const std = @import("std");

/// Optional command-latency profile aggregator for benchmarking.
/// Uses atomics so it can be updated from multiple client threads.
pub const Profile = struct {
    io: std.Io,
    report_every: u64,

    parse_ns: std.atomic.Value(u64) = .init(0),
    parse_n: std.atomic.Value(u64) = .init(0),

    /// Time blocked on the global command mutex (legacy threaded mode only).
    lock_wait_ns: std.atomic.Value(u64) = .init(0),
    lock_wait_n: std.atomic.Value(u64) = .init(0),

    /// Time inside `CommandHandler.execute` (single-writer or post-lock).
    exec_ns: std.atomic.Value(u64) = .init(0),
    exec_n: std.atomic.Value(u64) = .init(0),

    /// Time in `write(2)` for the response bytes.
    write_ns: std.atomic.Value(u64) = .init(0),
    write_n: std.atomic.Value(u64) = .init(0),

    /// Time from job enqueue until the engine thread starts it (single-writer mode).
    queue_wait_ns: std.atomic.Value(u64) = .init(0),
    queue_wait_n: std.atomic.Value(u64) = .init(0),

    aof_write_ns: std.atomic.Value(u64) = .init(0),
    aof_write_n: std.atomic.Value(u64) = .init(0),

    /// Time the engine thread blocks in popBatchBlocking (idle time between batches).
    batch_wait_ns: std.atomic.Value(u64) = .init(0),
    batch_wait_n: std.atomic.Value(u64) = .init(0),

    /// Sum of batch sizes (to compute average).
    batch_size_sum: std.atomic.Value(u64) = .init(0),
    batch_count: std.atomic.Value(u64) = .init(0),

    /// Per-job overhead: alloc/free, profiling timestamps, etc.
    job_overhead_ns: std.atomic.Value(u64) = .init(0),
    job_overhead_n: std.atomic.Value(u64) = .init(0),

    /// One bump per completed command (drives periodic snapshot).
    total_cmds: std.atomic.Value(u64) = .init(0),

    pub fn init(io: std.Io, report_every: u64) Profile {
        return .{
            .io = io,
            .report_every = report_every,
        };
    }

    pub fn recordParse(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.parse_n.fetchAdd(1, .monotonic);
        _ = self.parse_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    pub fn recordLockWait(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.lock_wait_n.fetchAdd(1, .monotonic);
        _ = self.lock_wait_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    pub fn recordExec(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.exec_n.fetchAdd(1, .monotonic);
        _ = self.exec_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    pub fn recordWrite(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.write_n.fetchAdd(1, .monotonic);
        _ = self.write_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    pub fn recordQueueWait(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.queue_wait_n.fetchAdd(1, .monotonic);
        _ = self.queue_wait_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    pub fn recordBatchWait(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.batch_wait_n.fetchAdd(1, .monotonic);
        _ = self.batch_wait_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    pub fn recordBatchSize(self: *Profile, size: u64) void {
        _ = self.batch_count.fetchAdd(1, .monotonic);
        _ = self.batch_size_sum.fetchAdd(size, .monotonic);
    }

    pub fn recordJobOverhead(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.job_overhead_n.fetchAdd(1, .monotonic);
        _ = self.job_overhead_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    pub fn recordAofWrite(self: *Profile, ns: i64) void {
        if (ns <= 0) return;
        _ = self.aof_write_n.fetchAdd(1, .monotonic);
        _ = self.aof_write_ns.fetchAdd(@as(u64, @intCast(ns)), .monotonic);
    }

    /// Call once after a command is fully handled (after write).
    pub fn bumpCommand(self: *Profile) void {
        const cur = self.total_cmds.fetchAdd(1, .monotonic) + 1;
        if (self.report_every > 0 and cur % self.report_every == 0) {
            self.printSnapshot(cur);
        }
    }

    fn printSnapshot(self: *Profile, cmd_count: u64) void {
        const pn = self.parse_n.load(.monotonic);
        const lwn = self.lock_wait_n.load(.monotonic);
        const en = self.exec_n.load(.monotonic);
        const wn = self.write_n.load(.monotonic);
        const qn = self.queue_wait_n.load(.monotonic);
        const an = self.aof_write_n.load(.monotonic);
        const bwn = self.batch_wait_n.load(.monotonic);
        const bcnt = self.batch_count.load(.monotonic);
        const bsum = self.batch_size_sum.load(.monotonic);
        const jon = self.job_overhead_n.load(.monotonic);

        const pns = self.parse_ns.load(.monotonic);
        const lwns = self.lock_wait_ns.load(.monotonic);
        const ens = self.exec_ns.load(.monotonic);
        const wns = self.write_ns.load(.monotonic);
        const qns = self.queue_wait_ns.load(.monotonic);
        const ans = self.aof_write_ns.load(.monotonic);
        const bwns = self.batch_wait_ns.load(.monotonic);
        const jons = self.job_overhead_ns.load(.monotonic);

        const avg = struct {
            fn us(sum: u64, n: u64) f64 {
                if (n == 0) return 0.0;
                return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n)) / 1000.0;
            }
        }.us;

        const parse_avg_us = avg(pns, pn);
        const lock_wait_avg_us = avg(lwns, lwn);
        const exec_avg_us = avg(ens, en);
        const write_avg_us = avg(wns, wn);
        const queue_wait_avg_us = avg(qns, qn);
        const aof_avg_us = avg(ans, an);
        const batch_wait_avg_us = avg(bwns, bwn);
        const avg_batch_size: f64 = if (bcnt > 0) @as(f64, @floatFromInt(bsum)) / @as(f64, @floatFromInt(bcnt)) else 0.0;
        const job_overhead_avg_us = avg(jons, jon);

        std.debug.print(
            "[vex-profile] cmds={d} parse={d:.2}us queue_wait={d:.2}us exec={d:.2}us write={d:.2}us batch_wait={d:.2}us job_oh={d:.2}us avg_batch={d:.1} aof={d:.2}us lock={d:.2}us\n",
            .{ cmd_count, parse_avg_us, queue_wait_avg_us, exec_avg_us, write_avg_us, batch_wait_avg_us, job_overhead_avg_us, avg_batch_size, aof_avg_us, lock_wait_avg_us },
        );
        _ = self.io;
    }
};

pub fn monotonicNs(t0: std.Io.Clock.Timestamp, t1: std.Io.Clock.Timestamp) i64 {
    return @intCast(t0.durationTo(t1).raw.toNanoseconds());
}
