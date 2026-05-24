//! Per-worker observability counters.
//!
//! Design contract: every counter in `WorkerStats` is written by exactly one
//! worker thread (no atomics on writes, no cross-thread contention).
//! Aggregation across workers happens lazily at read time (INFO, /metrics)
//! via `@atomicLoad` to avoid torn reads on non-x86.
//!
//! The global `workers` slice holds pointers to each worker's stats so
//! readers can iterate. Registration is one-time at worker startup;
//! it's protected by a mutex but not on any hot path.

const std = @import("std");
const cmd_table = @import("cmd_table.zig");

pub const N_CMDS = cmd_table.N_CMDS;

/// Per-worker counters. Writes are single-owner (the owning worker thread),
/// so no atomics are needed on increment. Readers iterate `workers` and use
/// `@atomicLoad(.monotonic)` to grab a snapshot.
pub const WorkerStats = struct {
    /// Per-command call counts. Indexed by `cmd_table.lookup(name)`.
    cmd_calls: [N_CMDS]u64 = @splat(0),

    pub fn init() WorkerStats {
        return .{};
    }

    /// Record that one command was dispatched. Caller passes the
    /// pre-resolved index from `cmd_table.lookup`.
    pub inline fn recordCall(self: *WorkerStats, cmd_idx: u8) void {
        // Single-owner write. No atomic needed.
        self.cmd_calls[cmd_idx] += 1;
    }
};

/// Global registry. Populated at worker init via `register()`.
/// Read by INFO and (later) /metrics.
var workers_buf: [MAX_WORKERS]*WorkerStats = undefined;
var workers_len: usize = 0;
var workers_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

pub const MAX_WORKERS: usize = 64;

/// Add a worker's stats to the global registry. Idempotent: re-registering
/// the same pointer is a no-op. Returns false if the registry is full.
pub fn register(stats: *WorkerStats) bool {
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    for (workers_buf[0..workers_len]) |existing| {
        if (existing == stats) return true;
    }
    if (workers_len >= MAX_WORKERS) return false;
    workers_buf[workers_len] = stats;
    workers_len += 1;
    return true;
}

/// Remove a worker's stats from the registry (worker is shutting down).
pub fn unregister(stats: *WorkerStats) void {
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    var i: usize = 0;
    while (i < workers_len) : (i += 1) {
        if (workers_buf[i] == stats) {
            workers_buf[i] = workers_buf[workers_len - 1];
            workers_len -= 1;
            return;
        }
    }
}

/// Reset the global registry. For tests only.
pub fn resetForTest() void {
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    workers_len = 0;
}

/// Aggregate per-command call counts across all registered workers.
/// Reader-side. Uses atomic loads to tolerate concurrent writes.
pub fn aggregateCmdCalls(out: *[N_CMDS]u64) void {
    @memset(out, 0);
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    for (workers_buf[0..workers_len]) |w| {
        for (0..N_CMDS) |i| {
            out[i] +%= @atomicLoad(u64, &w.cmd_calls[i], .monotonic);
        }
    }
}

/// Total commands across all workers.
pub fn totalCommands() u64 {
    var sum: u64 = 0;
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    for (workers_buf[0..workers_len]) |w| {
        for (0..N_CMDS) |i| {
            sum +%= @atomicLoad(u64, &w.cmd_calls[i], .monotonic);
        }
    }
    return sum;
}

// ── Tests ───────────────────────────────────────────────────────────

test "register and aggregate" {
    resetForTest();
    var s1 = WorkerStats.init();
    var s2 = WorkerStats.init();
    try std.testing.expect(register(&s1));
    try std.testing.expect(register(&s2));

    const get_idx = cmd_table.lookup("GET");
    const set_idx = cmd_table.lookup("SET");

    s1.recordCall(get_idx);
    s1.recordCall(get_idx);
    s1.recordCall(set_idx);
    s2.recordCall(get_idx);

    var totals: [N_CMDS]u64 = undefined;
    aggregateCmdCalls(&totals);
    try std.testing.expectEqual(@as(u64, 3), totals[get_idx]);
    try std.testing.expectEqual(@as(u64, 1), totals[set_idx]);
    try std.testing.expectEqual(@as(u64, 4), totalCommands());

    resetForTest();
}

test "register is idempotent" {
    resetForTest();
    var s = WorkerStats.init();
    try std.testing.expect(register(&s));
    try std.testing.expect(register(&s));
    s.recordCall(cmd_table.lookup("GET"));
    try std.testing.expectEqual(@as(u64, 1), totalCommands());
    resetForTest();
}

test "unregister" {
    resetForTest();
    var s1 = WorkerStats.init();
    var s2 = WorkerStats.init();
    _ = register(&s1);
    _ = register(&s2);
    s1.recordCall(0);
    s2.recordCall(0);
    try std.testing.expectEqual(@as(u64, 2), totalCommands());
    unregister(&s1);
    try std.testing.expectEqual(@as(u64, 1), totalCommands());
    resetForTest();
}

test "unknown command bucketed to OTHER" {
    resetForTest();
    var s = WorkerStats.init();
    _ = register(&s);
    s.recordCall(cmd_table.lookup("DEFINITELY_NOT_A_COMMAND"));
    var totals: [N_CMDS]u64 = undefined;
    aggregateCmdCalls(&totals);
    try std.testing.expectEqual(@as(u64, 1), totals[cmd_table.OTHER_IDX]);
    resetForTest();
}
