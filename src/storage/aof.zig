const std = @import("std");
const c = std.c;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const span = @import("../perf/span.zig");
const vex_log = @import("../log.zig");
const event_stats = @import("../observability/event_stats.zig");
const obs_stats = @import("../observability/stats.zig");
const atomic_io = @import("atomic_io.zig");

/// Durability mode for the AOF.
///   .always   — fsync after every flush; ~zero data loss on crash, high disk cost
///   .everysec — background thread fsyncs every ~1s; ≤1s data loss on crash, no
///               hot-path cost (this is the default and matches Redis)
///   .no       — never fsync explicitly; OS may flush whenever; fastest, least durable
pub const FsyncMode = enum {
    always,
    everysec,
    no,

    pub fn parse(s: []const u8) FsyncMode {
        if (std.ascii.eqlIgnoreCase(s, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(s, "no")) return .no;
        return .everysec;
    }

    pub fn label(self: FsyncMode) []const u8 {
        return switch (self) {
            .always => "always",
            .everysec => "everysec",
            .no => "no",
        };
    }
};

/// Shared between AOF and its background fsync thread.
const FsyncThreadCtx = struct {
    fd_ptr: *std.atomic.Value(c_int),
    stop: std.atomic.Value(bool),
    last_fsync_ms: std.atomic.Value(i64),
};

const is_linux = builtin.os.tag == .linux;

/// Append-Only File for write-ahead logging.
/// Group commit: logCommand() appends to an in-memory buffer (no I/O),
/// flush() writes the entire buffer to file in one write call.
pub const AOF = struct {
    io: std.Io,
    path: []const u8,
    file: std.Io.File,
    file_write_buf: [4096]u8 = undefined,
    snapshot_path: []const u8,
    last_save_time: i64,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    prof: ?*span.Profile = null,
    /// In-memory group commit buffer (commands accumulated between flushes)
    group_buf: std.array_list.Managed(u8) = undefined,
    group_buf_inited: bool = false,
    /// Double buffer for async io_uring flush (data being written to disk)
    flush_buf: std.array_list.Managed(u8) = undefined,
    flush_buf_inited: bool = false,
    /// True while io_uring write+fsync is in-flight
    flush_pending: bool = false,
    /// Current file offset (avoids seekTo on each flush)
    file_offset: u64 = 0,
    /// Bytes written in the current async flush (for file_offset tracking)
    flush_written_len: u64 = 0,
    /// Raw fd opened with O_DIRECT for bypassing page cache (Linux only, -1 if unavailable)
    direct_fd: i32 = -1,
    /// Page-aligned staging buffer for O_DIRECT writes (512-byte sector alignment)
    direct_buf: ?[]align(4096) u8 = null,
    direct_buf_allocator: ?Allocator = null,

    /// Durability mode. Set via setFsyncMode (called from main after init).
    fsync_mode: FsyncMode = .everysec,
    /// Raw fd opened separately for fsync calls. Atomic so the background
    /// thread can read it without coordinating with the main thread.
    /// -1 if fsync is not configured yet.
    fsync_fd: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(-1),
    /// Background fsync thread (only spawned in .everysec mode).
    fsync_thread: ?std.Thread = null,
    fsync_ctx: ?*FsyncThreadCtx = null,
    /// Wall-clock ms of the last successful fsync (exposed via INFO).
    last_fsync_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn init(io: std.Io, path: []const u8, snapshot_path: []const u8) !AOF {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .read = true,
        });
        errdefer file.close(io);
        return .{
            .io = io,
            .path = path,
            .file = file,
            .snapshot_path = snapshot_path,
            .last_save_time = 0,
        };
    }

    /// Enable Direct I/O (O_DIRECT) on Linux. Opens a second fd bypassing page cache.
    /// The direct_fd is used for async io_uring writes; the original file handle stays for sync fallback.
    pub fn enableDirectIO(self: *AOF, allocator: Allocator) void {
        if (!is_linux) return;
        const path_z = allocator.dupeSentinel(u8, self.path, 0) catch return;
        defer allocator.free(path_z);
        const fd = c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true, .DIRECT = true }, @as(c.mode_t, 0o644));
        if (fd < 0) return; // O_DIRECT not supported (e.g. tmpfs)
        self.direct_fd = fd;
        // Allocate 64KB page-aligned staging buffer
        const buf = allocator.alignedAlloc(u8, .fromByteUnits(4096), 65536) catch {
            _ = c.close(fd);
            self.direct_fd = -1;
            return;
        };
        self.direct_buf = buf;
        self.direct_buf_allocator = allocator;
    }

    /// Configure durability mode. Opens a dedicated fsync fd and (for
    /// .everysec) spawns the background thread. Idempotent: calling again
    /// with a different mode stops/starts the thread as needed and replaces
    /// the fd. Must be called after initGroupBuf so the AOF is fully set up.
    pub fn setFsyncMode(self: *AOF, allocator: Allocator, mode: FsyncMode) void {
        // Stop the background thread if running — we'll restart it below if
        // the new mode still needs it.
        self.stopFsyncThread();

        self.fsync_mode = mode;

        // Always open the fsync fd for .always and .everysec. For .no we don't
        // need it.
        if (mode == .no) {
            self.closeFsyncFd();
            return;
        }

        const path_z = allocator.dupeSentinel(u8, self.path, 0) catch {
            vex_log.warn("aof: failed to allocate fsync fd path", .{});
            return;
        };
        defer allocator.free(path_z);
        const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
        if (fd < 0) {
            vex_log.warn("aof: failed to open fsync fd for '{s}'", .{self.path});
            return;
        }
        self.closeFsyncFd();
        self.fsync_fd.store(fd, .release);

        if (mode == .everysec) {
            self.spawnFsyncThread(allocator);
        }
    }

    fn closeFsyncFd(self: *AOF) void {
        const fd = self.fsync_fd.swap(-1, .acq_rel);
        if (fd >= 0) _ = c.close(fd);
    }

    fn spawnFsyncThread(self: *AOF, allocator: Allocator) void {
        const ctx = allocator.create(FsyncThreadCtx) catch {
            vex_log.warn("aof: failed to allocate fsync thread ctx", .{});
            return;
        };
        ctx.* = .{
            .fd_ptr = &self.fsync_fd,
            .stop = std.atomic.Value(bool).init(false),
            .last_fsync_ms = std.atomic.Value(i64).init(0),
        };
        const t = std.Thread.spawn(.{}, fsyncThreadLoop, .{ctx}) catch {
            allocator.destroy(ctx);
            vex_log.warn("aof: failed to spawn fsync thread", .{});
            return;
        };
        self.fsync_ctx = ctx;
        self.fsync_thread = t;
    }

    fn stopFsyncThread(self: *AOF) void {
        if (self.fsync_ctx) |ctx| ctx.stop.store(true, .release);
        if (self.fsync_thread) |t| {
            t.join();
            self.fsync_thread = null;
        }
        if (self.fsync_ctx) |ctx| {
            // Mirror its last_fsync_ms back so INFO reads stay accurate after
            // the thread exits.
            self.last_fsync_ms.store(ctx.last_fsync_ms.load(.monotonic), .release);
            // Use the group_buf's allocator (set by initGroupBuf) — same one
            // that allocated the ctx via setFsyncMode.
            if (self.group_buf_inited) {
                self.group_buf.allocator.destroy(ctx);
            }
            self.fsync_ctx = null;
        }
    }

    /// Background fsync thread body. Wakes every BACKGROUND_FSYNC_PERIOD_MS
    /// and calls fsync on the current fd. The fd is loaded atomically so
    /// setFsyncMode can swap it in mid-flight without coordinating.
    fn fsyncThreadLoop(ctx: *FsyncThreadCtx) void {
        const PERIOD_MS: i64 = 1000;
        while (!ctx.stop.load(.acquire)) {
            // Sleep in small chunks so stop is responsive.
            var slept_ms: i64 = 0;
            while (slept_ms < PERIOD_MS and !ctx.stop.load(.acquire)) {
                std.Thread.yield() catch {};
                var dummy_pfd = [1]std.c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
                _ = std.c.poll(&dummy_pfd, 0, 100);
                slept_ms += 100;
            }
            if (ctx.stop.load(.acquire)) break;

            const fd = ctx.fd_ptr.load(.acquire);
            if (fd < 0) continue;

            const ev_span = event_stats.Span.begin();
            atomic_io.fsyncFile(fd) catch |err| {
                vex_log.warn("aof: background fsync failed: {s}", .{@errorName(err)});
                ev_span.end(.aof_fsync);
                continue;
            };
            ev_span.end(.aof_fsync);

            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const now_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
            ctx.last_fsync_ms.store(now_ms, .monotonic);
        }
    }

    pub fn initGroupBuf(self: *AOF, allocator: Allocator) void {
        if (!self.group_buf_inited) {
            self.group_buf = std.array_list.Managed(u8).init(allocator);
            self.group_buf_inited = true;
        }
        if (!self.flush_buf_inited) {
            self.flush_buf = std.array_list.Managed(u8).init(allocator);
            self.flush_buf_inited = true;
        }
        // Initialize file_offset to current file length
        self.file_offset = self.file.length(self.io) catch 0;
    }

    pub fn deinit(self: *AOF) void {
        // Stop background fsync thread first so it doesn't race with file close.
        self.stopFsyncThread();
        // Flush any remaining buffered commands
        self.flush();
        self.closeFsyncFd();
        if (self.group_buf_inited) self.group_buf.deinit();
        if (self.flush_buf_inited) self.flush_buf.deinit();
        if (self.direct_fd >= 0) _ = c.close(self.direct_fd);
        if (self.direct_buf) |buf| {
            if (self.direct_buf_allocator) |alloc| alloc.free(buf);
        }
        self.file.close(self.io);
    }

    /// Append command to in-memory buffer (no I/O). Thread-safe via mutex.
    pub fn logCommand(self: *AOF, args: []const []const u8) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (!self.group_buf_inited) {
            // Fallback: direct write if group buffer not initialized
            self.writeRecordDirect(args) catch |err| {
                vex_log.warn("aof: direct write failed: {s}", .{@errorName(err)});
            };
            return;
        }

        // Append binary record to in-memory buffer
        self.appendRecord(args) catch |err| {
            vex_log.warn("aof: buffer append failed: {s}", .{@errorName(err)});
        };
    }

    fn appendRecord(self: *AOF, args: []const []const u8) !void {
        var ts_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &ts_buf, std.Io.Timestamp.now(self.io, .real).toMilliseconds(), .little);
        try self.group_buf.appendSlice(&ts_buf);

        var ac_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &ac_buf, @intCast(args.len), .little);
        try self.group_buf.appendSlice(&ac_buf);

        for (args) |arg| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(arg.len), .little);
            try self.group_buf.appendSlice(&len_buf);
            try self.group_buf.appendSlice(arg);
        }
    }

    /// Flush the in-memory buffer to file in one write call (group commit).
    /// Called at the end of each event loop tick in worker.zig.
    pub fn flush(self: *AOF) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (!self.group_buf_inited or self.group_buf.items.len == 0) return;

        const t0 = std.Io.Clock.Timestamp.now(self.io, .awake);
        const ev_span = event_stats.Span.begin();
        self.flushBufferToFile() catch |err| {
            vex_log.err("aof: flush failed ({s}); entering STOP-WRITE state. Writes will return -MISCONF until the underlying issue is resolved.", .{@errorName(err)});
            // Persistence is broken: data may have been lost. Dispatch checks
            // this flag and rejects write commands so the client doesn't
            // receive +OK for writes that aren't durable. Set the errno from
            // the underlying syscall if we can map it (best-effort).
            obs_stats.persistence_broken.store(true, .release);
        };
        // appendfsync = always: real fsync inline so the caller doesn't
        // return to the client until the data is durable. Slow on rotational
        // disks (~5ms) but the only mode that survives a power loss with
        // zero data loss. Other modes leave fsync to the background thread
        // or the OS.
        if (self.fsync_mode == .always) {
            const fd = self.fsync_fd.load(.acquire);
            if (fd >= 0) {
                atomic_io.fsyncFile(fd) catch |err| {
                    vex_log.warn("aof: inline fsync failed: {s}", .{@errorName(err)});
                };
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                const now_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
                self.last_fsync_ms.store(now_ms, .release);
            }
        }
        ev_span.end(.aof_fsync);
        const t1 = std.Io.Clock.Timestamp.now(self.io, .awake);
        if (self.prof) |p| p.recordAofWrite(span.monotonicNs(t0, t1));
    }

    /// Most recent successful fsync timestamp (ms since epoch). For INFO.
    /// Reads the background thread's last fsync when in everysec mode.
    pub fn lastFsyncMs(self: *const AOF) i64 {
        if (self.fsync_ctx) |ctx| return ctx.last_fsync_ms.load(.monotonic);
        return self.last_fsync_ms.load(.monotonic);
    }

    /// Prepare an async flush: swap group_buf → flush_buf.
    /// Returns the flush_buf slice and file offset for io_uring submission.
    /// Returns null if nothing to flush or a flush is already in-flight.
    pub fn prepareAsyncFlush(self: *AOF) ?struct { data: []const u8, offset: u64 } {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (self.flush_pending) return null;
        if (!self.group_buf_inited or self.group_buf.items.len == 0) return null;

        const data_len = self.group_buf.items.len;

        // O_DIRECT path: copy to page-aligned buffer, pad to 512-byte sector boundary
        if (self.direct_fd >= 0) {
            if (self.direct_buf) |dbuf| {
                const padded_len = (data_len + 511) & ~@as(usize, 511);
                if (padded_len <= dbuf.len) {
                    @memcpy(dbuf[0..data_len], self.group_buf.items);
                    // Zero-pad remainder of sector
                    if (padded_len > data_len) {
                        @memset(dbuf[data_len..padded_len], 0);
                    }
                    self.group_buf.clearRetainingCapacity();
                    self.flush_pending = true;
                    self.flush_written_len = padded_len;
                    return .{ .data = dbuf[0..padded_len], .offset = self.file_offset };
                }
            }
        }

        // Non-O_DIRECT path: use flush_buf (no alignment needed)
        self.flush_buf.clearRetainingCapacity();
        self.flush_buf.appendSlice(self.group_buf.items) catch return null;
        self.group_buf.clearRetainingCapacity();

        self.flush_pending = true;
        self.flush_written_len = self.flush_buf.items.len;
        return .{ .data = self.flush_buf.items, .offset = self.file_offset };
    }

    /// Called when io_uring write+fsync CQE completes.
    pub fn asyncFlushComplete(self: *AOF, success: bool) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (success) {
            self.file_offset += self.flush_written_len;
        }
        self.flush_pending = false;
    }

    /// Returns the raw file descriptor for io_uring operations.
    /// Prefers O_DIRECT fd if available.
    pub fn getFd(self: *AOF) i32 {
        if (self.direct_fd >= 0) return self.direct_fd;
        return self.file.handle;
    }

    fn flushBufferToFile(self: *AOF) !void {
        var fw = std.Io.File.writer(self.file, self.io, &self.file_write_buf);
        try fw.seekTo(try self.file.length(self.io));
        const w = &fw.interface;
        try w.writeAll(self.group_buf.items);
        try w.flush();
        self.group_buf.clearRetainingCapacity();
    }

    fn writeRecordDirect(self: *AOF, args: []const []const u8) !void {
        const t0 = std.Io.Clock.Timestamp.now(self.io, .awake);
        var fw = std.Io.File.writer(self.file, self.io, &self.file_write_buf);
        try fw.seekTo(try self.file.length(self.io));
        const w = &fw.interface;

        var ts_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &ts_buf, std.Io.Timestamp.now(self.io, .real).toMilliseconds(), .little);
        try w.writeAll(&ts_buf);

        var ac_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &ac_buf, @intCast(args.len), .little);
        try w.writeAll(&ac_buf);

        for (args) |arg| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(arg.len), .little);
            try w.writeAll(&len_buf);
            try w.writeAll(arg);
        }
        try w.flush();
        const t1 = std.Io.Clock.Timestamp.now(self.io, .awake);
        if (self.prof) |p| p.recordAofWrite(span.monotonicNs(t0, t1));
    }

    pub fn truncate(self: *AOF) !void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        try self.file.setLength(self.io, 0);
    }

    /// Rewrite the AOF by serializing current KV + Graph state as commands.
    /// Writes to a temp file, then atomically renames over the current AOF.
    /// This compacts the AOF (removes redundant ops) and bounds its size.
    pub fn rewriteFromState(
        self: *AOF,
        allocator: Allocator,
        kv: *@import("../engine/kv.zig").KVStore,
        graph: *@import("../engine/graph.zig").GraphEngine,
    ) !void {
        const ev_span = event_stats.Span.begin();
        defer ev_span.end(.aof_rewrite);

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.rewrite.tmp", .{self.path});
        defer allocator.free(tmp_path);

        // Write all current state as AOF records to temp file
        const tmp_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{});
        defer tmp_file.close(self.io);

        var tmp_aof = AOF{
            .io = self.io,
            .path = tmp_path,
            .file = tmp_file,
            .snapshot_path = self.snapshot_path,
            .last_save_time = self.last_save_time,
        };

        // KV entries
        var kv_iter = kv.map.iterator();
        while (kv_iter.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
            if (entry.value_ptr.flags.has_ttl) {
                var ttl_buf: [32]u8 = undefined;
                const remaining_ms = entry.value_ptr.expires_at - kv.cached_now_ms;
                if (remaining_ms <= 0) continue; // already expired
                const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{@divTrunc(remaining_ms, 1000)}) catch continue;
                const args = [_][]const u8{ "SET", entry.key_ptr.*, entry.value_ptr.value, "EX", ttl_str };
                tmp_aof.logCommand(&args);
            } else {
                const args = [_][]const u8{ "SET", entry.key_ptr.*, entry.value_ptr.value };
                tmp_aof.logCommand(&args);
            }
        }

        // Graph nodes
        for (0..graph.node_keys.items.len) |i| {
            if (!graph.node_alive.isSet(i)) continue;
            const key = graph.node_keys.items[i];
            const type_str = graph.type_intern.resolve(graph.node_type_id.items[i]);
            const args = [_][]const u8{ "GRAPH.ADDNODE", key, type_str };
            tmp_aof.logCommand(&args);

            // Node properties
            const pairs = graph.node_props.collectAll(@intCast(i), allocator) catch continue;
            defer allocator.free(pairs);
            for (pairs) |pair| {
                const prop_args = [_][]const u8{ "GRAPH.SETPROP", key, pair.key, pair.value };
                tmp_aof.logCommand(&prop_args);
            }
        }

        // Graph edges
        for (0..graph.edge_from.items.len) |i| {
            if (!graph.edge_alive.isSet(i)) continue;
            const from_id = graph.edge_from.items[i];
            const to_id = graph.edge_to.items[i];
            if (from_id >= graph.node_keys.items.len or to_id >= graph.node_keys.items.len) continue;
            const from_key = graph.node_keys.items[from_id];
            const to_key = graph.node_keys.items[to_id];
            const type_str = graph.type_intern.resolve(graph.edge_type_id.items[i]);
            var weight_buf: [32]u8 = undefined;
            const weight_str = std.fmt.bufPrint(&weight_buf, "{d:.6}", .{graph.edge_weight.items[i]}) catch continue;
            const args = [_][]const u8{ "GRAPH.ADDEDGE", from_key, to_key, type_str, weight_str };
            tmp_aof.logCommand(&args);
        }

        // Atomic rename: replace old AOF with rewritten one.
        // Critical section: hold self.mutex so no concurrent flush can sneak
        // in between merging the in-flight group_buf and the rename. The
        // in-flight bytes get appended to the tmp file before rename so
        // logCommand calls that happened during the rewrite aren't lost.
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        // 1. Append any in-flight self.group_buf to the tmp file. Without
        //    this, mutations recorded during the long rewrite phase would
        //    be silently dropped when we rename tmp over self.path.
        if (self.group_buf_inited and self.group_buf.items.len > 0) {
            var tmp_fw = std.Io.File.writer(tmp_file, self.io, &self.file_write_buf);
            const tmp_len = tmp_file.length(self.io) catch 0;
            tmp_fw.seekTo(tmp_len) catch {
                vex_log.warn("aof rewrite: seek tmp failed", .{});
            };
            const w = &tmp_fw.interface;
            w.writeAll(self.group_buf.items) catch |err| {
                vex_log.warn("aof rewrite: merge in-flight failed: {s}", .{@errorName(err)});
            };
            w.flush() catch |err| {
                vex_log.warn("aof rewrite: flush tmp failed: {s}", .{@errorName(err)});
            };
            self.group_buf.clearRetainingCapacity();
        }

        // 2. fsync the tmp file so the data is durable on disk before rename.
        atomic_io.fsyncFile(tmp_file.handle) catch |err| {
            vex_log.warn("aof rewrite: fsync tmp failed: {s}", .{@errorName(err)});
        };

        // 3. Close the old AOF file, rename tmp over it, reopen.
        self.file.close(self.io);
        const old_path_z = allocator.dupeSentinel(u8, self.path, 0) catch return;
        defer allocator.free(old_path_z);
        const tmp_path_z = allocator.dupeSentinel(u8, tmp_path, 0) catch return;
        defer allocator.free(tmp_path_z);
        if (c.rename(tmp_path_z, old_path_z) != 0) {
            vex_log.err("aof rewrite: rename failed", .{});
            // Try to reopen the old file so the AOF isn't left in a broken state.
            self.file = std.Io.Dir.cwd().createFile(self.io, self.path, .{
                .truncate = false,
                .read = true,
            }) catch return;
            return;
        }

        self.file = std.Io.Dir.cwd().createFile(self.io, self.path, .{
            .truncate = false,
            .read = true,
        }) catch return;

        // 4. file_offset must be reset to the size of the new (rewritten) file
        //    so future appends land at the correct position.
        self.file_offset = self.file.length(self.io) catch 0;

        // 5. fsync the parent directory so the rename itself is durable.
        atomic_io.fsyncDir(allocator, self.path) catch |err| {
            vex_log.warn("aof rewrite: fsync dir failed: {s}", .{@errorName(err)});
        };
    }
};

fn readFileAll(file: std.Io.File, io: std.Io, allocator: Allocator, max_len: usize) ![]u8 {
    const len64 = try file.length(io);
    const len: usize = @intCast(len64);
    if (len > max_len) return error.StreamTooLong;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != len) return error.UnexpectedEof;
    return buf;
}

/// Replay an AOF file through any object with `execute(args, *std.Io.Writer)`.
pub fn replayFile(io: std.Io, allocator: Allocator, path: []const u8, handler: anytype) !u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer file.close(io);

    const data = try readFileAll(file, io, allocator, 1 << 30);
    defer allocator.free(data);

    if (data.len == 0) return 0;

    var discard_list: std.ArrayList(u8) = .empty;
    defer discard_list.deinit(allocator);
    var discard_aw = std.Io.Writer.Allocating.fromArrayList(allocator, &discard_list);
    defer discard_aw.deinit();

    var count: u64 = 0;
    var pos: usize = 0;

    while (pos + 10 <= data.len) {
        const record_start = pos;
        pos += 8; // skip timestamp

        const arg_count = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        const args = allocator.alloc([]const u8, arg_count) catch |err| {
            vex_log.warn("aof: replay aborted at offset {d} after {d} records: {s}", .{ record_start, count, @errorName(err) });
            break;
        };
        defer allocator.free(args);

        var valid = true;
        for (0..arg_count) |i| {
            if (pos + 4 > data.len) {
                valid = false;
                break;
            }
            const arg_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (pos + arg_len > data.len) {
                valid = false;
                break;
            }
            args[i] = data[pos .. pos + arg_len];
            pos += arg_len;
        }

        if (!valid) {
            vex_log.warn(
                "aof: truncated record at offset {d} (file_size={d}, records_replayed={d}); tail {d} bytes discarded",
                .{ record_start, data.len, count, data.len - record_start },
            );
            break;
        }

        discard_aw.clearRetainingCapacity();
        handler.execute(args, &discard_aw.writer) catch |err| {
            vex_log.warn("aof: replay of record {d} at offset {d} failed: {s}", .{ count, record_start, @errorName(err) });
        };
        count += 1;
    }

    return count;
}

test "aof write and replay" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_test.aof";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var a = try AOF.init(io, path, "/tmp/dummy.zdb");
        defer a.deinit();
        const set_args = [_][]const u8{ "SET", "key", "val" };
        a.logCommand(&set_args);
        const del_args = [_][]const u8{ "DEL", "key" };
        a.logCommand(&del_args);
    }

    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, path, &mock);
    try std.testing.expectEqual(@as(u64, 2), replayed);
    try std.testing.expectEqual(@as(u64, 2), exec_count);
}

test "aof truncate" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_trunc_test.aof";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var a = try AOF.init(io, path, "/tmp/dummy.zdb");
    defer a.deinit();

    const args = [_][]const u8{ "SET", "x", "y" };
    a.logCommand(&args);

    try a.truncate();

    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, path, &mock);
    try std.testing.expectEqual(@as(u64, 0), replayed);
}

test "aof replay missing file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, "/tmp/nonexistent_vex.aof", &mock);
    try std.testing.expectEqual(@as(u64, 0), replayed);
}

const MockHandler = struct {
    count: *u64,

    pub fn execute(self: *MockHandler, _: []const []const u8, _: *std.Io.Writer) std.Io.Writer.Error!void {
        self.count.* += 1;
    }
};

test "aof group commit buffer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_group_test.aof";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var a = try AOF.init(io, path, "/tmp/dummy.zdb");
        defer a.deinit();
        a.initGroupBuf(allocator);

        // logCommand should buffer, not write to file
        const set1 = [_][]const u8{ "SET", "k1", "v1" };
        a.logCommand(&set1);
        const set2 = [_][]const u8{ "SET", "k2", "v2" };
        a.logCommand(&set2);

        // Buffer should have data, file should be empty (or just have old data)
        try std.testing.expect(a.group_buf.items.len > 0);

        // flush() should write everything to file
        a.flush();
        try std.testing.expectEqual(@as(usize, 0), a.group_buf.items.len);
    }

    // Replay should find both commands
    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, path, &mock);
    try std.testing.expectEqual(@as(u64, 2), replayed);
}
