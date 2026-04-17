const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const EventLoop = @import("event_loop.zig").EventLoop;
const resp = @import("resp.zig");
const KVStore = @import("../engine/kv.zig").KVStore;
const ConcurrentKV = @import("../engine/concurrent_kv.zig").ConcurrentKV;
const GraphEngine = @import("../engine/graph.zig").GraphEngine;
const CommandHandler = @import("../command/handler.zig").CommandHandler;
const KeysMode = @import("../command/handler.zig").KeysMode;
const AOF = @import("../storage/aof.zig").AOF;
const span = @import("../perf/span.zig");

const READ_BUF_SIZE = 64 * 1024;
const MAX_NEW_FDS = 256;

// ─── Connection ──────────────────────────────────────────────────────

const Connection = struct {
    fd: i32,
    selected_db: u8,
    accum: std.array_list.Managed(u8),
    write_buf: std.array_list.Managed(u8),
    write_offset: usize,

    fn init(allocator: Allocator, fd: i32) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .selected_db = 0,
            .accum = std.array_list.Managed(u8).init(allocator),
            .write_buf = std.array_list.Managed(u8).init(allocator),
            .write_offset = 0,
        };
        return conn;
    }

    fn deinit(self: *Connection, allocator: Allocator) void {
        self.accum.deinit();
        self.write_buf.deinit();
        allocator.destroy(self);
    }
};

// ─── Worker ──────────────────────────────────────────────────────────

pub const Worker = struct {
    id: u16,
    loop: EventLoop,
    conns: std.AutoHashMap(i32, *Connection),
    allocator: Allocator,
    io: std.Io,
    kv: *KVStore,
    kv_mutex: *std.atomic.Mutex,
    ckv: ?*ConcurrentKV,
    graph: *GraphEngine,
    graph_mutex: *std.atomic.Mutex,
    aof: ?*AOF,
    keys_mode: KeysMode,
    profile: ?*span.Profile,
    // Bounded ring buffer for new fds pushed by the accept thread.
    new_fds: [MAX_NEW_FDS]i32,
    new_fd_head: std.atomic.Value(usize),
    new_fd_tail: std.atomic.Value(usize),

    pub fn init(
        allocator: Allocator,
        id: u16,
        io: std.Io,
        kv: *KVStore,
        kv_mutex: *std.atomic.Mutex,
        ckv: ?*ConcurrentKV,
        graph: *GraphEngine,
        graph_mutex: *std.atomic.Mutex,
        aof: ?*AOF,
        keys_mode: KeysMode,
        profile: ?*span.Profile,
    ) !Worker {
        return .{
            .id = id,
            .loop = try EventLoop.init(),
            .conns = std.AutoHashMap(i32, *Connection).init(allocator),
            .allocator = allocator,
            .io = io,
            .kv = kv,
            .kv_mutex = kv_mutex,
            .ckv = ckv,
            .graph = graph,
            .graph_mutex = graph_mutex,
            .aof = aof,
            .keys_mode = keys_mode,
            .profile = profile,
            .new_fds = [_]i32{-1} ** MAX_NEW_FDS,
            .new_fd_head = std.atomic.Value(usize).init(0),
            .new_fd_tail = std.atomic.Value(usize).init(0),
        };
    }

    /// Called by the accept thread to hand off a new client fd to this worker.
    /// Lock-free single-producer (accept thread) is assumed; multiple producers
    /// would need a CAS loop, but our architecture has one accept thread.
    pub fn pushNewFd(self: *Worker, fd: i32) void {
        const tail = self.new_fd_tail.load(.monotonic);
        const head = self.new_fd_head.load(.acquire);
        // If the ring buffer is full, drop the connection.
        if (tail -% head >= MAX_NEW_FDS) {
            _ = std.c.close(fd);
            return;
        }
        self.new_fds[tail % MAX_NEW_FDS] = fd;
        self.new_fd_tail.store(tail +% 1, .release);
        // Wake the event loop so it picks up the new fd promptly.
        self.loop.notify();
    }

    /// Main loop — runs on the worker thread, never returns.
    pub fn run(self: *Worker) void {
        var event_buf: [128]EventLoop.Event = undefined;

        while (true) {
            const events = self.loop.poll(&event_buf, 100) catch continue;

            for (events) |ev| {
                if (self.loop.isNotifyFd(ev.fd)) {
                    self.loop.drainNotify();
                    self.acceptQueuedFds();
                    continue;
                }

                if (ev.hup or ev.err) {
                    self.closeConn(ev.fd);
                    continue;
                }

                if (ev.readable) {
                    if (self.conns.get(ev.fd)) |conn| {
                        self.handleRead(conn);
                    }
                }

                if (ev.writable) {
                    if (self.conns.get(ev.fd)) |conn| {
                        self.flushWrite(conn);
                    }
                }
            }
        }
    }

    // ── Internal helpers ─────────────────────────────────────────────

    fn acceptQueuedFds(self: *Worker) void {
        while (true) {
            const head = self.new_fd_head.load(.monotonic);
            const tail = self.new_fd_tail.load(.acquire);
            if (head == tail) break;

            const fd = self.new_fds[head % MAX_NEW_FDS];
            self.new_fd_head.store(head +% 1, .release);

            self.registerConnection(fd);
        }
    }

    fn registerConnection(self: *Worker, fd: i32) void {
        const conn = Connection.init(self.allocator, fd) catch {
            _ = std.c.close(fd);
            return;
        };
        self.conns.put(fd, conn) catch {
            conn.deinit(self.allocator);
            _ = std.c.close(fd);
            return;
        };
        self.loop.addFd(fd, @intCast(fd)) catch {
            _ = self.conns.remove(fd);
            conn.deinit(self.allocator);
            _ = std.c.close(fd);
            return;
        };
    }

    fn closeConn(self: *Worker, fd: i32) void {
        self.loop.removeFd(fd);
        if (self.conns.fetchRemove(fd)) |kv| {
            kv.value.deinit(self.allocator);
        }
        _ = std.c.close(fd);
    }

    fn handleRead(self: *Worker, conn: *Connection) void {
        var read_buf: [READ_BUF_SIZE]u8 = undefined;
        const rc = std.c.read(conn.fd, &read_buf, READ_BUF_SIZE);
        if (rc <= 0) {
            if (rc < 0) {
                const err = std.c.errno(rc);
                if (err == .AGAIN) return; // no data yet
            }
            // 0 = EOF, or fatal error
            self.closeConn(conn.fd);
            return;
        }
        const n: usize = @intCast(rc);

        conn.accum.appendSlice(read_buf[0..n]) catch {
            self.closeConn(conn.fd);
            return;
        };

        // Process as many complete commands as we can from the accumulator.
        while (conn.accum.items.len > 0) {
            if (!self.processOneCommand(conn)) break;
        }

        // Try to flush any pending writes immediately.
        if (conn.write_buf.items.len > conn.write_offset) {
            self.flushWrite(conn);
        }
    }

    fn processOneCommand(self: *Worker, conn: *Connection) bool {
        const data = conn.accum.items;

        // Fast RESP path: manual parse avoids full parser allocations.
        if (data.len >= 4 and data[0] == '*') {
            if (parseFastResp(data)) |result| {
                self.dispatchCommand(conn, result.args[0..result.argc]);
                consumeAccum(&conn.accum, result.consumed);
                return true;
            }
        }

        // Inline command path
        if (resp.isInlineCommand(data)) {
            const eol = findCRLF(data) orelse return false;
            const line = data[0..eol];

            const parts = resp.parseInlineCommand(line, self.allocator) catch return false;
            defer {
                for (parts) |p| self.allocator.free(p);
                self.allocator.free(parts);
            }

            self.dispatchCommand(conn, parts);
            consumeAccum(&conn.accum, eol + 2);
            return true;
        }

        // Full RESP parse (fallback for complex commands)
        var parser = resp.Parser.init(data);
        var val = parser.parse(self.allocator) catch return false;
        defer val.deinit(self.allocator);

        const args_raw = val.array orelse return false;
        var args = std.array_list.Managed([]const u8).init(self.allocator);
        defer args.deinit();
        for (args_raw) |item| {
            const s = switch (item) {
                .bulk_string => |bs| bs orelse continue,
                .simple_string => |ss| ss,
                else => continue,
            };
            args.append(s) catch return false;
        }

        self.dispatchCommand(conn, args.items);
        consumeAccum(&conn.accum, parser.pos);
        return true;
    }

    fn dispatchCommand(self: *Worker, conn: *Connection, args: []const []const u8) void {
        if (args.len == 0) return;

        // Handle SELECT per-connection without going through CommandHandler.
        if (isSelect(args)) {
            self.handleSelect(conn, args);
            return;
        }

        // Hot-path: use ConcurrentKV directly (no global mutex needed)
        if (self.ckv) |ckv| {
            if (self.executeHot(conn, args, ckv)) return;
        }

        self.executeCommand(conn, args);
    }

    /// Execute common KV commands directly on ConcurrentKV (lock-free hot path).
    /// Returns true if handled, false to fall back to CommandHandler.
    fn executeHot(self: *Worker, conn: *Connection, args: []const []const u8, ckv: *ConcurrentKV) bool {
        if (args.len == 0) return false;
        const cmd = args[0];

        if (equalsAsciiUpper(cmd, "PING")) {
            if (args.len > 1) {
                writeBulkTo(&conn.write_buf, args[1]);
            } else {
                conn.write_buf.appendSlice("+PONG\r\n") catch {};
            }
            return true;
        }

        if (equalsAsciiUpper(cmd, "COMMAND")) {
            conn.write_buf.appendSlice("+OK\r\n") catch {};
            return true;
        }

        // Build namespaced key: "db:N:userkey"
        const db = conn.selected_db;

        if (equalsAsciiUpper(cmd, "GET") and args.len == 2) {
            var key_buf: [512]u8 = undefined;
            const ns_key = namespacedKey(db, args[1], &key_buf) orelse return false;
            _ = ckv.getAndWriteBulk(ns_key, &conn.write_buf);
            return true;
        }

        if (equalsAsciiUpper(cmd, "SET") and args.len >= 3) {
            var key_buf: [512]u8 = undefined;
            const ns_key = namespacedKey(db, args[1], &key_buf) orelse return false;
            if (args.len >= 5 and equalsAsciiUpper(args[3], "EX")) {
                const ttl = std.fmt.parseInt(i64, args[4], 10) catch return false;
                ckv.setEx(ns_key, args[2], ttl) catch return false;
            } else if (args.len >= 5 and equalsAsciiUpper(args[3], "PX")) {
                const ttl = std.fmt.parseInt(i64, args[4], 10) catch return false;
                ckv.setPx(ns_key, args[2], ttl) catch return false;
            } else {
                ckv.set(ns_key, args[2]) catch return false;
            }
            if (self.aof) |a| {
                a.logCommand(args);
            }
            conn.write_buf.appendSlice("+OK\r\n") catch {};
            return true;
        }

        if (equalsAsciiUpper(cmd, "DEL") and args.len == 2) {
            var key_buf: [512]u8 = undefined;
            const ns_key = namespacedKey(db, args[1], &key_buf) orelse return false;
            const removed = ckv.delete(ns_key);
            if (removed) {
                if (self.aof) |a| a.logCommand(args);
                conn.write_buf.appendSlice(":1\r\n") catch {};
            } else {
                conn.write_buf.appendSlice(":0\r\n") catch {};
            }
            return true;
        }

        if (equalsAsciiUpper(cmd, "EXISTS") and args.len == 2) {
            var key_buf: [512]u8 = undefined;
            const ns_key = namespacedKey(db, args[1], &key_buf) orelse return false;
            if (ckv.exists(ns_key)) {
                conn.write_buf.appendSlice(":1\r\n") catch {};
            } else {
                conn.write_buf.appendSlice(":0\r\n") catch {};
            }
            return true;
        }

        if (equalsAsciiUpper(cmd, "TTL") and args.len == 2) {
            var key_buf: [512]u8 = undefined;
            const ns_key = namespacedKey(db, args[1], &key_buf) orelse return false;
            const present = ckv.exists(ns_key);
            if (!present) {
                conn.write_buf.appendSlice(":-2\r\n") catch {};
            } else if (ckv.ttl(ns_key)) |sec| {
                writeIntTo(&conn.write_buf, sec);
            } else {
                conn.write_buf.appendSlice(":-1\r\n") catch {};
            }
            return true;
        }

        if (equalsAsciiUpper(cmd, "FLUSHDB")) {
            ckv.flushdb();
            conn.write_buf.appendSlice("+OK\r\n") catch {};
            return true;
        }

        return false; // not a hot command, fall back to CommandHandler
    }

    fn executeCommand(self: *Worker, conn: *Connection, args: []const []const u8) void {
        var selected_db = std.atomic.Value(u8).init(conn.selected_db);

        // Serialize all KV/graph access under mutex (temporary until ConcurrentKV is wired)
        const is_graph = isGraphCommand(args);
        if (is_graph) {
            while (!self.graph_mutex.tryLock()) std.atomic.spinLoopHint();
        }
        defer if (is_graph) self.graph_mutex.unlock();

        while (!self.kv_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.kv_mutex.unlock();

        var handler = CommandHandler.init(
            self.allocator,
            self.io,
            self.kv,
            self.graph,
            self.aof,
            &selected_db,
            self.keys_mode,
        );

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &list);
        defer aw.deinit();

        handler.execute(args, &aw.writer) catch return;

        // Sync selected_db back — handler may have changed it for SELECT
        // (though we handle SELECT ourselves, this is a safety net).
        conn.selected_db = selected_db.load(.monotonic);

        conn.write_buf.appendSlice(aw.written()) catch return;
    }

    fn handleSelect(self: *Worker, conn: *Connection, args: []const []const u8) void {
        _ = self;
        if (args.len != 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'SELECT'\r\n") catch return;
            return;
        }
        const db_index = std.fmt.parseInt(u8, args[1], 10) catch {
            conn.write_buf.appendSlice("-ERR DB index is out of range\r\n") catch return;
            return;
        };
        if (db_index >= 16) {
            conn.write_buf.appendSlice("-ERR DB index is out of range\r\n") catch return;
            return;
        }
        conn.selected_db = db_index;
        conn.write_buf.appendSlice("+OK\r\n") catch return;
    }

    fn flushWrite(self: *Worker, conn: *Connection) void {
        while (conn.write_offset < conn.write_buf.items.len) {
            const remaining = conn.write_buf.items[conn.write_offset..];
            const rc = std.c.write(conn.fd, remaining.ptr, remaining.len);
            if (rc < 0) {
                const err = std.c.errno(rc);
                if (err == .AGAIN) {
                    // Cannot write more now; ask the event loop to notify when writable.
                    self.loop.enableWrite(conn.fd, @intCast(conn.fd)) catch {};
                    return;
                }
                // Fatal write error — drop the connection.
                self.closeConn(conn.fd);
                return;
            }
            if (rc == 0) {
                self.closeConn(conn.fd);
                return;
            }
            conn.write_offset += @intCast(rc);
        }

        // All data flushed — reset the write buffer and disable write interest.
        conn.write_buf.clearRetainingCapacity();
        conn.write_offset = 0;
        self.loop.disableWrite(conn.fd, @intCast(conn.fd)) catch {};
    }
};

// ─── Utility ─────────────────────────────────────────────────────────

fn consumeAccum(accum: *std.array_list.Managed(u8), n: usize) void {
    if (n >= accum.items.len) {
        accum.clearRetainingCapacity();
    } else {
        std.mem.copyForwards(u8, accum.items[0..], accum.items[n..]);
        accum.shrinkRetainingCapacity(accum.items.len - n);
    }
}

fn findCRLF(data: []const u8) ?usize {
    if (data.len < 2) return null;
    for (0..data.len - 1) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n') return i;
    }
    return null;
}

fn isSelect(args: []const []const u8) bool {
    if (args.len == 0) return false;
    return equalsAsciiUpper(args[0], "SELECT");
}

fn isGraphCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const cmd = args[0];
    if (cmd.len < 6) return false;
    return equalsAsciiUpperPrefix(cmd[0..6], "GRAPH.");
}

fn equalsAsciiUpper(s: []const u8, comptime upper: []const u8) bool {
    if (s.len != upper.len) return false;
    for (s, 0..) |c, i| {
        if (std.ascii.toUpper(c) != upper[i]) return false;
    }
    return true;
}

fn equalsAsciiUpperPrefix(s: []const u8, comptime upper: []const u8) bool {
    if (s.len < upper.len) return false;
    for (s[0..upper.len], 0..) |c, i| {
        if (std.ascii.toUpper(c) != upper[i]) return false;
    }
    return true;
}

const FastRespResult = struct {
    args: [8][]const u8,
    argc: usize,
    consumed: usize,
};

/// Zero-allocation RESP array parser. Returns slices into the input data.
/// Handles up to 8 args. Returns null if incomplete or unsupported.
fn parseFastResp(data: []const u8) ?FastRespResult {
    if (data.len < 4 or data[0] != '*') return null;
    var pos: usize = 1;
    const argc = parseIntLine(data, &pos) orelse return null;
    if (argc <= 0 or argc > 8) return null;

    var result = FastRespResult{
        .args = undefined,
        .argc = @intCast(argc),
        .consumed = 0,
    };

    var i: usize = 0;
    while (i < result.argc) : (i += 1) {
        if (pos >= data.len or data[pos] != '$') return null;
        pos += 1;
        const blen = parseIntLine(data, &pos) orelse return null;
        if (blen < 0) return null;
        const n: usize = @intCast(blen);
        if (pos + n + 2 > data.len) return null;
        result.args[i] = data[pos .. pos + n];
        pos += n;
        if (data[pos] != '\r' or data[pos + 1] != '\n') return null;
        pos += 2;
    }
    result.consumed = pos;
    return result;
}

fn parseIntLine(data: []const u8, pos: *usize) ?i64 {
    const start = pos.*;
    while (pos.* + 1 < data.len) : (pos.* += 1) {
        if (data[pos.*] == '\r' and data[pos.* + 1] == '\n') {
            const line = data[start..pos.*];
            pos.* += 2;
            return std.fmt.parseInt(i64, line, 10) catch return null;
        }
    }
    return null;
}

fn namespacedKey(db: u8, user_key: []const u8, buf: []u8) ?[]const u8 {
    const prefix = std.fmt.bufPrint(buf, "db:{d}:", .{db}) catch return null;
    const total = prefix.len + user_key.len;
    if (total > buf.len) return null;
    std.mem.copyForwards(u8, buf[prefix.len..total], user_key);
    return buf[0..total];
}

fn writeBulkTo(list: *std.array_list.Managed(u8), data: []const u8) void {
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "${d}\r\n", .{data.len}) catch return;
    list.appendSlice(h) catch return;
    list.appendSlice(data) catch return;
    list.appendSlice("\r\n") catch return;
}

fn writeIntTo(list: *std.array_list.Managed(u8), n: i64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, ":{d}\r\n", .{n}) catch return;
    list.appendSlice(s) catch return;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[worker] " ++ fmt ++ "\n", args);
}
