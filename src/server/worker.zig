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
const ct = @import("../command/comptime_dispatch.zig");
const replication = @import("../cluster/replication.zig");
const TlsContext = @import("tls.zig").TlsContext;
const SSL = @import("tls.zig").SSL;

const READ_BUF_SIZE = 64 * 1024;
const MAX_NEW_FDS = 256;

// ─── Precomputed DB prefixes (fix #4) ───────────────────────────────
// Avoids std.fmt.bufPrint("db:{d}:") per command (~20ns saved per op)
const DB_PREFIXES = blk: {
    var prefixes: [16][]const u8 = undefined;
    for (0..16) |i| {
        prefixes[i] = std.fmt.comptimePrint("db:{d}:", .{i});
    }
    break :blk prefixes;
};

// ─── Connection ──────────────────────────────────────────────────────

const Connection = struct {
    fd: i32,
    selected_db: u8,
    accum: std.array_list.Managed(u8),
    accum_pos: usize, // FIX #1: head index — avoids memmove on consumeAccum
    write_buf: std.array_list.Managed(u8),
    write_offset: usize,
    write_registered: bool,
    authenticated: bool,
    ssl: ?*SSL,

    fn init(allocator: Allocator, fd: i32, auth_required: bool) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .selected_db = 0,
            .accum = std.array_list.Managed(u8).init(allocator),
            .accum_pos = 0,
            .write_buf = std.array_list.Managed(u8).init(allocator),
            .write_offset = 0,
            .write_registered = false,
            .authenticated = !auth_required,
            .ssl = null,
        };
        return conn;
    }

    fn deinit(self: *Connection, allocator: Allocator) void {
        self.accum.deinit();
        self.write_buf.deinit();
        allocator.destroy(self);
    }

    /// Remaining unprocessed data in the accumulator.
    fn accumData(self: *const Connection) []const u8 {
        return self.accum.items[self.accum_pos..];
    }

    /// Advance the read position (no memmove). Compacts only when fully consumed.
    fn advanceAccum(self: *Connection, n: usize) void {
        self.accum_pos += n;
        if (self.accum_pos >= self.accum.items.len) {
            // Fully consumed — reset to reuse buffer capacity
            self.accum.clearRetainingCapacity();
            self.accum_pos = 0;
        } else if (self.accum_pos > 32768) {
            // Compact when head is far advanced to avoid unbounded growth
            const remaining = self.accum.items.len - self.accum_pos;
            std.mem.copyForwards(u8, self.accum.items[0..remaining], self.accum.items[self.accum_pos..]);
            self.accum.shrinkRetainingCapacity(remaining);
            self.accum_pos = 0;
        }
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
    graph_rwlock: *std.c.pthread_rwlock_t,
    aof: ?*AOF,
    keys_mode: KeysMode,
    profile: ?*span.Profile,
    requirepass: ?[]const u8,
    maxclients: u32,
    max_client_buffer: usize,
    active_connections: *std.atomic.Value(u32),
    tls_ctx: ?*TlsContext,
    repl_follower: ?*replication.ReplicationFollower,
    repl_leader: ?*replication.ReplicationLeader,
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
        graph_rwlock: *std.c.pthread_rwlock_t,
        aof: ?*AOF,
        keys_mode: KeysMode,
        profile: ?*span.Profile,
        requirepass: ?[]const u8,
        maxclients: u32,
        max_client_buffer: usize,
        active_connections: *std.atomic.Value(u32),
        tls_ctx: ?*TlsContext,
        repl_follower: ?*replication.ReplicationFollower,
        repl_leader: ?*replication.ReplicationLeader,
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
            .graph_rwlock = graph_rwlock,
            .aof = aof,
            .keys_mode = keys_mode,
            .profile = profile,
            .requirepass = requirepass,
            .maxclients = maxclients,
            .max_client_buffer = max_client_buffer,
            .active_connections = active_connections,
            .tls_ctx = tls_ctx,
            .repl_follower = repl_follower,
            .repl_leader = repl_leader,
            .new_fds = [_]i32{-1} ** MAX_NEW_FDS,
            .new_fd_head = std.atomic.Value(usize).init(0),
            .new_fd_tail = std.atomic.Value(usize).init(0),
        };
    }

    pub fn pushNewFd(self: *Worker, fd: i32) void {
        const tail = self.new_fd_tail.load(.monotonic);
        const head = self.new_fd_head.load(.acquire);
        if (tail -% head >= MAX_NEW_FDS) {
            _ = std.c.close(fd);
            return;
        }
        self.new_fds[tail % MAX_NEW_FDS] = fd;
        self.new_fd_tail.store(tail +% 1, .release);
        self.loop.notify();
    }

    pub fn run(self: *Worker) void {
        var event_buf: [128]EventLoop.Event = undefined;

        while (true) {
            // Update cached clocks once per event loop tick
            if (self.ckv) |ckv| ckv.updateClock();

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
        setTcpNoDelay(fd);

        // Connection limit check
        const count = self.active_connections.fetchAdd(1, .monotonic);
        if (count >= self.maxclients) {
            _ = self.active_connections.fetchSub(1, .monotonic);
            _ = std.c.write(fd, "-ERR max number of clients reached\r\n", 36);
            _ = std.c.close(fd);
            return;
        }

        // TLS handshake (before adding to event loop)
        var ssl: ?*SSL = null;
        if (self.tls_ctx) |tls| {
            ssl = tls.wrapFd(fd);
            if (ssl == null) {
                _ = self.active_connections.fetchSub(1, .monotonic);
                _ = std.c.close(fd);
                return;
            }
        }

        const conn = Connection.init(self.allocator, fd, self.requirepass != null) catch {
            if (ssl) |s| self.tls_ctx.?.sslClose(s);
            _ = self.active_connections.fetchSub(1, .monotonic);
            _ = std.c.close(fd);
            return;
        };
        conn.ssl = ssl;
        self.conns.put(fd, conn) catch {
            if (conn.ssl) |s| self.tls_ctx.?.sslClose(s);
            conn.deinit(self.allocator);
            _ = self.active_connections.fetchSub(1, .monotonic);
            _ = std.c.close(fd);
            return;
        };
        self.loop.addFd(fd, @intCast(fd)) catch {
            _ = self.conns.remove(fd);
            if (conn.ssl) |s| self.tls_ctx.?.sslClose(s);
            conn.deinit(self.allocator);
            _ = self.active_connections.fetchSub(1, .monotonic);
            _ = std.c.close(fd);
            return;
        };
    }

    fn closeConn(self: *Worker, fd: i32) void {
        self.loop.removeFd(fd);
        if (self.conns.fetchRemove(fd)) |kv| {
            if (kv.value.ssl) |s| {
                if (self.tls_ctx) |tls| tls.sslClose(s);
            }
            kv.value.deinit(self.allocator);
        }
        _ = self.active_connections.fetchSub(1, .monotonic);
        _ = std.c.close(fd);
    }

    /// Read from connection, handling TLS transparently.
    /// Returns: >0 bytes read, 0 = closed, -1 = EAGAIN.
    fn connRead(self: *Worker, conn: *Connection, buf: [*]u8, len: usize) isize {
        if (conn.ssl) |ssl| {
            return self.tls_ctx.?.sslRead(ssl, buf, len);
        }
        const rc = std.c.read(conn.fd, buf, len);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .AGAIN) return -1;
            return 0;
        }
        return rc;
    }

    /// Write to connection, handling TLS transparently.
    /// Returns: >0 bytes written, 0 = closed, -1 = EAGAIN.
    fn connWrite(self: *Worker, conn: *Connection, buf: [*]const u8, len: usize) isize {
        if (conn.ssl) |ssl| {
            return self.tls_ctx.?.sslWrite(ssl, buf, len);
        }
        const rc = std.c.write(conn.fd, buf, len);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .AGAIN) return -1;
            return 0;
        }
        return rc;
    }

    fn handleRead(self: *Worker, conn: *Connection) void {
        var read_buf: [READ_BUF_SIZE]u8 = undefined;
        const rc = self.connRead(conn, &read_buf, READ_BUF_SIZE);
        if (rc <= 0) {
            if (rc < 0) return; // EAGAIN
            self.closeConn(conn.fd);
            return;
        }
        const n: usize = @intCast(rc);

        // FAST PATH: if accumulator is empty (no partial command from previous read),
        // parse directly from the read buffer — eliminates memcpy to accumulator.
        // This is the common case: pipelined batches fit in one read().
        if (conn.accum_pos >= conn.accum.items.len) {
            conn.accum.clearRetainingCapacity();
            conn.accum_pos = 0;

            var pos: usize = 0;
            while (pos < n) {
                const data = read_buf[pos..n];
                if (data.len >= 4 and data[0] == '*') {
                    if (parseFastResp(data)) |result| {
                        self.dispatchCommand(conn, result.args[0..result.argc]);
                        pos += result.consumed;
                        continue;
                    }
                }
                break; // incomplete or non-fast-path — move to accumulator
            }

            // Only copy leftover (partial command) to accumulator
            if (pos < n) {
                conn.accum.appendSlice(read_buf[pos..n]) catch {
                    self.closeConn(conn.fd);
                    return;
                };
                // Try parsing the accumulator for inline/full RESP commands
                while (conn.accumData().len > 0) {
                    if (!self.processOneCommand(conn)) break;
                }
            }
        } else {
            // SLOW PATH: accumulator has leftover from previous read
            conn.accum.appendSlice(read_buf[0..n]) catch {
                self.closeConn(conn.fd);
                return;
            };

            if (conn.accum.items.len > self.max_client_buffer) {
                _ = std.c.write(conn.fd, "-ERR max client buffer exceeded\r\n", 33);
                self.closeConn(conn.fd);
                return;
            }

            while (conn.accumData().len > 0) {
                if (!self.processOneCommand(conn)) break;
            }
        }

        if (conn.write_buf.items.len > conn.write_offset) {
            self.directFlush(conn);
        }
    }

    fn processOneCommand(self: *Worker, conn: *Connection) bool {
        const data = conn.accumData(); // FIX #1: uses head index, no copy

        // Fast RESP path: zero-allocation manual parse.
        if (data.len >= 4 and data[0] == '*') {
            if (parseFastResp(data)) |result| {
                self.dispatchCommand(conn, result.args[0..result.argc]);
                conn.advanceAccum(result.consumed); // FIX #1: advance, no memmove
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
            conn.advanceAccum(eol + 2);
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
        conn.advanceAccum(parser.pos);
        return true;
    }

    fn dispatchCommand(self: *Worker, conn: *Connection, args: []const []const u8) void {
        if (args.len == 0) return;

        // AUTH gate: reject unauthenticated commands (except AUTH and PING)
        if (!conn.authenticated) {
            const cmd = args[0];
            if (equalsAsciiUpper(cmd, "AUTH")) {
                self.handleAuth(conn, args);
                return;
            }
            if (equalsAsciiUpper(cmd, "PING")) {
                if (args.len > 1) {
                    writeBulkTo(&conn.write_buf, args[1]);
                } else {
                    conn.write_buf.appendSlice(ct.resp_pong) catch {};
                }
                return;
            }
            conn.write_buf.appendSlice("-NOAUTH Authentication required.\r\n") catch {};
            return;
        }

        // ── Follower write forwarding: send writes to leader ──
        if (self.repl_follower) |rf| {
            if (replication.isWriteCommand(args)) {
                const resp_bytes = rf.forwardWrite(args) catch {
                    conn.write_buf.appendSlice("-ERR leader unavailable\r\n") catch {};
                    return;
                };
                defer self.allocator.free(resp_bytes);
                conn.write_buf.appendSlice(resp_bytes) catch {};
                return;
            }
        }

        if (self.ckv) |ckv| {
            if (self.executeHotFast(conn, args, ckv)) return;
        }

        // AUTH when already authenticated (Redis allows re-AUTH)
        if (args.len >= 1 and args[0].len == 4 and equalsAsciiUpper(args[0], "AUTH")) {
            self.handleAuth(conn, args);
            return;
        }

        if (isSelect(args)) {
            self.handleSelect(conn, args);
            return;
        }

        self.executeCommand(conn, args);
    }

    fn handleAuth(self: *Worker, conn: *Connection, args: []const []const u8) void {
        if (self.requirepass == null) {
            conn.write_buf.appendSlice("-ERR Client sent AUTH, but no password is set\r\n") catch {};
            return;
        }
        if (args.len != 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'AUTH'\r\n") catch {};
            return;
        }
        const pass = self.requirepass.?;
        const provided = args[1];
        // Constant-time comparison to prevent timing attacks
        if (provided.len == pass.len and constantTimeEql(provided, pass)) {
            conn.authenticated = true;
            conn.write_buf.appendSlice("+OK\r\n") catch {};
        } else {
            conn.write_buf.appendSlice("-ERR invalid password\r\n") catch {};
        }
    }

    /// Hot-path command dispatch using nested switch (compiler generates jump tables).
    /// Comptime response literals from ct module avoid runtime formatting.
    fn executeHotFast(self: *Worker, conn: *Connection, args: []const []const u8, ckv: *ConcurrentKV) bool {
        if (args.len == 0) return false;
        const cmd = args[0];
        if (cmd.len == 0) return false;

        const first = std.ascii.toUpper(cmd[0]);
        switch (cmd.len) {
            3 => switch (first) {
                'G' => if (args.len >= 2 and equalsAsciiUpper(cmd, "GET")) {
                    const ns_key = nsKey(conn.selected_db, args[1]) orelse return false;
                    _ = ckv.getAndWriteBulk(ns_key, &conn.write_buf);
                    return true;
                },
                'S' => if (args.len >= 3 and equalsAsciiUpper(cmd, "SET")) {
                    const ns_key = nsKey(conn.selected_db, args[1]) orelse return false;
                    // Pre-allocate key+value OUTSIDE the stripe lock
                    const key_copy = self.allocator.dupe(u8, ns_key) catch return false;
                    const val_copy = self.allocator.dupe(u8, args[2]) catch {
                        self.allocator.free(key_copy);
                        return false;
                    };
                    var expires: i64 = 0;
                    if (args.len >= 5 and equalsAsciiUpper(args[3], "EX")) {
                        const t = std.fmt.parseInt(i64, args[4], 10) catch return false;
                        expires = ckv.nowMillis() + t * 1000;
                    } else if (args.len >= 5 and equalsAsciiUpper(args[3], "PX")) {
                        const t = std.fmt.parseInt(i64, args[4], 10) catch return false;
                        expires = ckv.nowMillis() + t;
                    }
                    // Lock held only for HashMap update (~20ns), not malloc (~60ns)
                    const stale = ckv.setPrealloc(ns_key, key_copy, val_copy, expires);
                    // Free stale data OUTSIDE the lock
                    if (stale.stale_val) |v| self.allocator.free(v);
                    if (stale.stale_key) |k| self.allocator.free(k);
                    if (self.aof) |a| a.logCommand(args);
                    conn.write_buf.appendSlice(ct.resp_ok) catch {};
                    return true;
                },
                'D' => if (args.len >= 2 and equalsAsciiUpper(cmd, "DEL")) {
                    const ns_key = nsKey(conn.selected_db, args[1]) orelse return false;
                    const stale = ckv.deleteStale(ns_key);
                    // Free OUTSIDE lock
                    if (stale.stale_key) |k| self.allocator.free(k);
                    if (stale.stale_val) |v| self.allocator.free(v);
                    if (stale.found) {
                        if (self.aof) |a| a.logCommand(args);
                        conn.write_buf.appendSlice(ct.RespInts.@"1") catch {};
                    } else {
                        conn.write_buf.appendSlice(ct.RespInts.@"0") catch {};
                    }
                    return true;
                },
                'T' => if (args.len >= 2 and equalsAsciiUpper(cmd, "TTL")) {
                    const ns_key = nsKey(conn.selected_db, args[1]) orelse return false;
                    if (!ckv.exists(ns_key)) {
                        conn.write_buf.appendSlice(ct.RespInts.@"-2") catch {};
                    } else if (ckv.ttl(ns_key)) |sec| {
                        writeIntTo(&conn.write_buf, sec);
                    } else {
                        conn.write_buf.appendSlice(ct.RespInts.@"-1") catch {};
                    }
                    return true;
                },
                else => {},
            },
            4 => if (first == 'P' and equalsAsciiUpper(cmd, "PING")) {
                if (args.len > 1) {
                    writeBulkTo(&conn.write_buf, args[1]);
                } else {
                    conn.write_buf.appendSlice(ct.resp_pong) catch {};
                }
                return true;
            },
            6 => switch (first) {
                'E' => if (args.len >= 2 and equalsAsciiUpper(cmd, "EXISTS")) {
                    const ns_key = nsKey(conn.selected_db, args[1]) orelse return false;
                    if (ckv.exists(ns_key)) {
                        conn.write_buf.appendSlice(ct.RespInts.@"1") catch {};
                    } else {
                        conn.write_buf.appendSlice(ct.RespInts.@"0") catch {};
                    }
                    return true;
                },
                'D' => if (equalsAsciiUpper(cmd, "DBSIZE")) {
                    writeIntTo(&conn.write_buf, @intCast(ckv.dbsize()));
                    return true;
                },
                else => {},
            },
            7 => switch (first) {
                'C' => if (equalsAsciiUpper(cmd, "COMMAND")) {
                    conn.write_buf.appendSlice(ct.resp_ok) catch {};
                    return true;
                },
                'F' => if (equalsAsciiUpper(cmd, "FLUSHDB")) {
                    ckv.flushdb();
                    conn.write_buf.appendSlice(ct.resp_ok) catch {};
                    return true;
                },
                else => {},
            },
            else => {},
        }
        return false;
    }

    fn executeCommand(self: *Worker, conn: *Connection, args: []const []const u8) void {
        var selected_db = std.atomic.Value(u8).init(conn.selected_db);

        const is_graph = isGraphCommand(args);
        const is_graph_write = if (is_graph) isGraphWriteCommand(args) else false;
        if (is_graph) {
            if (is_graph_write) {
                _ = std.c.pthread_rwlock_wrlock(self.graph_rwlock);
            } else {
                _ = std.c.pthread_rwlock_rdlock(self.graph_rwlock);
            }
        }
        defer if (is_graph) {
            _ = std.c.pthread_rwlock_unlock(self.graph_rwlock);
        };

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

    /// FIX #2: Direct write attempt — avoids enableWrite/disableWrite syscalls.
    /// Most responses fit in the TCP send buffer, so write() succeeds immediately.
    /// Only registers for writable events if EAGAIN (partial write).
    fn directFlush(self: *Worker, conn: *Connection) void {
        while (conn.write_offset < conn.write_buf.items.len) {
            const remaining = conn.write_buf.items[conn.write_offset..];
            const rc = self.connWrite(conn, remaining.ptr, remaining.len);
            if (rc < 0) {
                // Send buffer full — register for writable event
                if (!conn.write_registered) {
                    self.loop.enableWrite(conn.fd, @intCast(conn.fd)) catch {};
                    conn.write_registered = true;
                }
                return;
            }
            if (rc == 0) {
                self.closeConn(conn.fd);
                return;
            }
            conn.write_offset += @intCast(rc);
        }

        // All data flushed
        conn.write_buf.clearRetainingCapacity();
        conn.write_offset = 0;
        // Only call disableWrite if we previously registered
        if (conn.write_registered) {
            self.loop.disableWrite(conn.fd, @intCast(conn.fd)) catch {};
            conn.write_registered = false;
        }
    }

    /// Called when event loop says fd is writable (deferred flush for partial writes).
    fn flushWrite(self: *Worker, conn: *Connection) void {
        self.directFlush(conn);
    }
};

// ─── Utility ─────────────────────────────────────────────────────────

/// FIX #4: Precomputed DB prefix + user key concatenation.
/// Uses compile-time prefix table instead of runtime std.fmt.bufPrint.
fn nsKey(db: u8, user_key: []const u8) ?[]const u8 {
    // We need to build "db:N:userkey" in a buffer.
    // The prefix is precomputed; we just memcpy prefix + user_key.
    const S = struct {
        threadlocal var buf: [512]u8 = undefined;
    };
    if (db >= 16) return null;
    const prefix = DB_PREFIXES[db];
    const total = prefix.len + user_key.len;
    if (total > S.buf.len) return null;
    @memcpy(S.buf[0..prefix.len], prefix);
    @memcpy(S.buf[prefix.len..total], user_key);
    return S.buf[0..total];
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

/// Graph write commands need exclusive (write) lock.
/// Read commands (GETNODE, NEIGHBORS, TRAVERSE, PATH, WPATH, STATS) take shared read lock.
fn isGraphWriteCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const cmd = args[0];
    // Write commands: ADDNODE, DELNODE, SETPROP, ADDEDGE, DELEDGE
    if (cmd.len >= 12 and equalsAsciiUpperPrefix(cmd[6..], "ADDNOD")) return true;
    if (cmd.len >= 12 and equalsAsciiUpperPrefix(cmd[6..], "DELNOD")) return true;
    if (cmd.len >= 13 and equalsAsciiUpperPrefix(cmd[6..], "SETPRO")) return true;
    if (cmd.len >= 12 and equalsAsciiUpperPrefix(cmd[6..], "ADDEDG")) return true;
    if (cmd.len >= 12 and equalsAsciiUpperPrefix(cmd[6..], "DELEDG")) return true;
    return false; // GETNODE, NEIGHBORS, TRAVERSE, PATH, WPATH, STATS = read
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

fn setTcpNoDelay(fd: i32) void {
    const yes: c_int = 1;
    _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, @ptrCast(&yes), @sizeOf(c_int));
}

/// Constant-time byte comparison to prevent timing attacks on password check.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[worker] " ++ fmt ++ "\n", args);
}
