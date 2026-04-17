const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const resp = @import("resp.zig");
const KVStore = @import("../engine/kv.zig").KVStore;
const graph_mod = @import("../engine/graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const CommandHandler = @import("../command/handler.zig").CommandHandler;
const KeysMode = @import("../command/handler.zig").KeysMode;
const AOF = @import("../storage/aof.zig").AOF;
const span = @import("../perf/span.zig");

const READ_BUF_SIZE = 64 * 1024; // 64 KiB per client
const JOB_QUEUE_CAP: usize = 65_536;
const ENGINE_BATCH_MAX: usize = 64;

const ConnState = struct {
    io: std.Io,
    next_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_seq: u64 = 1,
    write_mutex: std.Io.Mutex = .init,
    write_ready: std.Io.Condition = .init,

    fn init(io: std.Io) ConnState {
        return .{
            .io = io,
        };
    }

    fn allocSeq(self: *ConnState) u64 {
        return self.next_seq.fetchAdd(1, .monotonic) + 1;
    }
};

pub const ScaleMode = enum {
    scaled,
    cluster,
};

/// Shared state for the single-writer engine thread (read-only for I/O threads).
pub const EngineRuntime = struct {
    allocator: Allocator,
    io: std.Io,
    kv: *KVStore,
    graph: *GraphEngine,
    aof: ?*AOF,
    keys_mode: KeysMode,
    profile: ?*span.Profile,
    /// Lightweight spinlock for inline single-engine execution (bypass queue).
    inline_mutex: std.atomic.Mutex = .unlocked,

    fn lockInline(self: *EngineRuntime) void {
        while (!self.inline_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockInline(self: *EngineRuntime) void {
        self.inline_mutex.unlock();
    }
};

const JobWork = union(enum) {
    /// Full argv copy; executed via `CommandHandler`.
    generic: [][]u8,
    /// Owned optional PING argument (null → `PONG`).
    ping: ?[]u8,
    set_plain: struct { user_key: []u8, val: []u8 },
    set_ex: struct { user_key: []u8, val: []u8, ttl_sec: i64 },
    set_px: struct { user_key: []u8, val: []u8, ttl_ms: i64 },
    get: []u8,
    del: []u8,
    exists: []u8,
    ttl: []u8,
};

const CommandJob = struct {
    rt: *EngineRuntime,
    conn: ?*ConnState = null,
    fd: posix.socket_t,
    seq: u64 = 0,
    selected_db_value: u8,
    enqueue_t: std.Io.Clock.Timestamp,
    reply: bool = true,
    work: JobWork,
};

const JobQueue = struct {
    buf: []CommandJob,
    slot_state: []std.atomic.Value(u8), // 0: empty, 1: full
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn init(buf: []CommandJob, slot_state: []std.atomic.Value(u8)) JobQueue {
        return .{ .buf = buf, .slot_state = slot_state };
    }

    fn push(self: *JobQueue, io: std.Io, job: CommandJob) void {
        _ = io;
        const cap = self.buf.len;
        const spin = struct {
            fn wait() void {
                var i: usize = 0;
                while (i < 128) : (i += 1) std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
        }.wait;

        var reserved: usize = 0;
        while (true) {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            if (t - h >= cap) {
                spin();
                continue;
            }
            if (self.tail.cmpxchgWeak(t, t + 1, .acq_rel, .acquire) == null) {
                reserved = t;
                break;
            }
        }

        const idx = reserved % cap;
        while (self.slot_state[idx].load(.acquire) != 0) spin();
        self.buf[idx] = job;
        self.slot_state[idx].store(1, .release);
    }

    fn popBlocking(self: *JobQueue, io: std.Io) CommandJob {
        _ = io;
        const spin = struct {
            fn wait() void {
                var i: usize = 0;
                while (i < 128) : (i += 1) std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
        }.wait;

        while (true) {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            if (h == t) {
                spin();
                continue;
            }
            const idx = h % self.buf.len;
            if (self.slot_state[idx].load(.acquire) != 1) {
                spin();
                continue;
            }
            const job = self.buf[idx];
            self.slot_state[idx].store(0, .release);
            self.head.store(h + 1, .release);
            return job;
        }
    }

    /// Pop at least one command (blocking), then opportunistically drain more
    /// under the same lock to reduce wakeup and lock overhead.
    fn popBatchBlocking(self: *JobQueue, io: std.Io, out: []CommandJob) usize {
        std.debug.assert(out.len > 0);
        out[0] = self.popBlocking(io);
        var n: usize = 1;
        while (n < out.len) : (n += 1) {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            if (h == t) break;
            const idx = h % self.buf.len;
            if (self.slot_state[idx].load(.acquire) != 1) break;
            out[n] = self.buf[idx];
            self.slot_state[idx].store(0, .release);
            self.head.store(h + 1, .release);
        }
        return n;
    }
};

const EngineShared = struct {
    queue: *JobQueue,
    rt: *EngineRuntime,
};

fn writeOrderedBegin(conn: *ConnState, seq: u64) void {
    conn.write_mutex.lockUncancelable(conn.io);
    while (conn.write_seq != seq) {
        conn.write_ready.waitUncancelable(conn.io, &conn.write_mutex);
    }
}

fn writeOrderedEnd(conn: *ConnState) void {
    conn.write_seq += 1;
    conn.write_ready.signal(conn.io);
    conn.write_mutex.unlock(conn.io);
}

fn engineMain(shared: *EngineShared) void {
    const io = shared.rt.io;
    var batch: [ENGINE_BATCH_MAX]CommandJob = undefined;
    while (true) {
        const batch_pop_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const count = shared.queue.popBatchBlocking(io, batch[0..]);
        const batch_pop_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (shared.rt.profile) |p| {
            p.recordBatchWait(span.monotonicNs(batch_pop_t0, batch_pop_t1));
            p.recordBatchSize(@as(u64, count));
        }

        for (batch[0..count]) |*job| {
            defer freeJobWork(shared.rt.allocator, job.work);

            const job_start = std.Io.Clock.Timestamp.now(io, .awake);
            if (shared.rt.profile) |p| {
                p.recordQueueWait(span.monotonicNs(job.enqueue_t, job_start));
            }

            switch (job.work) {
                .generic => |args| {
                    var job_db = std.atomic.Value(u8).init(job.selected_db_value);
                    var handler = CommandHandler.init(
                        shared.rt.allocator,
                        shared.rt.io,
                        shared.rt.kv,
                        shared.rt.graph,
                        shared.rt.aof,
                        &job_db,
                        shared.rt.keys_mode,
                    );

                    var list: std.ArrayList(u8) = .empty;
                    defer list.deinit(shared.rt.allocator);
                    var aw = std.Io.Writer.Allocating.fromArrayList(shared.rt.allocator, &list);
                    defer aw.deinit();

                    const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
                    handler.execute(args, &aw.writer) catch continue;
                    const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
                    if (shared.rt.profile) |p| {
                        p.recordExec(span.monotonicNs(exec_t0, exec_t1));
                    }

                    const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
                    if (job.reply) {
                        if (job.conn) |c| {
                            writeOrderedBegin(c, job.seq);
                            writeAll(job.fd, aw.written());
                            writeOrderedEnd(c);
                        } else {
                            writeAll(job.fd, aw.written());
                        }
                    }
                    const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
                    if (shared.rt.profile) |p| {
                        p.recordWrite(span.monotonicNs(write_t0, write_t1));
                        if (job.reply) p.bumpCommand();
                    }
                },
                else => {
                    executeHotJob(job);
                },
            }

            // Measure per-job overhead (timestamps, free, dispatch)
            if (shared.rt.profile) |p| {
                const job_end = std.Io.Clock.Timestamp.now(io, .awake);
                const total_ns = span.monotonicNs(job_start, job_end);
                // Subtract exec + write to get overhead
                const exec_ns_val = shared.rt.profile.?.exec_ns.load(.monotonic);
                _ = exec_ns_val;
                p.recordJobOverhead(total_ns);
            }
        }
    }
}

fn dupArgsOwned(allocator: Allocator, parts: []const []const u8) error{OutOfMemory}![][]u8 {
    const out = try allocator.alloc([]u8, parts.len);
    errdefer {
        for (out) |s| allocator.free(s);
        allocator.free(out);
    }
    for (parts, 0..) |p, i| {
        out[i] = try allocator.dupe(u8, p);
    }
    return out;
}

fn freeOwnedArgs(allocator: Allocator, args: [][]u8) void {
    for (args) |s| allocator.free(s);
    allocator.free(args);
}

fn freeJobWork(allocator: Allocator, work: JobWork) void {
    switch (work) {
        .generic => |args| freeOwnedArgs(allocator, args),
        .ping => |msg| {
            if (msg) |m| allocator.free(m);
        },
        .set_plain => |s| {
            allocator.free(s.user_key);
            allocator.free(s.val);
        },
        .set_ex => |s| {
            allocator.free(s.user_key);
            allocator.free(s.val);
        },
        .set_px => |s| {
            allocator.free(s.user_key);
            allocator.free(s.val);
        },
        .get => |k| allocator.free(k),
        .del => |k| allocator.free(k),
        .exists => |k| allocator.free(k),
        .ttl => |k| allocator.free(k),
    }
}

fn shardForDbUserKey(user_key: []const u8, selected_db: u8, queue_count: usize) usize {
    if (queue_count <= 1) return 0;
    var h_buf: [320]u8 = undefined;
    const prefix = std.fmt.bufPrint(&h_buf, "db:{d}:", .{selected_db}) catch return 0;
    const total = prefix.len + user_key.len;
    if (total > h_buf.len) return 0;
    std.mem.copyForwards(u8, h_buf[prefix.len..total], user_key);
    const n = h_buf[0..total];
    const h = std.hash.Wyhash.hash(0, n);
    return @as(usize, @intCast(h % queue_count));
}

fn shardIdxForHotWork(work: JobWork, selected_db: u8, queue_count: usize, scale_mode: ScaleMode) usize {
    if (scale_mode != .scaled) return 0;
    return switch (work) {
        .generic => unreachable,
        .ping => 0,
        .set_plain => |s| shardForDbUserKey(s.user_key, selected_db, queue_count),
        .set_ex => |s| shardForDbUserKey(s.user_key, selected_db, queue_count),
        .set_px => |s| shardForDbUserKey(s.user_key, selected_db, queue_count),
        .get => |k| shardForDbUserKey(k, selected_db, queue_count),
        .del => |k| shardForDbUserKey(k, selected_db, queue_count),
        .exists => |k| shardForDbUserKey(k, selected_db, queue_count),
        .ttl => |k| shardForDbUserKey(k, selected_db, queue_count),
    };
}

fn tryDupHotJobWork(args: []const []const u8, allocator: Allocator) error{OutOfMemory}!?JobWork {
    if (args.len == 0) return null;

    var cmd_buf: [64]u8 = undefined;
    const cmd = toUpperLocal(args[0], &cmd_buf);

    if (std.mem.eql(u8, cmd, "PING")) {
        if (args.len == 1) return .{ .ping = null };
        const msg = try allocator.dupe(u8, args[1]);
        return .{ .ping = msg };
    }

    if (std.mem.eql(u8, cmd, "GET") and args.len == 2) {
        return .{ .get = try allocator.dupe(u8, args[1]) };
    }
    if (std.mem.eql(u8, cmd, "DEL") and args.len == 2) {
        return .{ .del = try allocator.dupe(u8, args[1]) };
    }
    if (std.mem.eql(u8, cmd, "EXISTS") and args.len == 2) {
        return .{ .exists = try allocator.dupe(u8, args[1]) };
    }
    if (std.mem.eql(u8, cmd, "TTL") and args.len == 2) {
        return .{ .ttl = try allocator.dupe(u8, args[1]) };
    }

    if (std.mem.eql(u8, cmd, "SET") and args.len >= 3) {
        const uk = try allocator.dupe(u8, args[1]);
        const val = try allocator.dupe(u8, args[2]);

        if (args.len >= 5) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpperLocal(args[3], &flag_buf);
            if (std.mem.eql(u8, flag, "EX")) {
                const ttl = std.fmt.parseInt(i64, args[4], 10) catch {
                    allocator.free(uk);
                    allocator.free(val);
                    return null;
                };
                return .{ .set_ex = .{ .user_key = uk, .val = val, .ttl_sec = ttl } };
            }
            if (std.mem.eql(u8, flag, "PX")) {
                const ttl = std.fmt.parseInt(i64, args[4], 10) catch {
                    allocator.free(uk);
                    allocator.free(val);
                    return null;
                };
                return .{ .set_px = .{ .user_key = uk, .val = val, .ttl_ms = ttl } };
            }
            allocator.free(uk);
            allocator.free(val);
            return null;
        }

        return .{ .set_plain = .{ .user_key = uk, .val = val } };
    }

    return null;
}

fn enqueueMultiEngineJob(
    io: std.Io,
    allocator: Allocator,
    fd: posix.socket_t,
    conn: ?*ConnState,
    seq: u64,
    args: []const []const u8,
    selected_db: *std.atomic.Value(u8),
    queues: []JobQueue,
    runtimes: []EngineRuntime,
    scale_mode: ScaleMode,
) error{OutOfMemory}!void {
    const enqueue_t = std.Io.Clock.Timestamp.now(io, .awake);
    const db = selected_db.load(.monotonic);

    if (scale_mode == .scaled) {
        if (try tryDupHotJobWork(args, allocator)) |work| {
            const shard_idx = shardIdxForHotWork(work, db, queues.len, scale_mode);
            queues[shard_idx].push(io, .{
                .rt = &runtimes[shard_idx],
                .conn = conn,
                .fd = fd,
                .seq = seq,
                .selected_db_value = db,
                .enqueue_t = enqueue_t,
                .work = work,
            });
            return;
        }
    }

    const owned = try dupArgsOwned(allocator, args);
    const shard_idx = shardForArgs(owned, db, queues.len, scale_mode);
    queues[shard_idx].push(io, .{
        .rt = &runtimes[shard_idx],
        .conn = conn,
        .fd = fd,
        .seq = seq,
        .selected_db_value = db,
        .enqueue_t = enqueue_t,
        .work = .{ .generic = owned },
    });
}

fn executeHotJob(job: *const CommandJob) void {
    const rt = job.rt;
    const io = rt.io;
    const allocator = rt.allocator;
    const fd = job.fd;
    const profile = rt.profile;
    const db = job.selected_db_value;
    const conn = job.conn;

    switch (job.work) {
        .generic => unreachable,
        .ping => |msg| {
            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    if (msg) |m| writeBulkPacked(fd, m) else writeAll(fd, "+PONG\r\n");
                    writeOrderedEnd(c);
                } else {
                    if (msg) |m| writeBulkPacked(fd, m) else writeAll(fd, "+PONG\r\n");
                }
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
        .set_plain => |s| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRefForFast(db, s.user_key, &key_buf, allocator) catch return;
            defer key_ref.deinit(allocator);

            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            rt.kv.set(key_ref.key, s.val) catch return;
            if (rt.aof) |a| {
                const a_args = [_][]const u8{ "SET", s.user_key, s.val };
                a.logCommand(&a_args);
            }
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    writeAll(fd, "+OK\r\n");
                    writeOrderedEnd(c);
                } else writeAll(fd, "+OK\r\n");
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
        .set_ex => |s| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRefForFast(db, s.user_key, &key_buf, allocator) catch return;
            defer key_ref.deinit(allocator);

            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            rt.kv.setEx(key_ref.key, s.val, s.ttl_sec) catch return;
            if (rt.aof) |a| {
                var ttl_buf: [32]u8 = undefined;
                const ttl_s = std.fmt.bufPrint(&ttl_buf, "{d}", .{s.ttl_sec}) catch return;
                const a_args = [_][]const u8{ "SET", s.user_key, s.val, "EX", ttl_s };
                a.logCommand(&a_args);
            }
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    writeAll(fd, "+OK\r\n");
                    writeOrderedEnd(c);
                } else writeAll(fd, "+OK\r\n");
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
        .set_px => |s| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRefForFast(db, s.user_key, &key_buf, allocator) catch return;
            defer key_ref.deinit(allocator);

            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            rt.kv.setPx(key_ref.key, s.val, s.ttl_ms) catch return;
            if (rt.aof) |a| {
                var ttl_buf: [32]u8 = undefined;
                const ttl_s = std.fmt.bufPrint(&ttl_buf, "{d}", .{s.ttl_ms}) catch return;
                const a_args = [_][]const u8{ "SET", s.user_key, s.val, "PX", ttl_s };
                a.logCommand(&a_args);
            }
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    writeAll(fd, "+OK\r\n");
                    writeOrderedEnd(c);
                } else writeAll(fd, "+OK\r\n");
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
        .get => |user_key| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRefForFast(db, user_key, &key_buf, allocator) catch return;
            defer key_ref.deinit(allocator);

            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const val = rt.kv.get(key_ref.key);
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    writeBulkPacked(fd, val);
                    writeOrderedEnd(c);
                } else writeBulkPacked(fd, val);
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
        .del => |user_key| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRefForFast(db, user_key, &key_buf, allocator) catch return;
            defer key_ref.deinit(allocator);

            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const removed = rt.kv.delete(key_ref.key);
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            if (removed) {
                if (rt.aof) |a| {
                    const a_args = [_][]const u8{ "DEL", user_key };
                    a.logCommand(&a_args);
                }
            }

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    if (removed) writeAll(fd, ":1\r\n") else writeAll(fd, ":0\r\n");
                    writeOrderedEnd(c);
                } else {
                    if (removed) writeAll(fd, ":1\r\n") else writeAll(fd, ":0\r\n");
                }
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
        .exists => |user_key| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRefForFast(db, user_key, &key_buf, allocator) catch return;
            defer key_ref.deinit(allocator);

            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const exists = rt.kv.exists(key_ref.key);
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    if (exists) writeAll(fd, ":1\r\n") else writeAll(fd, ":0\r\n");
                    writeOrderedEnd(c);
                } else {
                    if (exists) writeAll(fd, ":1\r\n") else writeAll(fd, ":0\r\n");
                }
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
        .ttl => |user_key| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRefForFast(db, user_key, &key_buf, allocator) catch return;
            defer key_ref.deinit(allocator);

            const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const present = rt.kv.exists(key_ref.key);
            const sec: ?i64 = if (present) rt.kv.ttl(key_ref.key) else null;
            const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

            const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
            if (job.reply) {
                if (conn) |c| {
                    writeOrderedBegin(c, job.seq);
                    if (!present) writeAll(fd, ":-2\r\n") else if (sec) |tsec| writeIntegerPacked(fd, tsec) else writeAll(fd, ":-1\r\n");
                    writeOrderedEnd(c);
                } else {
                    if (!present) writeAll(fd, ":-2\r\n") else if (sec) |tsec| writeIntegerPacked(fd, tsec) else writeAll(fd, ":-1\r\n");
                }
            }
            const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
            if (profile) |p| {
                p.recordWrite(span.monotonicNs(write_t0, write_t1));
                if (job.reply) p.bumpCommand();
            }
        },
    }
}

fn toUpperLocal(input: []const u8, buf: []u8) []const u8 {
    const len = @min(input.len, buf.len);
    for (0..len) |i| buf[i] = std.ascii.toUpper(input[i]);
    return buf[0..len];
}

fn shardForArgs(args: []const []const u8, selected_db: u8, queue_count: usize, scale_mode: ScaleMode) usize {
    if (queue_count <= 1) return 0;
    if (scale_mode != .scaled) return 0;
    if (args.len == 0) return 0;

    var cmd_buf: [64]u8 = undefined;
    const cmd = toUpperLocal(args[0], &cmd_buf);

    var key: ?[]const u8 = null;
    if (std.mem.eql(u8, cmd, "GET") or std.mem.eql(u8, cmd, "TTL")) {
        if (args.len == 2) key = args[1];
    } else if (std.mem.eql(u8, cmd, "SET")) {
        if (args.len >= 3) key = args[1];
    } else if (std.mem.eql(u8, cmd, "DEL") or std.mem.eql(u8, cmd, "EXISTS")) {
        if (args.len == 2) key = args[1];
    } else if (std.mem.eql(u8, cmd, "FLUSHDB") or
        std.mem.eql(u8, cmd, "SELECT") or
        std.mem.startsWith(u8, cmd, "GRAPH."))
    {
        return 0;
    }
    const k = key orelse return 0;

    var h_buf: [320]u8 = undefined;
    const prefix = std.fmt.bufPrint(&h_buf, "db:{d}:", .{selected_db}) catch return 0;
    const total = prefix.len + k.len;
    if (total > h_buf.len) return 0;
    std.mem.copyForwards(u8, h_buf[prefix.len..total], k);
    const n = h_buf[0..total];
    const h = std.hash.Wyhash.hash(0, n);
    return @as(usize, @intCast(h % queue_count));
}

fn supportsScaledMultiEngine(args: []const []const u8) bool {
    if (args.len == 0) return true;
    var cmd_buf: [64]u8 = undefined;
    const cmd = toUpperLocal(args[0], &cmd_buf);
    if (std.mem.eql(u8, cmd, "SET")) return args.len >= 3;
    if (std.mem.eql(u8, cmd, "GET")) return args.len == 2;
    if (std.mem.eql(u8, cmd, "TTL")) return args.len == 2;
    if (std.mem.eql(u8, cmd, "DEL")) return args.len == 2;
    if (std.mem.eql(u8, cmd, "EXISTS")) return args.len == 2;
    if (std.mem.eql(u8, cmd, "FLUSHDB")) return true;
    if (std.mem.eql(u8, cmd, "SELECT")) return false;
    if (std.mem.startsWith(u8, cmd, "GRAPH.")) return true;
    if (std.mem.eql(u8, cmd, "PING")) return true;
    if (std.mem.eql(u8, cmd, "COMMAND")) return true;
    return false;
}

fn isFlushDb(args: []const []const u8) bool {
    if (args.len == 0) return false;
    var cmd_buf: [64]u8 = undefined;
    const cmd = toUpperLocal(args[0], &cmd_buf);
    return std.mem.eql(u8, cmd, "FLUSHDB");
}

fn writeErrorResp(fd: posix.socket_t, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "-ERR {s}\r\n", .{msg}) catch return;
    writeAll(fd, out);
}

fn shardForNamespacedKey(key: []const u8, shard_count: usize) usize {
    if (shard_count <= 1) return 0;
    const h = std.hash.Wyhash.hash(0, key);
    return @as(usize, @intCast(h % shard_count));
}

fn rebalanceIntoShards(source: *KVStore, shards: []KVStore, shard_count: usize) !void {
    var it = source.map.iterator();
    while (it.next()) |entry| {
        const raw_key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        const idx = shardForNamespacedKey(raw_key, shard_count);
        try shards[idx].restoreEntry(raw_key, v.value, v.expires_at);
    }
    source.flushdb();
}

pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    kv: *KVStore,
    graph: *GraphEngine,
    aof: ?*AOF,
    /// Address used for `std.Io.net.IpAddress.listen` (IPv4 or IPv4-mapped IPv6).
    bind_address: std.Io.net.IpAddress,
    listen_port: u16,
    keys_mode: KeysMode,
    profile: ?*span.Profile,
    scale_mode: ScaleMode,
    engine_threads: usize,
    cluster_config: ?[]const u8,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        kv: *KVStore,
        g: *GraphEngine,
        aof: ?*AOF,
        host: []const u8,
        port: u16,
        keys_mode: KeysMode,
        profile: ?*span.Profile,
        scale_mode: ScaleMode,
        engine_threads: usize,
        cluster_config: ?[]const u8,
    ) !Server {
        const resolved = try std.Io.net.IpAddress.resolve(io, host, port);
        const bind_address: std.Io.net.IpAddress = switch (resolved) {
            .ip4 => |x| .{ .ip4 = x },
            .ip6 => |x| blk: {
                if (std.Io.net.Ip4Address.fromIp6(x)) |ip4| break :blk .{ .ip4 = ip4 };
                return error.AddressFamilyUnsupported;
            },
        };
        return .{
            .allocator = allocator,
            .io = io,
            .kv = kv,
            .graph = g,
            .aof = aof,
            .bind_address = bind_address,
            .listen_port = bind_address.getPort(),
            .keys_mode = keys_mode,
            .profile = profile,
            .scale_mode = scale_mode,
            .engine_threads = engine_threads,
            .cluster_config = cluster_config,
        };
    }

    /// Blocking accept loop. Spawns a thread per client connection; commands run on a single engine thread.
    pub fn run(self: *Server) !void {
        var addr = self.bind_address;
        var net_server = try std.Io.net.IpAddress.listen(&addr, self.io, .{
            .reuse_address = true,
        });
        defer net_server.deinit(self.io);

        const effective_engine_threads = switch (self.scale_mode) {
            .cluster => blk: {
                if (self.cluster_config == null) return error.InvalidClusterConfiguration;
                if (self.engine_threads == 0) return error.InvalidEngineThreadCount;
                break :blk self.engine_threads;
            },
            .scaled => blk: {
                if (self.engine_threads == 0) return error.InvalidEngineThreadCount;
                break :blk self.engine_threads;
            },
        };

        const queues = try self.allocator.alloc(JobQueue, effective_engine_threads);
        defer self.allocator.free(queues);
        const queue_buf = try self.allocator.alloc(CommandJob, JOB_QUEUE_CAP * effective_engine_threads);
        defer self.allocator.free(queue_buf);
        const queue_state = try self.allocator.alloc(std.atomic.Value(u8), JOB_QUEUE_CAP * effective_engine_threads);
        defer self.allocator.free(queue_state);
        const runtimes = try self.allocator.alloc(EngineRuntime, effective_engine_threads);
        defer self.allocator.free(runtimes);
        const shared_arr = try self.allocator.alloc(EngineShared, effective_engine_threads);
        defer self.allocator.free(shared_arr);

        const kv_shards = try self.allocator.alloc(KVStore, effective_engine_threads);
        defer {
            for (kv_shards) |*s| s.deinit();
            self.allocator.free(kv_shards);
        }
        for (kv_shards) |*s| {
            s.* = KVStore.init(self.allocator, self.io);
        }
        try rebalanceIntoShards(self.kv, kv_shards, effective_engine_threads);

        var shard_aofs: ?[]AOF = null;
        if (self.scale_mode == .scaled and effective_engine_threads > 1 and self.aof != null) {
            const extra = effective_engine_threads - 1;
            const arr = try self.allocator.alloc(AOF, extra);
            for (0..extra) |j| {
                const shard_path = try std.fmt.allocPrint(self.allocator, "{s}.shard{d}", .{ self.aof.?.path, j + 1 });
                arr[j] = try AOF.init(self.io, shard_path, self.aof.?.snapshot_path);
                arr[j].prof = self.profile;
            }
            shard_aofs = arr;
        }

        for (0..effective_engine_threads) |i| {
            const start = i * JOB_QUEUE_CAP;
            const stop = start + JOB_QUEUE_CAP;
            for (queue_state[start..stop]) |*s| s.* = std.atomic.Value(u8).init(0);
            queues[i] = JobQueue.init(queue_buf[start..stop], queue_state[start..stop]);
            runtimes[i] = .{
                .allocator = self.allocator,
                .io = self.io,
                .kv = &kv_shards[i],
                .graph = self.graph,
                .aof = if (i == 0) self.aof else if (shard_aofs) |arr| &arr[i - 1] else null,
                .keys_mode = self.keys_mode,
                .profile = self.profile,
            };
            shared_arr[i] = .{
                .queue = &queues[i],
                .rt = &runtimes[i],
            };
            // Only spawn engine threads for multi-engine mode.
            // Single-engine uses inline execution on I/O threads.
            if (effective_engine_threads > 1) {
                const engine_thread = try std.Thread.spawn(.{}, engineMain, .{&shared_arr[i]});
                engine_thread.detach();
            }
        }

        if (self.scale_mode == .cluster) {
            log("listening on :{d} (mode=cluster, engine_threads={d}, queue cap {d}, cluster_config={s})", .{
                self.listen_port,
                effective_engine_threads,
                JOB_QUEUE_CAP,
                self.cluster_config.?,
            });
        } else {
            log("listening on :{d} (mode=scaled, engine_threads={d}, queue cap {d})", .{
                self.listen_port,
                effective_engine_threads,
                JOB_QUEUE_CAP,
            });
        }

        while (true) {
            var stream = net_server.accept(self.io) catch |err| {
                log("accept error: {}", .{err});
                continue;
            };
            // Disable Nagle's algorithm for low-latency request/response
            const yes: c_int = 1;
            _ = std.c.setsockopt(stream.socket.handle, 6, 1, @ptrCast(&yes), @sizeOf(c_int)); // IPPROTO_TCP=6, TCP_NODELAY=1
            const conn = self.allocator.create(ConnState) catch {
                stream.close(self.io);
                continue;
            };
            conn.* = ConnState.init(self.io);

            const ctx = self.allocator.create(ClientCtx) catch {
                self.allocator.destroy(conn);
                stream.close(self.io);
                continue;
            };
            ctx.* = .{
                .stream = stream,
                .conn = conn,
                .io = self.io,
                .allocator = self.allocator,
                .selected_db = std.atomic.Value(u8).init(0),
                .keys_mode = self.keys_mode,
                .profile = self.profile,
                .queues = queues,
                .queue_count = effective_engine_threads,
                .scale_mode = self.scale_mode,
                .runtimes = runtimes,
                .kv_shards = kv_shards,
            };

            const thread = std.Thread.spawn(.{}, handleClient, .{ctx}) catch {
                ctx.stream.close(ctx.io);
                self.allocator.destroy(ctx.conn);
                self.allocator.destroy(ctx);
                continue;
            };
            thread.detach();
        }
    }

    /// Multi-reactor accept loop. N worker threads each run their own event loop.
    pub fn runReactor(self: *Server, num_workers: usize) !void {
        const Worker = @import("worker.zig").Worker;

        var addr = self.bind_address;
        var net_server = try std.Io.net.IpAddress.listen(&addr, self.io, .{
            .reuse_address = true,
        });
        defer net_server.deinit(self.io);

        var graph_mutex = std.atomic.Mutex.unlocked;
        var kv_mutex = std.atomic.Mutex.unlocked;

        // Create ConcurrentKV and import existing data from the plain KVStore.
        const ConcurrentKV = @import("../engine/concurrent_kv.zig").ConcurrentKV;
        var ckv = ConcurrentKV.init(self.allocator, self.io);
        defer ckv.deinit();
        try ckv.importFrom(self.kv);

        const workers = try self.allocator.alloc(Worker, num_workers);
        defer self.allocator.free(workers);

        for (workers, 0..) |*w, i| {
            w.* = try Worker.init(
                self.allocator,
                @intCast(i),
                self.io,
                self.kv,
                &kv_mutex,
                &ckv,
                self.graph,
                &graph_mutex,
                self.aof,
                self.keys_mode,
                self.profile,
            );
        }

        // Spawn worker threads.
        for (workers) |*w| {
            const t = try std.Thread.spawn(.{}, Worker.run, .{w});
            t.detach();
        }

        log("listening on :{d} (reactor, workers={d})", .{ self.listen_port, num_workers });

        var next_worker: usize = 0;
        while (true) {
            const stream = net_server.accept(self.io) catch |err| {
                log("accept error: {}", .{err});
                continue;
            };
            const fd = stream.socket.handle;

            // TCP_NODELAY for low latency.
            const yes: c_int = 1;
            _ = std.c.setsockopt(fd, 6, 1, @ptrCast(&yes), @sizeOf(c_int));

            // Set non-blocking.
            _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));

            // Round-robin to workers.
            workers[next_worker].pushNewFd(fd);
            next_worker = (next_worker + 1) % num_workers;
        }
    }
};

const ClientCtx = struct {
    stream: std.Io.net.Stream,
    conn: *ConnState,
    io: std.Io,
    allocator: Allocator,
    selected_db: std.atomic.Value(u8),
    keys_mode: KeysMode,
    profile: ?*span.Profile,
    queues: []JobQueue,
    queue_count: usize,
    scale_mode: ScaleMode,
    runtimes: []EngineRuntime,
    kv_shards: []KVStore,
};

fn handleClient(ctx: *ClientCtx) void {
    defer {
        ctx.allocator.destroy(ctx.conn);
        ctx.stream.close(ctx.io);
        ctx.allocator.destroy(ctx);
    }

    const fd = ctx.stream.socket.handle;

    var read_buf: [READ_BUF_SIZE]u8 = undefined;
    var accum = std.array_list.Managed(u8).init(ctx.allocator);
    defer accum.deinit();

    while (true) {
        const n = posix.read(fd, &read_buf) catch break;
        if (n == 0) break; // client disconnected

        accum.appendSlice(read_buf[0..n]) catch break;

        while (accum.items.len > 0) {
            if (!processOneCommand(&accum, fd, ctx.conn, ctx.allocator, ctx.queues, ctx.queue_count, ctx.scale_mode, ctx.runtimes, ctx.kv_shards, &ctx.selected_db, ctx.profile, ctx.io)) break;
        }
    }
}

/// Execute a command inline on the I/O thread under the runtime's OS mutex.
/// Used for single-engine mode to avoid queue handoff latency.
fn executeInline(
    rt: *EngineRuntime,
    args: []const []const u8,
    allocator: Allocator,
    fd: posix.socket_t,
    selected_db: *std.atomic.Value(u8),
    io: std.Io,
    profile: ?*span.Profile,
) void {
    rt.lockInline();

    var handler = CommandHandler.init(
        allocator,
        io,
        rt.kv,
        rt.graph,
        rt.aof,
        selected_db,
        rt.keys_mode,
    );

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();

    const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    handler.execute(args, &aw.writer) catch {
        rt.unlockInline();
        return;
    };
    const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    rt.unlockInline();

    if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

    const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    writeAll(fd, aw.written());
    const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    if (profile) |p| {
        p.recordWrite(span.monotonicNs(write_t0, write_t1));
        p.bumpCommand();
    }
}

/// Execute a hot KV command inline under the runtime's OS mutex.
/// Returns true if the command was handled, false if not a hot command.
fn executeHotInline(
    rt: *EngineRuntime,
    args: []const []const u8,
    fd: posix.socket_t,
    selected_db: u8,
    allocator: Allocator,
    io: std.Io,
    profile: ?*span.Profile,
) bool {
    if (args.len == 0) return false;
    const cmd = args[0];

    if (equalsAsciiUpper(cmd, "PING")) {
        if (profile) |p| {
            const t0 = std.Io.Clock.Timestamp.now(io, .awake);
            const t1 = std.Io.Clock.Timestamp.now(io, .awake);
            p.recordExec(span.monotonicNs(t0, t1));
        }
        const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        if (args.len > 1) writeBulkPacked(fd, args[1]) else writeAll(fd, "+PONG\r\n");
        const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (profile) |p| {
            p.recordWrite(span.monotonicNs(write_t0, write_t1));
            p.bumpCommand();
        }
        return true;
    }

    if (equalsAsciiUpper(cmd, "GET") and args.len == 2) {
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRefForFast(selected_db, args[1], &key_buf, allocator) catch return false;
        defer key_ref.deinit(allocator);

        rt.lockInline();
        const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const val = rt.kv.get(key_ref.key);
        // Must copy val before unlock since KV store owns the memory
        var val_copy: ?[]u8 = null;
        if (val) |v| {
            val_copy = allocator.dupe(u8, v) catch {
                rt.unlockInline();
                return false;
            };
        }
        const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        rt.unlockInline();

        if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));
        defer if (val_copy) |vc| allocator.free(vc);

        const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        writeBulkPacked(fd, val_copy);
        const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (profile) |p| {
            p.recordWrite(span.monotonicNs(write_t0, write_t1));
            p.bumpCommand();
        }
        return true;
    }

    if (equalsAsciiUpper(cmd, "SET") and args.len >= 3) {
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRefForFast(selected_db, args[1], &key_buf, allocator) catch return false;
        defer key_ref.deinit(allocator);

        rt.lockInline();
        const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        if (args.len >= 5 and equalsAsciiUpper(args[3], "EX")) {
            const ttl = std.fmt.parseInt(i64, args[4], 10) catch {
                rt.unlockInline();
                return false;
            };
            rt.kv.setEx(key_ref.key, args[2], ttl) catch {
                rt.unlockInline();
                return false;
            };
        } else if (args.len >= 5 and equalsAsciiUpper(args[3], "PX")) {
            const ttl = std.fmt.parseInt(i64, args[4], 10) catch {
                rt.unlockInline();
                return false;
            };
            rt.kv.setPx(key_ref.key, args[2], ttl) catch {
                rt.unlockInline();
                return false;
            };
        } else {
            rt.kv.set(key_ref.key, args[2]) catch {
                rt.unlockInline();
                return false;
            };
        }
        if (rt.aof) |a| {
            if (args.len >= 5) {
                const a_args = [_][]const u8{ "SET", args[1], args[2], args[3], args[4] };
                a.logCommand(&a_args);
            } else {
                const a_args = [_][]const u8{ "SET", args[1], args[2] };
                a.logCommand(&a_args);
            }
        }
        const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        rt.unlockInline();

        if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

        const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        writeAll(fd, "+OK\r\n");
        const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (profile) |p| {
            p.recordWrite(span.monotonicNs(write_t0, write_t1));
            p.bumpCommand();
        }
        return true;
    }

    if (equalsAsciiUpper(cmd, "DEL") and args.len == 2) {
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRefForFast(selected_db, args[1], &key_buf, allocator) catch return false;
        defer key_ref.deinit(allocator);

        rt.lockInline();
        const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const removed = rt.kv.delete(key_ref.key);
        if (removed) {
            if (rt.aof) |a| {
                const a_args = [_][]const u8{ "DEL", args[1] };
                a.logCommand(&a_args);
            }
        }
        const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        rt.unlockInline();

        if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

        const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        if (removed) writeAll(fd, ":1\r\n") else writeAll(fd, ":0\r\n");
        const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (profile) |p| {
            p.recordWrite(span.monotonicNs(write_t0, write_t1));
            p.bumpCommand();
        }
        return true;
    }

    if (equalsAsciiUpper(cmd, "EXISTS") and args.len == 2) {
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRefForFast(selected_db, args[1], &key_buf, allocator) catch return false;
        defer key_ref.deinit(allocator);

        rt.lockInline();
        const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const exists = rt.kv.exists(key_ref.key);
        const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        rt.unlockInline();

        if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

        const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        if (exists) writeAll(fd, ":1\r\n") else writeAll(fd, ":0\r\n");
        const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (profile) |p| {
            p.recordWrite(span.monotonicNs(write_t0, write_t1));
            p.bumpCommand();
        }
        return true;
    }

    if (equalsAsciiUpper(cmd, "TTL") and args.len == 2) {
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRefForFast(selected_db, args[1], &key_buf, allocator) catch return false;
        defer key_ref.deinit(allocator);

        rt.lockInline();
        const exec_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const present = rt.kv.exists(key_ref.key);
        const sec: ?i64 = if (present) rt.kv.ttl(key_ref.key) else null;
        const exec_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        rt.unlockInline();

        if (profile) |p| p.recordExec(span.monotonicNs(exec_t0, exec_t1));

        const write_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        if (!present) writeAll(fd, ":-2\r\n") else if (sec) |tsec| writeIntegerPacked(fd, tsec) else writeAll(fd, ":-1\r\n");
        const write_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (profile) |p| {
            p.recordWrite(span.monotonicNs(write_t0, write_t1));
            p.bumpCommand();
        }
        return true;
    }

    return false;
}

fn consumeAccum(accum: *std.array_list.Managed(u8), n: usize) void {
    if (n >= accum.items.len) {
        accum.clearRetainingCapacity();
    } else {
        std.mem.copyForwards(u8, accum.items[0..], accum.items[n..]);
        accum.shrinkRetainingCapacity(accum.items.len - n);
    }
}

fn enqueueArgs(
    args: []const []const u8,
    allocator: Allocator,
    fd: posix.socket_t,
    conn: *ConnState,
    queues: []JobQueue,
    queue_count: usize,
    runtimes: []EngineRuntime,
    kv_shards: []KVStore,
    selected_db: *std.atomic.Value(u8),
    io: std.Io,
    scale_mode: ScaleMode,
    profile: ?*span.Profile,
) bool {
    // Multi-engine: reject unsupported commands, handle FLUSHDB across shards
    if (queue_count > 1) {
        if (!supportsScaledMultiEngine(args)) {
            writeErrorResp(fd, "unsupported command in scaled multi-engine mode");
            return true; // consumed (error sent)
        }
        if (isFlushDb(args)) {
            for (kv_shards) |*s| s.flushdb();
            sendSimpleReply(fd, conn, queue_count, "+OK\r\n");
            return true;
        }
        const seq = conn.allocSeq();
        enqueueMultiEngineJob(io, allocator, fd, conn, seq, args, selected_db, queues, runtimes, scale_mode) catch return false;
        return true;
    }

    // Single engine: inline execution under OS mutex (no queue overhead)
    executeInline(&runtimes[0], args, allocator, fd, selected_db, io, profile);
    return true;
}

fn processOneCommand(
    accum: *std.array_list.Managed(u8),
    fd: posix.socket_t,
    conn: *ConnState,
    allocator: Allocator,
    queues: []JobQueue,
    queue_count: usize,
    scale_mode: ScaleMode,
    runtimes: []EngineRuntime,
    kv_shards: []KVStore,
    selected_db: *std.atomic.Value(u8),
    profile: ?*span.Profile,
    io: std.Io,
) bool {
    const data = accum.items;

    // Fast RESP path: manual parse avoids full parser allocations for common commands.
    if (data.len >= 4 and data[0] == '*') {
        if (enqueueFastResp(data, allocator, fd, conn, queues, queue_count, runtimes, kv_shards, selected_db, io, scale_mode, profile)) |consumed| {
            if (consumed > 0) {
                consumeAccum(accum, consumed);
                return true;
            }
        } else |err| switch (err) {
            error.NoFastPath => {},
            error.OutOfMemory => return false,
        }
    }

    // Inline command path
    if (resp.isInlineCommand(data)) {
        const eol = findCRLF(data) orelse return false;
        const line = data[0..eol];

        const parse_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const parts = resp.parseInlineCommand(line, allocator) catch return false;
        const parse_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        if (profile) |p| p.recordParse(span.monotonicNs(parse_t0, parse_t1));
        defer {
            for (parts) |p| allocator.free(p);
            allocator.free(parts);
        }

        if (tryHandleSelect(parts, selected_db, fd, conn, queue_count)) {
            consumeAccum(accum, eol + 2);
            return true;
        }

        if (!enqueueArgs(parts, allocator, fd, conn, queues, queue_count, runtimes, kv_shards, selected_db, io, scale_mode, profile)) return false;
        consumeAccum(accum, eol + 2);
        return true;
    }

    // Full RESP parse
    var parser = resp.Parser.init(data);
    const parse_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    var val = parser.parse(allocator) catch return false;
    defer val.deinit(allocator);

    const args_raw = val.array orelse return false;
    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    for (args_raw) |item| {
        const s = switch (item) {
            .bulk_string => |bs| bs orelse continue,
            .simple_string => |ss| ss,
            else => continue,
        };
        args.append(s) catch return false;
    }
    const parse_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    if (profile) |p| p.recordParse(span.monotonicNs(parse_t0, parse_t1));

    if (tryHandleSelect(args.items, selected_db, fd, conn, queue_count)) {
        consumeAccum(accum, parser.pos);
        return true;
    }

    if (!enqueueArgs(args.items, allocator, fd, conn, queues, queue_count, runtimes, kv_shards, selected_db, io, scale_mode, profile)) return false;
    consumeAccum(accum, parser.pos);
    return true;
}

fn tryHandleSelect(
    args: []const []const u8,
    selected_db: *std.atomic.Value(u8),
    fd: posix.socket_t,
    conn: *ConnState,
    queue_count: usize,
) bool {
    if (args.len != 2) return false;
    var cmd_buf: [64]u8 = undefined;
    const cmd = toUpperLocal(args[0], &cmd_buf);
    if (!std.mem.eql(u8, cmd, "SELECT")) return false;
    const db = std.fmt.parseInt(u8, args[1], 10) catch {
        writeErrorResp(fd, "DB index out of range");
        return true;
    };
    selected_db.store(db, .monotonic);
    sendSimpleReply(fd, conn, queue_count, "+OK\r\n");
    return true;
}

fn sendSimpleReply(fd: posix.socket_t, conn: *ConnState, queue_count: usize, msg: []const u8) void {
    if (queue_count > 1) {
        const seq = conn.allocSeq();
        writeOrderedBegin(conn, seq);
        writeAll(fd, msg);
        writeOrderedEnd(conn);
    } else {
        writeAll(fd, msg);
    }
}

fn enqueueFastResp(
    data: []const u8,
    allocator: Allocator,
    fd: posix.socket_t,
    conn: *ConnState,
    queues: []JobQueue,
    queue_count: usize,
    runtimes: []EngineRuntime,
    _: []KVStore,
    selected_db: *std.atomic.Value(u8),
    io: std.Io,
    scale_mode: ScaleMode,
    profile: ?*span.Profile,
) error{ NoFastPath, OutOfMemory }!usize {
    if (data.len < 4 or data[0] != '*') return error.NoFastPath;

    var pos: usize = 1;
    const argc = parseIntLine(data, &pos) catch return error.NoFastPath;
    if (argc <= 0 or argc > 6) return error.NoFastPath;

    var args_buf: [6][]const u8 = undefined;
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        if (pos >= data.len or data[pos] != '$') return error.NoFastPath;
        pos += 1;
        const blen = parseIntLine(data, &pos) catch return error.NoFastPath;
        if (blen < 0) return error.NoFastPath;
        const n: usize = @intCast(blen);
        if (pos + n + 2 > data.len) return error.NoFastPath;
        args_buf[i] = data[pos .. pos + n];
        pos += n;
        if (data[pos] != '\r' or data[pos + 1] != '\n') return error.NoFastPath;
        pos += 2;
    }

    const args = args_buf[0..@as(usize, @intCast(argc))];

    // Handle SELECT inline (per-connection, not queued)
    if (tryHandleSelect(args, selected_db, fd, conn, queue_count)) return pos;

    // Multi-engine checks
    if (queue_count > 1) {
        if (!supportsScaledMultiEngine(args)) return error.NoFastPath;
        if (isFlushDb(args)) return error.NoFastPath; // handled in common path
    }

    if (profile) |p| {
        const parse_t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const parse_t1 = std.Io.Clock.Timestamp.now(io, .awake);
        p.recordParse(span.monotonicNs(parse_t0, parse_t1));
    }

    if (queue_count == 1) {
        // Single engine: inline execution with hot-path or generic fallback
        const db = selected_db.load(.monotonic);
        if (executeHotInline(&runtimes[0], args, fd, db, allocator, io, profile)) return pos;
        // Fall back to generic inline
        executeInline(&runtimes[0], args, allocator, fd, selected_db, io, profile);
        return pos;
    }

    // Multi-engine: enqueue
    const seq = conn.allocSeq();
    try enqueueMultiEngineJob(io, allocator, fd, conn, seq, args, selected_db, queues, runtimes, scale_mode);
    return pos;
}


const FastNamespacedRef = struct {
    key: []const u8,
    owned: ?[]u8 = null,
    fn deinit(self: *const FastNamespacedRef, allocator: Allocator) void {
        if (self.owned) |b| allocator.free(b);
    }
};

fn namespacedKeyRefForFast(db: u8, key: []const u8, stack: []u8, allocator: Allocator) !FastNamespacedRef {
    const prefix = std.fmt.bufPrint(stack, "db:{d}:", .{db}) catch {
        const owned = try std.fmt.allocPrint(allocator, "db:{d}:{s}", .{ db, key });
        return .{ .key = owned, .owned = owned };
    };
    const total = prefix.len + key.len;
    if (total <= stack.len) {
        std.mem.copyForwards(u8, stack[prefix.len..total], key);
        return .{ .key = stack[0..total] };
    }
    const owned = try std.fmt.allocPrint(allocator, "db:{d}:{s}", .{ db, key });
    return .{ .key = owned, .owned = owned };
}

fn equalsAsciiUpper(s: []const u8, comptime upper: []const u8) bool {
    if (s.len != upper.len) return false;
    for (s, 0..) |c, i| {
        if (std.ascii.toUpper(c) != upper[i]) return false;
    }
    return true;
}

fn parseIntLine(data: []const u8, pos: *usize) !i64 {
    const start = pos.*;
    while (pos.* + 1 < data.len) : (pos.* += 1) {
        if (data[pos.*] == '\r' and data[pos.* + 1] == '\n') {
            const line = data[start..pos.*];
            pos.* += 2;
            return std.fmt.parseInt(i64, line, 10);
        }
    }
    return error.Incomplete;
}

fn writeIntegerPacked(fd: posix.socket_t, n: i64) void {
    var buf: [64]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, ":{d}\r\n", .{n}) catch return;
    writeAll(fd, out);
}

fn writeBulkPacked(fd: posix.socket_t, data: ?[]const u8) void {
    if (data) |d| {
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "${d}\r\n", .{d.len}) catch return;
        const total = h.len + d.len + 2;
        if (total <= 16 * 1024) {
            var buf: [16 * 1024]u8 = undefined;
            std.mem.copyForwards(u8, buf[0..h.len], h);
            std.mem.copyForwards(u8, buf[h.len .. h.len + d.len], d);
            buf[h.len + d.len] = '\r';
            buf[h.len + d.len + 1] = '\n';
            writeAll(fd, buf[0..total]);
        } else {
            writeAll(fd, h);
            writeAll(fd, d);
            writeAll(fd, "\r\n");
        }
    } else {
        writeAll(fd, "$-1\r\n");
    }
}

fn findCRLF(data: []const u8) ?usize {
    if (data.len < 2) return null;
    for (0..data.len - 1) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n') return i;
    }
    return null;
}

fn writeAll(fd: posix.socket_t, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const slice = data[written..];
        const rc = std.c.write(fd, slice.ptr, slice.len);
        if (rc <= 0) return;
        written += @intCast(rc);
    }
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[vex] " ++ fmt ++ "\n", args);
}
