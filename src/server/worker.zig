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
const ListStore = @import("../engine/list.zig").ListStore;
const HashStore = @import("../engine/hash.zig").HashStore;
const SetStore = @import("../engine/set.zig").SetStore;
const SortedSetStore = @import("../engine/sorted_set.zig").SortedSetStore;

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

/// Shared pub/sub registry (thread-safe, shared across all workers).
pub const PubSubRegistry = struct {
    /// channel_name → list of subscriber fds
    channels: std.StringHashMap(std.array_list.Managed(i32)),
    mutex: std.c.pthread_mutex_t,
    allocator: Allocator,

    pub fn init(allocator: Allocator) PubSubRegistry {
        return .{
            .channels = std.StringHashMap(std.array_list.Managed(i32)).init(allocator),
            .mutex = std.c.PTHREAD_MUTEX_INITIALIZER,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PubSubRegistry) void {
        var it = self.channels.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.channels.deinit();
    }

    pub fn subscribe(self: *PubSubRegistry, channel: []const u8, fd: i32) !void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        const gop = try self.channels.getOrPut(channel);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, channel);
            gop.value_ptr.* = std.array_list.Managed(i32).init(self.allocator);
        }
        // Avoid duplicate subscriptions
        for (gop.value_ptr.items) |existing_fd| {
            if (existing_fd == fd) return;
        }
        try gop.value_ptr.append(fd);
    }

    pub fn unsubscribe(self: *PubSubRegistry, channel: []const u8, fd: i32) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        if (self.channels.getPtr(channel)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == fd) {
                    _ = list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    pub fn unsubscribeAll(self: *PubSubRegistry, fd: i32) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        var it = self.channels.iterator();
        while (it.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (entry.value_ptr.items[i] == fd) {
                    _ = entry.value_ptr.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Publish: returns list of subscriber fds (caller writes to them).
    /// Caller must NOT hold the mutex while writing to fds.
    pub fn getSubscribers(self: *PubSubRegistry, channel: []const u8, out: *std.array_list.Managed(i32)) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        if (self.channels.get(channel)) |list| {
            out.appendSlice(list.items) catch {};
        }
    }
};

pub const DS_STRIPE_COUNT = 256;
pub const STRIPE_UNOWNED: u16 = 0xFFFF;

pub const DsStripeLocks = struct {
    /// Stripe lease: holds the worker_id that currently owns the stripe.
    /// STRIPE_UNOWNED = free. Worker that owns a lease can access the stripe
    /// without any atomic ops (~1ns check vs ~10ns CAS per command).
    /// Leases are held for the duration of a pipeline batch, then released.
    /// With P=50: 1 CAS acquire + 49 free checks + 1 release = 3 atomic ops
    /// vs old approach: 50 CAS acquire + 50 release = 100 atomic ops.
    lease: [DS_STRIPE_COUNT]std.atomic.Value(u16) align(64),

    pub fn init(self: *DsStripeLocks) void {
        for (&self.lease) |*l| l.* = std.atomic.Value(u16).init(STRIPE_UNOWNED);
    }

    pub fn stripeIndex(key: []const u8) usize {
        return @as(usize, std.hash.Wyhash.hash(0, key)) % DS_STRIPE_COUNT;
    }

    pub fn acquire(self: *DsStripeLocks, key: []const u8, worker_id: u16, last: *u16) void {
        const idx: u16 = @intCast(stripeIndex(key));
        // Fast path: same stripe as last command — register compare only, ~0.3ns
        if (idx == last.*) return;
        // Release previous stripe (if any)
        if (last.* != STRIPE_UNOWNED) {
            self.lease[last.*].store(STRIPE_UNOWNED, .release);
        }
        // TTAS: spin on cheap load (stays in L1, no cache bouncing), then CAS
        while (true) {
            while (self.lease[idx].load(.monotonic) != STRIPE_UNOWNED)
                std.atomic.spinLoopHint();
            if (self.lease[idx].cmpxchgWeak(STRIPE_UNOWNED, worker_id, .acquire, .monotonic) == null)
                break;
        }
        last.* = idx;
    }

    pub fn releaseAll(self: *DsStripeLocks, last: *u16) void {
        if (last.* != STRIPE_UNOWNED) {
            self.lease[last.*].store(STRIPE_UNOWNED, .release);
            last.* = STRIPE_UNOWNED;
        }
    }
};

/// Shared per-key version tracking for WATCH/EXEC optimistic locking.
/// Every write to a key bumps its version. WATCH snapshots versions.
/// EXEC aborts if any watched key's version changed.
pub const WatchMap = struct {
    versions: std.StringHashMap(u64),
    mutex: std.c.pthread_mutex_t,
    allocator: Allocator,
    /// Number of active watches across all connections. When 0, bumpVersion is a no-op.
    active_watches: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(allocator: Allocator) WatchMap {
        return .{
            .versions = std.StringHashMap(u64).init(allocator),
            .mutex = std.c.PTHREAD_MUTEX_INITIALIZER,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WatchMap) void {
        var it = self.versions.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.versions.deinit();
    }

    pub fn getVersion(self: *WatchMap, key: []const u8) u64 {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        return self.versions.get(key) orelse 0;
    }

    pub fn bumpVersion(self: *WatchMap, key: []const u8) void {
        // Fast exit: no active watches → skip mutex + HashMap entirely
        if (self.active_watches.load(.monotonic) == 0) return;
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        const gop = self.versions.getOrPut(key) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, key) catch return;
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* += 1;
        }
    }
};

const WatchEntry = struct {
    key: []u8,
    version: u64,
};

const Connection = struct {
    fd: i32,
    selected_db: u8,
    accum: std.array_list.Managed(u8),
    accum_pos: usize,    write_buf: std.array_list.Managed(u8),
    write_offset: usize,
    write_registered: bool,
    authenticated: bool,
    ssl: ?*SSL,
    pubsub_mode: bool,
    /// Connection name set by CLIENT SETNAME
    client_name: ?[]u8,
    /// Unique connection ID
    client_id: u64,
    /// Transaction queue: non-null when MULTI is active
    tx_queue: ?std.array_list.Managed(TxCommand),
    /// WATCH: list of key version snapshots
    watched_keys: ?std.array_list.Managed(WatchEntry),
    /// Set to true if a watched key was modified (dirty flag)
    watch_dirty: bool,

    const TxCommand = struct {
        args: [][]u8,

        fn deinit(self: *TxCommand, alloc: Allocator) void {
            for (self.args) |arg| alloc.free(arg);
            alloc.free(self.args);
        }
    };

    /// Global connection ID counter
    var next_client_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

    fn init(allocator: Allocator, fd: i32, auth_required: bool) !*Connection {
        const conn = try allocator.create(Connection);
        conn.* = .{
            .fd = fd,
            .selected_db = 0,
            .accum = std.array_list.Managed(u8).init(allocator),
            .accum_pos = 0,
            .write_buf = blk: {
                var buf = std.array_list.Managed(u8).init(allocator);
                buf.ensureTotalCapacity(4096) catch {}; // pre-warm to avoid first-response malloc
                break :blk buf;
            },
            .write_offset = 0,
            .write_registered = false,
            .authenticated = !auth_required,
            .ssl = null,
            .pubsub_mode = false,
            .client_name = null,
            .client_id = next_client_id.fetchAdd(1, .monotonic),
            .tx_queue = null,
            .watched_keys = null,
            .watch_dirty = false,
        };
        return conn;
    }

    fn deinit(self: *Connection, allocator: Allocator) void {
        if (self.tx_queue) |*q| {
            for (q.items) |*cmd| cmd.deinit(allocator);
            q.deinit();
        }
        if (self.watched_keys) |*wk| {
            for (wk.items) |entry| allocator.free(entry.key);
            wk.deinit();
        }
        if (self.client_name) |name| allocator.free(name);
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
    pubsub: ?*PubSubRegistry,
    list_store: ?*ListStore,
    hash_store: ?*HashStore,
    set_store: ?*SetStore,
    sorted_set_store: ?*SortedSetStore,
    ds_locks: ?*DsStripeLocks, // striped rwlocks for list/hash/set/zset stores
    watch_map: ?*WatchMap,
    new_fds: [MAX_NEW_FDS]i32,
    new_fd_head: std.atomic.Value(usize),
    new_fd_tail: std.atomic.Value(usize),
    /// Last stripe lease held by this worker (only one at a time)
    last_stripe: u16,

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
        pubsub: ?*PubSubRegistry,
        list_store: ?*ListStore,
        hash_store: ?*HashStore,
        set_store: ?*SetStore,
        sorted_set_store: ?*SortedSetStore,
        ds_locks: ?*DsStripeLocks,
        watch_map: ?*WatchMap,
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
            .pubsub = pubsub,
            .list_store = list_store,
            .hash_store = hash_store,
            .set_store = set_store,
            .sorted_set_store = sorted_set_store,
            .ds_locks = ds_locks,
            .watch_map = watch_map,
            .new_fds = [_]i32{-1} ** MAX_NEW_FDS,
            .new_fd_head = std.atomic.Value(usize).init(0),
            .new_fd_tail = std.atomic.Value(usize).init(0),
            .last_stripe = STRIPE_UNOWNED,
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

            // AOF group commit: flush buffered commands to file at end of tick
            if (self.aof) |a| a.flush();
        }
    }

    /// Stripe affinity: after processing a data-store command, check if this
    /// connection should migrate to the worker that owns the stripe.
    /// Processes current command normally (with lock), migration happens after flush.
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
        // Unsubscribe from all pub/sub channels
        if (self.pubsub) |ps| ps.unsubscribeAll(fd);
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
        // Read drain loop: process all available data before flushing.
        // If more data arrived while processing commands, read it too.
        // This effectively increases pipeline depth for free.
        var reads: u32 = 0;
        while (reads < 8) : (reads += 1) {
            var read_buf: [READ_BUF_SIZE]u8 = undefined;
            const rc = self.connRead(conn, &read_buf, READ_BUF_SIZE);
            if (rc <= 0) {
                if (rc < 0) break; // EAGAIN — no more data, flush and return
                self.closeConn(conn.fd);
                return;
            }
            const n: usize = @intCast(rc);

            // FAST PATH: if accumulator is empty (no partial command from previous read),
            // parse directly from the read buffer — eliminates memcpy to accumulator.
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
                    break;
                }

                if (pos < n) {
                    conn.accum.appendSlice(read_buf[pos..n]) catch {
                        self.closeConn(conn.fd);
                        return;
                    };
                    while (conn.accumData().len > 0) {
                        if (!self.processOneCommand(conn)) break;
                    }
                }
            } else {
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
        }

        if (conn.write_buf.items.len > conn.write_offset) {
            self.directFlush(conn);
        }

        // Release the single held stripe lease.
        if (self.ds_locks) |dsl| dsl.releaseAll(&self.last_stripe);
    }

    fn processOneCommand(self: *Worker, conn: *Connection) bool {
        const data = conn.accumData();
        // Fast RESP path: zero-allocation manual parse.
        if (data.len >= 4 and data[0] == '*') {
            if (parseFastResp(data)) |result| {
                self.dispatchCommand(conn, result.args[0..result.argc]);
                conn.advanceAccum(result.consumed);                return true;
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

        // ── Fast path: common case (authenticated, no pubsub, no transaction) ──
        // Skips ~15 branch comparisons for the hot path.
        if (conn.authenticated and !conn.pubsub_mode and conn.tx_queue == null) {
            // Check for _REPL marker
            if (args.len >= 2 and std.mem.eql(u8, args[0], "_REPL")) {
                const real_args = args[1..];
                if (self.ckv) |ckv| {
                    if (self.executeHotFast(conn, real_args, ckv)) return;
                }
                self.executeCommand(conn, real_args);
                return;
            }

            // Follower write forwarding
            if (self.repl_follower) |rf| {
                if (!rf.promoted.load(.acquire) and replication.isWriteCommand(args)) {
                    const resp_bytes = rf.forwardWrite(args) catch {
                        conn.write_buf.appendSlice("-ERR leader unavailable\r\n") catch {};
                        return;
                    };
                    defer self.allocator.free(resp_bytes);
                    conn.write_buf.appendSlice(resp_bytes) catch {};
                    return;
                }
            }

            // Hot path engine dispatch
            if (self.ckv) |ckv| {
                if (self.executeHotFast(conn, args, ckv)) {
                    self.maybeBroadcast(args);
                    return;
                }
            }

            // SELECT (connection-level, not in CommandHandler)
            if (isSelect(args)) {
                self.handleSelect(conn, args);
                return;
            }

            // Fall through to CommandHandler for non-hot-path commands
            self.executeCommand(conn, args);
            self.maybeBroadcast(args);
            return;
        }

        // ── Slow path: handles auth, pubsub, transactions, etc. ──

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

        // ── Pub/Sub commands ────────────────────────────────────────────
        if (self.pubsub) |ps| {
            if (args[0].len >= 7 and equalsAsciiUpper(args[0], "PUBLISH")) {
                self.handlePublish(conn, args, ps);
                return;
            }
            if (args[0].len >= 9 and equalsAsciiUpper(args[0], "SUBSCRIBE")) {
                self.handleSubscribe(conn, args, ps);
                return;
            }
            if (args[0].len >= 11 and equalsAsciiUpper(args[0], "UNSUBSCRIBE")) {
                self.handleUnsubscribe(conn, args, ps);
                return;
            }
        }

        // In pub/sub mode, only SUBSCRIBE/UNSUBSCRIBE/PING/QUIT are allowed
        if (conn.pubsub_mode) {
            conn.write_buf.appendSlice("-ERR only (P)SUBSCRIBE / (P)UNSUBSCRIBE / PING / QUIT allowed in this context\r\n") catch {};
            return;
        }

        // ── WATCH/UNWATCH (optimistic locking) ────────────────────────
        if (args[0].len == 5 and equalsAsciiUpper(args[0], "WATCH")) {
            self.handleWatch(conn, args);
            return;
        }
        if (args[0].len == 7 and equalsAsciiUpper(args[0], "UNWATCH")) {
            self.clearWatches(conn);
            conn.write_buf.appendSlice("+OK\r\n") catch {};
            return;
        }

        // ── MULTI/EXEC/DISCARD transactions ─────────────────────────────
        if (args[0].len == 5 and equalsAsciiUpper(args[0], "MULTI")) {
            if (conn.tx_queue != null) {
                conn.write_buf.appendSlice("-ERR MULTI calls can not be nested\r\n") catch {};
            } else {
                conn.tx_queue = std.array_list.Managed(Connection.TxCommand).init(self.allocator);
                conn.write_buf.appendSlice("+OK\r\n") catch {};
            }
            return;
        }
        if (args[0].len == 7 and equalsAsciiUpper(args[0], "DISCARD")) {
            if (conn.tx_queue) |*q| {
                for (q.items) |*cmd| cmd.deinit(self.allocator);
                q.deinit();
                conn.tx_queue = null;
                self.clearWatches(conn);
                conn.write_buf.appendSlice("+OK\r\n") catch {};
            } else {
                conn.write_buf.appendSlice("-ERR DISCARD without MULTI\r\n") catch {};
            }
            return;
        }
        if (args[0].len == 4 and equalsAsciiUpper(args[0], "EXEC")) {
            self.handleExec(conn);
            return;
        }

        // If inside MULTI, queue the command
        if (conn.tx_queue) |*q| {
            // Copy args since they'll be freed after this call
            const owned_args = self.allocator.alloc([]u8, args.len) catch {
                conn.write_buf.appendSlice("-ERR out of memory\r\n") catch {};
                return;
            };
            for (args, 0..) |arg, i| {
                owned_args[i] = self.allocator.dupe(u8, arg) catch {
                    // Clean up partially allocated
                    for (owned_args[0..i]) |a| self.allocator.free(a);
                    self.allocator.free(owned_args);
                    conn.write_buf.appendSlice("-ERR out of memory\r\n") catch {};
                    return;
                };
            }
            q.append(.{ .args = owned_args }) catch {
                for (owned_args) |a| self.allocator.free(a);
                self.allocator.free(owned_args);
                conn.write_buf.appendSlice("-ERR out of memory\r\n") catch {};
                return;
            };
            conn.write_buf.appendSlice("+QUEUED\r\n") catch {};
            return;
        }

        // ── Connection-level commands (handled in worker, not CommandHandler) ──

        // CLIENT subcommands
        if (args[0].len == 6 and equalsAsciiUpper(args[0], "CLIENT")) {
            self.handleClient(conn, args);
            return;
        }

        // CONFIG GET/SET — return sensible defaults for client compatibility
        if (args[0].len == 6 and equalsAsciiUpper(args[0], "CONFIG")) {
            self.handleConfig(conn, args);
            return;
        }

        // UNLINK — non-blocking DEL (we alias to DEL since our DEL is already fast)
        if (args[0].len == 6 and equalsAsciiUpper(args[0], "UNLINK")) {
            if (self.ckv) |ckv| {
                var count: i64 = 0;
                for (args[1..]) |user_key| {
                    const ns = nsKey(conn.selected_db, user_key) orelse continue;
                    const stale = ckv.deleteStale(ns);
                    if (stale.stale_key) |k| self.allocator.free(k);
                    if (stale.stale_val) |v| self.allocator.free(v);
                    if (stale.found) count += 1;
                }
                if (count > 0) {
                    if (self.aof) |a| a.logCommand(args);
                    self.maybeBroadcast(args);
                }
                writeIntTo(&conn.write_buf, count);
                return;
            }
            // Fallthrough to CommandHandler (DEL logic)
        }

        // TIME — server time as [seconds, microseconds]
        if (args[0].len == 4 and equalsAsciiUpper(args[0], "TIME")) {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            conn.write_buf.appendSlice("*2\r\n") catch {};
            var buf: [32]u8 = undefined;
            const sec_s = std.fmt.bufPrint(&buf, "{d}", .{ts.sec}) catch "0";
            writeBulkTo(&conn.write_buf, sec_s);
            const usec: i64 = @divTrunc(@as(i64, @intCast(ts.nsec)), 1000);
            const usec_s = std.fmt.bufPrint(&buf, "{d}", .{usec}) catch "0";
            writeBulkTo(&conn.write_buf, usec_s);
            return;
        }

        // OBJECT ENCODING/IDLETIME/HELP
        if (args[0].len == 6 and equalsAsciiUpper(args[0], "OBJECT")) {
            self.handleObject(conn, args);
            return;
        }

        // COPY src dst [REPLACE]
        if (args[0].len == 4 and equalsAsciiUpper(args[0], "COPY")) {
            self.handleCopy(conn, args);
            return;
        }

        // WAIT numreplicas timeout — wait for replication ack
        if (args[0].len == 4 and equalsAsciiUpper(args[0], "WAIT")) {
            // Return current follower count (best-effort — we don't have per-write ack yet)
            var follower_count: i64 = 0;
            if (self.repl_leader) |rl| {
                follower_count = @intCast(rl.follower_count.load(.acquire));
            } else if (self.repl_follower) |rf| {
                if (rf.getPromotedLeader()) |pl| {
                    follower_count = @intCast(pl.follower_count.load(.acquire));
                }
            }
            writeIntTo(&conn.write_buf, follower_count);
            return;
        }

        // RESET — reset connection state
        if (args[0].len == 5 and equalsAsciiUpper(args[0], "RESET")) {
            conn.selected_db = 0;
            if (conn.client_name) |name| self.allocator.free(name);
            conn.client_name = null;
            if (conn.pubsub_mode) {
                if (self.pubsub) |ps| ps.unsubscribeAll(conn.fd);
                conn.pubsub_mode = false;
            }
            if (conn.tx_queue) |*q| {
                for (q.items) |*cmd| cmd.deinit(self.allocator);
                q.deinit();
                conn.tx_queue = null;
            }
            conn.write_buf.appendSlice("+RESET\r\n") catch {};
            return;
        }

        // PSUBSCRIBE — pattern subscribe (basic glob pattern matching)
        if (self.pubsub) |ps| {
            if (args[0].len == 10 and equalsAsciiUpper(args[0], "PSUBSCRIBE")) {
                self.handlePSubscribe(conn, args, ps);
                return;
            }
            if (args[0].len == 12 and equalsAsciiUpper(args[0], "PUNSUBSCRIBE")) {
                self.handlePUnsubscribe(conn, args, ps);
                return;
            }
        }

        // ── Replication replay marker: _REPL prefix means this is a replayed
        // command. Execute locally, skip forwarding AND broadcasting.
        if (args.len >= 2 and std.mem.eql(u8, args[0], "_REPL")) {
            const real_args = args[1..];
            // Execute directly — bypass forwarding and broadcasting
            if (self.ckv) |ckv| {
                if (self.executeHotFast(conn, real_args, ckv)) return;
            }
            self.executeCommand(conn, real_args);
            return;
        }

        // ── Follower write forwarding: send writes to leader ──
        // If this follower has been promoted to leader, skip forwarding and execute locally.
        if (self.repl_follower) |rf| {
            if (!rf.promoted.load(.acquire) and replication.isWriteCommand(args)) {
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
            if (self.executeHotFast(conn, args, ckv)) {
                // Leader: broadcast write mutations to followers
                self.maybeBroadcast(args);
                return;
            }
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
        self.maybeBroadcast(args);
    }

    /// If this node is the leader and the command is a write, broadcast to followers.
    fn maybeBroadcast(self: *Worker, args: []const []const u8) void {
        // Check original leader pointer, or promoted leader if this was a follower
        var rl = self.repl_leader;
        if (rl == null) {
            if (self.repl_follower) |rf| {
                rl = rf.getPromotedLeader();
            }
        }
        const leader = rl orelse return;
        if (!replication.isWriteCommand(args)) return;

        // Encode command as write_forward payload (same format followers use)
        const payload = @import("../cluster/protocol.zig").encodeWriteForward(self.allocator, args) catch return;
        defer self.allocator.free(payload);
        std.debug.print("[repl-broadcast] cmd={s} payload_len={d}\n", .{ if (args.len > 0) args[0] else "?", payload.len });
        leader.broadcastMutation(payload);
    }

    // ── Pool helpers ──────────────────────────────────────────────────


    // ── Flush all stores ──────────────────────────────────────────────

    fn flushAllStores(self: *Worker, ckv: *ConcurrentKV) void {
        ckv.flushdb();
        // Flush data stores: free all data but retain pre-allocated HashMap capacity
        if (self.list_store) |ls| ls.flush();
        if (self.hash_store) |hs| hs.flush();
        if (self.set_store) |ss| ss.flush();
        if (self.sorted_set_store) |zs| zs.flush();
    }

    // ── WATCH/UNWATCH ─────────────────────────────────────────────────

    fn handleWatch(self: *Worker, conn: *Connection, args: []const []const u8) void {
        if (args.len < 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'WATCH'\r\n") catch {};
            return;
        }
        if (conn.tx_queue != null) {
            conn.write_buf.appendSlice("-ERR WATCH inside MULTI is not allowed\r\n") catch {};
            return;
        }
        const wm = self.watch_map orelse {
            conn.write_buf.appendSlice("+OK\r\n") catch {};
            return;
        };
        if (conn.watched_keys == null) {
            conn.watched_keys = std.array_list.Managed(WatchEntry).init(self.allocator);
        }
        var wk = &conn.watched_keys.?;
        for (args[1..]) |user_key| {
            const ns = nsKey(conn.selected_db, user_key) orelse continue;
            const version = wm.getVersion(ns);
            const key_copy = self.allocator.dupe(u8, ns) catch continue;
            wk.append(.{ .key = key_copy, .version = version }) catch {
                self.allocator.free(key_copy);
            };
        }
        // Track active watches for fast bumpVersion skip
        _ = wm.active_watches.fetchAdd(1, .monotonic);
        conn.write_buf.appendSlice("+OK\r\n") catch {};
    }

    fn clearWatches(self: *Worker, conn: *Connection) void {
        if (conn.watched_keys) |*wk| {
            if (wk.items.len > 0) {
                if (self.watch_map) |wm| _ = wm.active_watches.fetchSub(1, .monotonic);
            }
            for (wk.items) |entry| self.allocator.free(entry.key);
            wk.deinit();
            conn.watched_keys = null;
        }
        conn.watch_dirty = false;
    }

    /// Check if any watched key was modified since WATCH. Returns true if dirty.
    fn isWatchDirty(self: *Worker, conn: *Connection) bool {
        if (conn.watch_dirty) return true;
        const wm = self.watch_map orelse return false;
        const wk = conn.watched_keys orelse return false;
        for (wk.items) |entry| {
            if (wm.getVersion(entry.key) != entry.version) return true;
        }
        return false;
    }

    /// Bump version for a key after a write (for WATCH tracking).
    fn bumpWatchVersion(self: *Worker, selected_db: u8, user_key: []const u8) void {
        const wm = self.watch_map orelse return;
        const ns = nsKey(selected_db, user_key) orelse return;
        wm.bumpVersion(ns);
    }

    // ── CLIENT subcommand handler ──────────────────────────────────────

    fn handleClient(self: *Worker, conn: *Connection, args: []const []const u8) void {
        if (args.len < 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'CLIENT'\r\n") catch {};
            return;
        }
        if (equalsAsciiUpper(args[1], "SETNAME")) {
            if (args.len < 3) {
                conn.write_buf.appendSlice("-ERR wrong number of arguments for 'CLIENT SETNAME'\r\n") catch {};
                return;
            }
            if (conn.client_name) |old| self.allocator.free(old);
            conn.client_name = self.allocator.dupe(u8, args[2]) catch null;
            conn.write_buf.appendSlice("+OK\r\n") catch {};
        } else if (equalsAsciiUpper(args[1], "GETNAME")) {
            if (conn.client_name) |name| {
                writeBulkTo(&conn.write_buf, name);
            } else {
                conn.write_buf.appendSlice("$-1\r\n") catch {};
            }
        } else if (equalsAsciiUpper(args[1], "ID")) {
            writeIntTo(&conn.write_buf, @intCast(conn.client_id));
        } else if (equalsAsciiUpper(args[1], "LIST")) {
            // Minimal CLIENT LIST: return info for connections on this worker
            var buf = std.array_list.Managed(u8).init(self.allocator);
            defer buf.deinit();
            var it = self.conns.iterator();
            while (it.next()) |entry| {
                const c = entry.value_ptr.*;
                var line_buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "id={d} fd={d} db={d} name={s}\n", .{
                    c.client_id, c.fd, c.selected_db, if (c.client_name) |n| n else "",
                }) catch continue;
                buf.appendSlice(line) catch {};
            }
            writeBulkTo(&conn.write_buf, buf.items);
        } else if (equalsAsciiUpper(args[1], "INFO")) {
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "id={d} fd={d} db={d} name={s}\n", .{
                conn.client_id, conn.fd, conn.selected_db, if (conn.client_name) |n| n else "",
            }) catch "";
            writeBulkTo(&conn.write_buf, line);
        } else {
            conn.write_buf.appendSlice("+OK\r\n") catch {};
        }
    }

    // ── CONFIG subcommand handler ────────────────────────────────────

    fn handleConfig(self: *Worker, conn: *Connection, args: []const []const u8) void {
        _ = self;
        if (args.len < 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'CONFIG'\r\n") catch {};
            return;
        }
        if (equalsAsciiUpper(args[1], "GET")) {
            if (args.len < 3) {
                conn.write_buf.appendSlice("*0\r\n") catch {};
                return;
            }
            // Return known config keys, empty array for unknown
            const key = args[2];
            if (equalsAsciiUpper(key, "SAVE") or equalsAsciiUpper(key, "DATABASES") or
                equalsAsciiUpper(key, "MAXMEMORY") or equalsAsciiUpper(key, "APPENDONLY"))
            {
                conn.write_buf.appendSlice("*2\r\n") catch {};
                writeBulkTo(&conn.write_buf, key);
                writeBulkTo(&conn.write_buf, "");
            } else if (key.len == 1 and key[0] == '*') {
                // CONFIG GET * — return empty (some clients do this on connect)
                conn.write_buf.appendSlice("*0\r\n") catch {};
            } else {
                conn.write_buf.appendSlice("*0\r\n") catch {};
            }
        } else if (equalsAsciiUpper(args[1], "SET")) {
            // Accept but ignore — Vex doesn't support runtime config changes
            conn.write_buf.appendSlice("+OK\r\n") catch {};
        } else if (equalsAsciiUpper(args[1], "RESETSTAT")) {
            conn.write_buf.appendSlice("+OK\r\n") catch {};
        } else {
            conn.write_buf.appendSlice("-ERR unknown CONFIG subcommand\r\n") catch {};
        }
    }

    // ── OBJECT subcommand handler ────────────────────────────────────

    fn handleObject(self: *Worker, conn: *Connection, args: []const []const u8) void {
        if (args.len < 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'OBJECT'\r\n") catch {};
            return;
        }
        if (equalsAsciiUpper(args[1], "ENCODING")) {
            if (args.len < 3) {
                conn.write_buf.appendSlice("-ERR wrong number of arguments\r\n") catch {};
                return;
            }
            const ns = nsKey(conn.selected_db, args[2]);
            if (ns != null and self.ckv != null and self.ckv.?.exists(ns.?)) {
                writeBulkTo(&conn.write_buf, "embstr");
            } else {
                conn.write_buf.appendSlice("-ERR no such key\r\n") catch {};
            }
        } else if (equalsAsciiUpper(args[1], "IDLETIME")) {
            if (args.len < 3) {
                conn.write_buf.appendSlice("-ERR wrong number of arguments\r\n") catch {};
                return;
            }
            // We don't track idle time precisely in ConcurrentKV, return 0
            const ns = nsKey(conn.selected_db, args[2]);
            if (ns != null and self.ckv != null and self.ckv.?.exists(ns.?)) {
                writeIntTo(&conn.write_buf, 0);
            } else {
                conn.write_buf.appendSlice("-ERR no such key\r\n") catch {};
            }
        } else if (equalsAsciiUpper(args[1], "HELP")) {
            conn.write_buf.appendSlice("*3\r\n") catch {};
            writeBulkTo(&conn.write_buf, "OBJECT ENCODING <key> - Return encoding of the value stored at <key>");
            writeBulkTo(&conn.write_buf, "OBJECT IDLETIME <key> - Return idle time of <key> (seconds since last access)");
            writeBulkTo(&conn.write_buf, "OBJECT HELP - Return this help message");
        } else {
            conn.write_buf.appendSlice("-ERR unknown OBJECT subcommand\r\n") catch {};
        }
    }

    // ── COPY handler ────────────────────────────────────────────────

    fn handleCopy(self: *Worker, conn: *Connection, args: []const []const u8) void {
        if (args.len < 3) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'COPY'\r\n") catch {};
            return;
        }
        const ckv = self.ckv orelse {
            conn.write_buf.appendSlice("-ERR not available\r\n") catch {};
            return;
        };
        const src = nsKey(conn.selected_db, args[1]) orelse {
            writeIntTo(&conn.write_buf, 0);
            return;
        };
        const dst = nsKey(conn.selected_db, args[2]) orelse {
            writeIntTo(&conn.write_buf, 0);
            return;
        };

        // Check REPLACE flag
        var replace = false;
        if (args.len >= 4 and equalsAsciiUpper(args[3], "REPLACE")) {
            replace = true;
        }

        // Check if src exists — get returns OwnedValue (allocated copy)
        const owned = ckv.get(src) orelse {
            writeIntTo(&conn.write_buf, 0);
            return;
        };
        defer owned.deinit();

        // Check if dst exists and REPLACE not set
        if (!replace and ckv.exists(dst)) {
            writeIntTo(&conn.write_buf, 0);
            return;
        }

        // Copy value to destination
        const key_copy = self.allocator.dupe(u8, dst) catch {
            writeIntTo(&conn.write_buf, 0);
            return;
        };
        const val_copy = self.allocator.dupe(u8, owned.data) catch {
            self.allocator.free(key_copy);
            writeIntTo(&conn.write_buf, 0);
            return;
        };
        const stale = ckv.setPrealloc(dst, key_copy, val_copy, 0);
        if (stale.stale_val) |v| self.allocator.free(v);
        if (stale.stale_key) |k| self.allocator.free(k);
        writeIntTo(&conn.write_buf, 1);
    }

    // ── PSUBSCRIBE / PUNSUBSCRIBE handlers ──────────────────────────

    fn handlePSubscribe(self: *Worker, conn: *Connection, args: []const []const u8, ps: *PubSubRegistry) void {
        _ = self;
        if (args.len < 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'PSUBSCRIBE'\r\n") catch {};
            return;
        }
        conn.pubsub_mode = true;
        // Store pattern subscriptions as "pattern:<pat>" channels
        for (args[1..]) |pattern| {
            var key_buf: [256]u8 = undefined;
            const pkey = std.fmt.bufPrint(&key_buf, "pattern:{s}", .{pattern}) catch continue;
            ps.subscribe(pkey, conn.fd) catch continue;
            conn.write_buf.appendSlice("*3\r\n$10\r\npsubscribe\r\n") catch {};
            writeBulkTo(&conn.write_buf, pattern);
            writeIntTo(&conn.write_buf, 1);
        }
    }

    fn handlePUnsubscribe(self: *Worker, conn: *Connection, args: []const []const u8, ps: *PubSubRegistry) void {
        _ = self;
        if (args.len < 2) {
            ps.unsubscribeAll(conn.fd);
            conn.pubsub_mode = false;
            conn.write_buf.appendSlice("*3\r\n$12\r\npunsubscribe\r\n$-1\r\n:0\r\n") catch {};
            return;
        }
        for (args[1..]) |pattern| {
            var key_buf: [256]u8 = undefined;
            const pkey = std.fmt.bufPrint(&key_buf, "pattern:{s}", .{pattern}) catch continue;
            ps.unsubscribe(pkey, conn.fd);
            conn.write_buf.appendSlice("*3\r\n$12\r\npunsubscribe\r\n") catch {};
            writeBulkTo(&conn.write_buf, pattern);
            writeIntTo(&conn.write_buf, 0);
        }
        conn.pubsub_mode = false;
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

    // ── Pub/Sub handlers ─────────────────────────────────────────────

    fn handleSubscribe(self: *Worker, conn: *Connection, args: []const []const u8, ps: *PubSubRegistry) void {
        if (args.len < 2) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'SUBSCRIBE'\r\n") catch {};
            return;
        }
        conn.pubsub_mode = true;
        for (args[1..]) |channel| {
            ps.subscribe(channel, conn.fd) catch continue;
            // RESP push: *3\r\n$9\r\nsubscribe\r\n$<chanlen>\r\n<chan>\r\n:<count>\r\n
            conn.write_buf.appendSlice("*3\r\n$9\r\nsubscribe\r\n") catch {};
            writeBulkTo(&conn.write_buf, channel);
            writeIntTo(&conn.write_buf, 1);
        }
        _ = self;
    }

    fn handleUnsubscribe(self: *Worker, conn: *Connection, args: []const []const u8, ps: *PubSubRegistry) void {
        _ = self;
        if (args.len < 2) {
            // Unsubscribe from all channels
            ps.unsubscribeAll(conn.fd);
            conn.pubsub_mode = false;
            conn.write_buf.appendSlice("*3\r\n$11\r\nunsubscribe\r\n$-1\r\n:0\r\n") catch {};
            return;
        }
        for (args[1..]) |channel| {
            ps.unsubscribe(channel, conn.fd);
            conn.write_buf.appendSlice("*3\r\n$11\r\nunsubscribe\r\n") catch {};
            writeBulkTo(&conn.write_buf, channel);
            writeIntTo(&conn.write_buf, 0);
        }
        conn.pubsub_mode = false;
    }

    fn handlePublish(self: *Worker, conn: *Connection, args: []const []const u8, ps: *PubSubRegistry) void {
        if (args.len < 3) {
            conn.write_buf.appendSlice("-ERR wrong number of arguments for 'PUBLISH'\r\n") catch {};
            return;
        }
        const channel = args[1];
        const message = args[2];

        // Get subscriber fds
        var subs = std.array_list.Managed(i32).init(self.allocator);
        defer subs.deinit();
        ps.getSubscribers(channel, &subs);

        // Format the push message: *3\r\n$7\r\nmessage\r\n$<chanlen>\r\n<chan>\r\n$<msglen>\r\n<msg>\r\n
        var push_buf = std.array_list.Managed(u8).init(self.allocator);
        defer push_buf.deinit();
        push_buf.appendSlice("*3\r\n$7\r\nmessage\r\n") catch {};
        writeBulkTo(&push_buf, channel);
        writeBulkTo(&push_buf, message);

        // Write to all subscribers (direct write to their fds)
        for (subs.items) |fd| {
            if (self.conns.get(fd)) |sub_conn| {
                sub_conn.write_buf.appendSlice(push_buf.items) catch {};
            } else {
                // Subscriber on different worker — write directly to fd
                _ = std.c.write(fd, push_buf.items.ptr, push_buf.items.len);
            }
        }

        // Reply with count of subscribers who received the message
        writeIntTo(&conn.write_buf, @intCast(subs.items.len));
    }

    /// EXEC: execute all queued commands atomically under engine lock.
    fn handleExec(self: *Worker, conn: *Connection) void {
        var q = conn.tx_queue orelse {
            conn.write_buf.appendSlice("-ERR EXEC without MULTI\r\n") catch {};
            return;
        };

        // WATCH check: if any watched key was modified, abort the transaction
        if (self.isWatchDirty(conn)) {
            // Abort: return nil array (Redis convention for WATCH failure)
            conn.write_buf.appendSlice("*-1\r\n") catch {};
            for (q.items) |*cmd| cmd.deinit(self.allocator);
            q.deinit();
            conn.tx_queue = null;
            self.clearWatches(conn);
            return;
        }

        // Write array header for the number of queued commands
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "*{d}\r\n", .{q.items.len}) catch {
            conn.write_buf.appendSlice("-ERR internal error\r\n") catch {};
            return;
        };
        conn.write_buf.appendSlice(h) catch {};

        // Execute all commands under engine lock
        while (!self.kv_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.kv_mutex.unlock();

        for (q.items) |cmd| {
            // Cast [][]u8 to []const []const u8
            const args: []const []const u8 = @ptrCast(cmd.args);

            if (self.ckv) |ckv| {
                if (self.executeHotFast(conn, args, ckv)) continue;
            }

            // Fall back to CommandHandler for non-hot-path commands
            var selected_db = std.atomic.Value(u8).init(conn.selected_db);
            var handler = CommandHandler.init(
                self.allocator, self.io, self.kv, self.graph, self.aof,
                &selected_db, self.keys_mode,
            );
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.allocator);
            var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &list);
            defer aw.deinit();
            handler.execute(args, &aw.writer) catch {
                conn.write_buf.appendSlice("-ERR internal error\r\n") catch {};
                continue;
            };
            conn.selected_db = selected_db.load(.monotonic);
            conn.write_buf.appendSlice(aw.written()) catch {};
        }

        // Clean up transaction queue + watched keys
        for (q.items) |*cmd| cmd.deinit(self.allocator);
        q.deinit();
        conn.tx_queue = null;
        self.clearWatches(conn);
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
                    // Ultra-fast GET with SeqLock — lock-free for inline values.
                    const user_key = args[1];
                    const db = conn.selected_db;
                    if (db >= 16) return false;
                    const prefix = DB_PREFIXES[db];
                    const KVS = @import("../engine/kv.zig").KVStore;
                    const S = struct { threadlocal var buf: [512]u8 = undefined; };
                    const total = prefix.len + user_key.len;
                    if (total > S.buf.len) return false;
                    @memcpy(S.buf[0..prefix.len], prefix);
                    @memcpy(S.buf[prefix.len..total], user_key);
                    const ns_key = S.buf[0..total];

                    const stripe = ckv.getStripePublic(ns_key);
                    const entry_opt = stripe.map.getPtr(ns_key);
                    if (entry_opt == null) {
                        conn.write_buf.appendSlice("$-1\r\n") catch {};
                        return true;
                    }
                    const entry = entry_opt.?;

                    // Check deleted/expired (these flags are set under write lock, safe to read)
                    if (entry.flags.deleted or
                        (entry.flags.has_ttl and ckv.cached_now_ms > entry.expires_at))
                    {
                        conn.write_buf.appendSlice("$-1\r\n") catch {};
                        return true;
                    }

                    // Integer path: read int_value atomically (8-byte aligned, atomic on 64-bit)
                    if (entry.flags.is_integer) {
                        const int_val = entry.int_value;
                        var int_buf: [24]u8 = undefined;
                        const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{int_val}) catch return false;
                        var hdr_buf: [32]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hdr_buf, "${d}\r\n", .{int_str.len}) catch return false;
                        conn.write_buf.ensureTotalCapacity(conn.write_buf.items.len + hdr.len + int_str.len + 2) catch {};
                        conn.write_buf.appendSliceAssumeCapacity(hdr);
                        conn.write_buf.appendSliceAssumeCapacity(int_str);
                        conn.write_buf.appendSliceAssumeCapacity("\r\n");
                        return true;
                    }

                    // Inline value path: SeqLock — NO pthread_rwlock needed
                    if (entry.flags.is_inline) {
                        var val_copy: [KVS.INLINE_BUF_SIZE]u8 = undefined;
                        var vlen: u8 = undefined;

                        // SeqLock read: retry if writer was active
                        var attempts: u32 = 0;
                        while (attempts < 64) : (attempts += 1) {
                            const s1 = entry.seq.load(.acquire);
                            if (s1 & 1 != 0) { // odd = write in progress
                                std.atomic.spinLoopHint();
                                continue;
                            }
                            vlen = entry.inline_len;
                            @memcpy(val_copy[0..vlen], entry.inline_buf[0..vlen]);
                            const s2 = entry.seq.load(.acquire);
                            if (s1 == s2) break; // consistent read
                            std.atomic.spinLoopHint();
                        }

                        var hdr_buf: [32]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hdr_buf, "${d}\r\n", .{vlen}) catch return false;
                        conn.write_buf.ensureTotalCapacity(conn.write_buf.items.len + hdr.len + vlen + 2) catch {};
                        conn.write_buf.appendSliceAssumeCapacity(hdr);
                        conn.write_buf.appendSliceAssumeCapacity(val_copy[0..vlen]);
                        conn.write_buf.appendSliceAssumeCapacity("\r\n");
                        return true;
                    }

                    // Large value fallback: read lock (rare — values > 128 bytes)
                    ckv.readLockStripePublic(stripe);
                    const vlen = entry.value.len;
                    var val_stack: [4096]u8 = undefined;
                    if (vlen <= val_stack.len) {
                        @memcpy(val_stack[0..vlen], entry.value);
                        ckv.readUnlockStripePublic(stripe);
                        var hdr_buf: [32]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hdr_buf, "${d}\r\n", .{vlen}) catch return false;
                        conn.write_buf.ensureTotalCapacity(conn.write_buf.items.len + hdr.len + vlen + 2) catch {};
                        conn.write_buf.appendSliceAssumeCapacity(hdr);
                        conn.write_buf.appendSliceAssumeCapacity(val_stack[0..vlen]);
                        conn.write_buf.appendSliceAssumeCapacity("\r\n");
                    } else {
                        conn.write_buf.ensureTotalCapacity(conn.write_buf.items.len + vlen + 40) catch {};
                        var hdr_buf: [32]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hdr_buf, "${d}\r\n", .{vlen}) catch {
                            ckv.readUnlockStripePublic(stripe);
                            return false;
                        };
                        conn.write_buf.appendSliceAssumeCapacity(hdr);
                        conn.write_buf.appendSliceAssumeCapacity(entry.value);
                        conn.write_buf.appendSliceAssumeCapacity("\r\n");
                        ckv.readUnlockStripePublic(stripe);
                    }
                    return true;
                },
                'S' => if (args.len >= 3 and equalsAsciiUpper(cmd, "SET")) {
                    const KVS = @import("../engine/kv.zig").KVStore;
                    const ns_key = nsKey(conn.selected_db, args[1]) orelse return false;
                    const value = args[2];

                    var expires: i64 = 0;
                    if (args.len >= 5 and equalsAsciiUpper(args[3], "EX")) {
                        const t = std.fmt.parseInt(i64, args[4], 10) catch return false;
                        expires = ckv.nowMillis() + t * 1000;
                    } else if (args.len >= 5 and equalsAsciiUpper(args[3], "PX")) {
                        const t = std.fmt.parseInt(i64, args[4], 10) catch return false;
                        expires = ckv.nowMillis() + t;
                    }

                    // Lock-free fast path: update existing inline entry via SeqLock
                    if (value.len <= KVS.INLINE_BUF_SIZE and expires == 0) {
                        const stripe = ckv.getStripePublic(ns_key);
                        const entry_opt = stripe.map.getPtr(ns_key);
                        if (entry_opt) |entry| {
                            if (!entry.flags.deleted) {
                                // SeqLock write: bump to odd, memcpy, bump to even
                                _ = entry.seq.fetchAdd(1, .release);
                                @memcpy(entry.inline_buf[0..value.len], value);
                                entry.inline_len = @intCast(value.len);
                                entry.value = entry.inline_buf[0..value.len];
                                entry.flags = .{ .is_inline = true };
                                entry.expires_at = 0;
                                _ = entry.seq.fetchAdd(1, .release);

                                if (self.aof) |a| a.logCommand(args);
                                self.bumpWatchVersion(conn.selected_db, args[1]);
                                conn.write_buf.appendSlice(ct.resp_ok) catch {};
                                return true;
                            }
                        }
                    }

                    // Fallback: new key or large value — use write lock
                    const key_copy = self.allocator.dupe(u8, ns_key) catch return false;
                    const val_copy = self.allocator.dupe(u8, value) catch {
                        self.allocator.free(key_copy);
                        return false;
                    };
                    const stale = ckv.setPrealloc(ns_key, key_copy, val_copy, expires);
                    if (stale.stale_val) |v| self.allocator.free(v);
                    if (stale.stale_key) |k| self.allocator.free(k);
                    if (self.aof) |a| a.logCommand(args);
                    self.bumpWatchVersion(conn.selected_db, args[1]);
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
                        self.bumpWatchVersion(conn.selected_db, args[1]);
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
            4 => switch (first) {
                'P' => if (equalsAsciiUpper(cmd, "PING")) {
                    if (args.len > 1) writeBulkTo(&conn.write_buf, args[1]) else conn.write_buf.appendSlice(ct.resp_pong) catch {};
                    return true;
                },
                'I' => if (args.len >= 2 and equalsAsciiUpper(cmd, "INCR")) {
                    // Ultra-fast INCR: inline nsKey + batch reservation
                    const user_key = args[1];
                    const db = conn.selected_db;
                    if (db >= 16) return false;
                    const prefix = DB_PREFIXES[db];
                    const IK = struct { threadlocal var buf: [512]u8 = undefined; };
                    const total_len = prefix.len + user_key.len;
                    if (total_len > IK.buf.len) return false;
                    @memcpy(IK.buf[0..prefix.len], prefix);
                    @memcpy(IK.buf[prefix.len..total_len], user_key);
                    const ns_key = IK.buf[0..total_len];

                    // Lock-free fast path: atomic INCR on existing integer key
                    const stripe = ckv.getStripePublic(ns_key);
                    const entry_opt = stripe.map.getPtr(ns_key);
                    if (entry_opt) |entry| {
                        if (entry.flags.is_integer and !entry.flags.deleted) {
                            // Single atomic instruction — minimum possible synchronization
                            const int_ptr: *i64 = &entry.int_value;
                            const new_val = @atomicRmw(i64, int_ptr, .Add, 1, .monotonic) + 1;
                            if (self.aof) |a| a.logCommand(args);
                            var incr_resp: [32]u8 = undefined;
                            const ir = std.fmt.bufPrint(&incr_resp, ":{d}\r\n", .{new_val}) catch return false;
                            conn.write_buf.appendSlice(ir) catch {};
                            return true;
                        }
                    }

                    // Fallback: new key or non-integer — use write lock
                    const new_val = ckv.incrBy(ns_key, 1) catch |err| {
                        if (err == error.NotAnInteger) {
                            conn.write_buf.appendSlice("-ERR value is not an integer or out of range\r\n") catch {};
                        } else {
                            conn.write_buf.appendSlice("-ERR internal error\r\n") catch {};
                        }
                        return true;
                    };
                    if (self.aof) |a| a.logCommand(args);
                    self.bumpWatchVersion(conn.selected_db, args[1]);
                    writeIntTo(&conn.write_buf, new_val);
                    return true;
                },
                'H' => {
                    if (args.len >= 4 and equalsAsciiUpper(cmd, "HSET")) {
                        if (self.hash_store) |hs| {
                            const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                            const dsl = self.ds_locks orelse return false;
                            // Pre-alloc field+value pairs OUTSIDE the lock
                            const fv = args[2..];
                            var owned_buf: [32][]u8 = undefined;
                            if (fv.len > owned_buf.len) return false;
                            for (fv, 0..) |v, i| {
                                owned_buf[i] = self.allocator.dupe(u8, v) catch return false;
                            }
                            const owned = owned_buf[0..fv.len];
                            dsl.acquire(ns, self.id, &self.last_stripe);
                            const added = hs.hsetOwned(ns, owned) catch {
                                    for (owned) |o| self.allocator.free(o);
                                return false;
                            };
                            if (self.aof) |a| a.logCommand(args);
                            self.bumpWatchVersion(conn.selected_db, args[1]);
                            writeIntTo(&conn.write_buf, @intCast(added));
                            return true;
                        }
                    }
                    if (args.len >= 3 and equalsAsciiUpper(cmd, "HGET")) {
                        if (self.hash_store) |hs| {
                            const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                            const dsl = self.ds_locks orelse return false;
                            dsl.acquire(ns, self.id, &self.last_stripe);
                            if (hs.hget(ns, args[2])) |val| {
                                writeBulkTo(&conn.write_buf, val);
                            } else {
                                conn.write_buf.appendSlice("$-1\r\n") catch {};
                            }
                            return true;
                        }
                    }
                    if (args.len >= 2 and equalsAsciiUpper(cmd, "HLEN")) {
                        if (self.hash_store) |hs| {
                            const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                            const dsl = self.ds_locks orelse return false;
                            dsl.acquire(ns, self.id, &self.last_stripe);
                            writeIntTo(&conn.write_buf, @intCast(hs.hlen(ns)));
                            return true;
                        }
                    }
                },
                'L' => {
                    if (args.len >= 2 and equalsAsciiUpper(cmd, "LLEN")) {
                        if (self.list_store) |ls| {
                            const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                            const dsl = self.ds_locks orelse return false;
                            dsl.acquire(ns, self.id, &self.last_stripe);
                            writeIntTo(&conn.write_buf, @intCast(ls.llen(ns)));
                            return true;
                        }
                    }
                    if (args.len >= 2 and equalsAsciiUpper(cmd, "LPOP")) {
                        if (self.list_store) |ls| {
                            const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                            const dsl = self.ds_locks orelse return false;
                            dsl.acquire(ns, self.id, &self.last_stripe);
                            const val = ls.lpop(ns);
                            if (val) |v| {
                                if (self.aof) |a| a.logCommand(args);
                                writeBulkTo(&conn.write_buf, v);
                            } else {
                                conn.write_buf.appendSlice("$-1\r\n") catch {};
                            }
                            return true;
                        }
                    }
                },
                'R' => if (args.len >= 2 and equalsAsciiUpper(cmd, "RPOP")) {
                    if (self.list_store) |ls| {
                        const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                        const dsl = self.ds_locks orelse return false;
                        dsl.acquire(ns, self.id, &self.last_stripe);
                        const val = ls.rpop(ns);
                        if (val) |v| {
                            if (self.aof) |a| a.logCommand(args);
                            writeBulkTo(&conn.write_buf, v);
                        } else {
                            conn.write_buf.appendSlice("$-1\r\n") catch {};
                        }
                        return true;
                    }
                },
                'S' => if (args.len >= 3 and equalsAsciiUpper(cmd, "SADD")) {
                    if (self.set_store) |ss| {
                        const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                        const dsl = self.ds_locks orelse return false;
                        // Pre-alloc members OUTSIDE the lock
                        const members = args[2..];
                        var owned_buf: [16][]u8 = undefined;
                        if (members.len > owned_buf.len) return false;
                        for (members, 0..) |m, i| {
                            owned_buf[i] = self.allocator.dupe(u8, m) catch return false;
                        }
                        const owned = owned_buf[0..members.len];
                        dsl.acquire(ns, self.id, &self.last_stripe);
                        const added = ss.saddOwned(ns, owned) catch {
                            for (owned) |o| self.allocator.free(o);
                            return false;
                        };
                        if (self.aof) |a| a.logCommand(args);
                        self.bumpWatchVersion(conn.selected_db, args[1]);
                        writeIntTo(&conn.write_buf, @intCast(added));
                        return true;
                    }
                },
                'Z' => {
                    if (args.len >= 4 and equalsAsciiUpper(cmd, "ZADD")) {
                        if (self.sorted_set_store) |zs| {
                            const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                            const dsl = self.ds_locks orelse return false;
                            dsl.acquire(ns, self.id, &self.last_stripe);
                            const added = zs.zadd(ns, args[2..]) catch return false;
                            if (self.aof) |a| a.logCommand(args);
                            self.bumpWatchVersion(conn.selected_db, args[1]);
                            writeIntTo(&conn.write_buf, @intCast(added));
                            return true;
                        }
                    }
                },
                else => {},
            },
            5 => switch (first) {
                'L' => if (args.len >= 3 and equalsAsciiUpper(cmd, "LPUSH")) {
                    if (self.list_store) |ls| {
                        const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                        const dsl = self.ds_locks orelse return false;
                        dsl.acquire(ns, self.id, &self.last_stripe);
                        const list_len = ls.lpush(ns, args[2..]) catch return false;
                        if (self.aof) |a| a.logCommand(args);
                        self.bumpWatchVersion(conn.selected_db, args[1]);
                        writeIntTo(&conn.write_buf, @intCast(list_len));
                        return true;
                    }
                },
                'R' => if (args.len >= 3 and equalsAsciiUpper(cmd, "RPUSH")) {
                    if (self.list_store) |ls| {
                        const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                        const dsl = self.ds_locks orelse return false;
                        dsl.acquire(ns, self.id, &self.last_stripe);
                        const list_len = ls.rpush(ns, args[2..]) catch return false;
                        if (self.aof) |a| a.logCommand(args);
                        self.bumpWatchVersion(conn.selected_db, args[1]);
                        writeIntTo(&conn.write_buf, @intCast(list_len));
                        return true;
                    }
                },
                'S' => if (args.len >= 2 and equalsAsciiUpper(cmd, "SCARD")) {
                    if (self.set_store) |ss| {
                        const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                        const dsl = self.ds_locks orelse return false;
                        dsl.acquire(ns, self.id, &self.last_stripe);
                        writeIntTo(&conn.write_buf, @intCast(ss.scard(ns)));
                        return true;
                    }
                },
                'Z' => if (args.len >= 2 and equalsAsciiUpper(cmd, "ZCARD")) {
                    if (self.sorted_set_store) |zs| {
                        const ns = nsKey(conn.selected_db, args[1]) orelse return false;
                        const dsl = self.ds_locks orelse return false;
                        dsl.acquire(ns, self.id, &self.last_stripe);
                        writeIntTo(&conn.write_buf, @intCast(zs.zcard(ns)));
                        return true;
                    }
                },
                else => {},
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
                    self.flushAllStores(ckv);
                    conn.write_buf.appendSlice(ct.resp_ok) catch {};
                    return true;
                },
                else => {},
            },
            8 => if (first == 'F' and equalsAsciiUpper(cmd, "FLUSHALL")) {
                self.flushAllStores(ckv);
                conn.write_buf.appendSlice(ct.resp_ok) catch {};
                return true;
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
        handler.list_store = self.list_store;
        handler.hash_store = self.hash_store;
        handler.set_store = self.set_store;
        handler.sorted_set_store = self.sorted_set_store;

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

    /// Direct write attempt — avoids enableWrite/disableWrite syscalls.
    /// Most responses fit in the TCP send buffer, so write() succeeds immediately.
    /// Only registers for writable events if EAGAIN (partial write).
    fn directFlush(self: *Worker, conn: *Connection) void {
        // Cork the socket: buffer writes into one TCP segment (uncork sends).
        // macOS: TCP_NOPUSH (4), Linux: TCP_CORK (3). IPPROTO_TCP = 6.
        const cork_opt: c_int = if (comptime @import("builtin").os.tag == .linux) 3 else 4;
        const cork_on: c_int = 1;
        const cork_off: c_int = 0;
        if (conn.ssl == null) {
            _ = std.c.setsockopt(conn.fd, 6, cork_opt, @ptrCast(&cork_on), @sizeOf(c_int));
        }

        while (conn.write_offset < conn.write_buf.items.len) {
            const remaining = conn.write_buf.items[conn.write_offset..];
            const rc = self.connWrite(conn, remaining.ptr, remaining.len);
            if (rc < 0) {
                // Send buffer full — uncork and register for writable event
                if (conn.ssl == null) {
                    _ = std.c.setsockopt(conn.fd, 6, cork_opt, @ptrCast(&cork_off), @sizeOf(c_int));
                }
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

        // All data flushed — uncork to send the batched segment
        if (conn.ssl == null) {
            _ = std.c.setsockopt(conn.fd, 6, cork_opt, @ptrCast(&cork_off), @sizeOf(c_int));
        }
        conn.write_buf.clearRetainingCapacity();
        conn.write_offset = 0;
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

/// Precomputed DB prefix + user key concatenation.
/// Uses compile-time prefix table instead of runtime std.fmt.bufPrint.
fn nsKey(db: u8, user_key: []const u8) ?[]const u8 {
    // db 0 fast path: prefix is "0:" (2 bytes). Use threadlocal buffer.
    const S = struct {
        threadlocal var buf: [512]u8 = .{ '0', ':' } ++ ([_]u8{0} ** 510);
    };
    if (db >= 16) return null;
    if (db == 0) {
        // Fast path: just copy user_key after "0:" — skip prefix lookup
        if (2 + user_key.len > S.buf.len) return null;
        @memcpy(S.buf[2 .. 2 + user_key.len], user_key);
        return S.buf[0 .. 2 + user_key.len];
    }
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
    if (cmd.len >= 12 and equalsAsciiUpperPrefix(cmd[6..], "SETVEC")) return true;
    return false; // GETNODE, GETVEC, NEIGHBORS, TRAVERSE, PATH, WPATH, STATS, VECSEARCH, RAG = read
}

fn equalsAsciiUpper(s: []const u8, comptime upper: []const u8) bool {
    if (s.len != upper.len) return false;
    // Compare with mask: OR 0x20 to lowercase both sides, then compare.
    // Single pass, no branch per byte.
    comptime var mask: [upper.len]u8 = undefined;
    comptime for (upper, 0..) |c, i| { mask[i] = c | 0x20; };
    inline for (0..upper.len) |i| {
        if ((s[i] | 0x20) != mask[i]) return false;
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
    // Hand-rolled integer parse — ~2ns vs ~15ns for std.fmt.parseInt.
    // RESP integers are always small non-negative (argc, bulk length).
    var p = pos.*;
    var val: i64 = 0;
    var neg = false;
    if (p < data.len and data[p] == '-') { neg = true; p += 1; }
    if (p >= data.len or data[p] < '0' or data[p] > '9') return null;
    while (p + 1 < data.len) : (p += 1) {
        if (data[p] == '\r' and data[p + 1] == '\n') {
            pos.* = p + 2;
            return if (neg) -val else val;
        }
        if (data[p] < '0' or data[p] > '9') return null;
        val = val * 10 + @as(i64, data[p] - '0');
    }
    return null;
}

fn writeBulkTo(list: *std.array_list.Managed(u8), data: []const u8) void {
    // Fast path: small values (< 100 bytes) — build entire response in stack buffer, one appendSlice
    if (data.len < 100) {
        var buf: [140]u8 = undefined; // $XX\r\n + 100 bytes + \r\n
        var pos: usize = 0;
        buf[pos] = '$';
        pos += 1;
        if (data.len < 10) {
            buf[pos] = @intCast('0' + data.len);
            pos += 1;
        } else {
            buf[pos] = @intCast('0' + data.len / 10);
            buf[pos + 1] = @intCast('0' + data.len % 10);
            pos += 2;
        }
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
        @memcpy(buf[pos .. pos + data.len], data);
        pos += data.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
        list.appendSlice(buf[0..pos]) catch return;
        return;
    }
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "${d}\r\n", .{data.len}) catch return;
    list.appendSlice(h) catch return;
    list.appendSlice(data) catch return;
    list.appendSlice("\r\n") catch return;
}

/// Pre-computed RESP integer responses for 0-31 (covers most return values).
const RESP_INTS = blk: {
    @setEvalBranchQuota(10000);
    var table: [32][]const u8 = undefined;
    for (0..32) |i| {
        table[i] = std.fmt.comptimePrint(":{d}\r\n", .{i});
    }
    break :blk table;
};

fn writeIntTo(list: *std.array_list.Managed(u8), n: i64) void {
    if (n >= 0 and n < 32) {
        list.appendSlice(RESP_INTS[@intCast(n)]) catch return;
        return;
    }
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

// ─── Tests ──────────────────────────────────────────────────────────

test "PubSubRegistry subscribe and getSubscribers" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("news", 10);
    try ps.subscribe("news", 20);
    try ps.subscribe("sports", 30);

    var subs = std.array_list.Managed(i32).init(std.testing.allocator);
    defer subs.deinit();

    ps.getSubscribers("news", &subs);
    try std.testing.expectEqual(@as(usize, 2), subs.items.len);

    subs.clearRetainingCapacity();
    ps.getSubscribers("sports", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    try std.testing.expectEqual(@as(i32, 30), subs.items[0]);

    subs.clearRetainingCapacity();
    ps.getSubscribers("nonexistent", &subs);
    try std.testing.expectEqual(@as(usize, 0), subs.items.len);
}

test "PubSubRegistry unsubscribe" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("ch", 10);
    try ps.subscribe("ch", 20);

    ps.unsubscribe("ch", 10);

    var subs = std.array_list.Managed(i32).init(std.testing.allocator);
    defer subs.deinit();
    ps.getSubscribers("ch", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    try std.testing.expectEqual(@as(i32, 20), subs.items[0]);
}

test "PubSubRegistry unsubscribeAll" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("a", 10);
    try ps.subscribe("b", 10);
    try ps.subscribe("a", 20);

    ps.unsubscribeAll(10);

    var subs = std.array_list.Managed(i32).init(std.testing.allocator);
    defer subs.deinit();

    ps.getSubscribers("a", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    try std.testing.expectEqual(@as(i32, 20), subs.items[0]);

    subs.clearRetainingCapacity();
    ps.getSubscribers("b", &subs);
    try std.testing.expectEqual(@as(usize, 0), subs.items.len);
}

test "PubSubRegistry duplicate subscribe ignored" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("ch", 10);
    try ps.subscribe("ch", 10); // duplicate

    var subs = std.array_list.Managed(i32).init(std.testing.allocator);
    defer subs.deinit();
    ps.getSubscribers("ch", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
}
