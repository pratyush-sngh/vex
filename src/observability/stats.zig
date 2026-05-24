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

/// Per-worker slowlog ring capacity. Compile-time constant so each
/// WorkerStats has fixed footprint (no heap for the ring slots themselves;
/// only for the args blob held by each occupied slot).
pub const SLOWLOG_RING_LEN: usize = 128;

/// Maximum bytes we'll copy from the command-line for a slowlog entry.
/// Mirrors Redis's per-arg cap; total budget per entry ~= this.
pub const SLOWLOG_ARGS_MAX: usize = 256;

/// One slot in a worker's slowlog ring. The args_blob is a packed buffer
/// `<u8 argc> <u8 len0> <bytes0> <u8 len1> <bytes1> ...` truncated to
/// SLOWLOG_ARGS_MAX bytes. Owning worker allocates/frees.
pub const SlowlogEntry = struct {
    id: u64,
    ts_ms: i64,
    duration_us: u64,
    cmd_idx: u8,
    args_blob: []u8,
};

/// Per-worker counters. Writes are single-owner (the owning worker thread),
/// so no atomics are needed on increment. Readers iterate `workers` and use
/// `@atomicLoad(.monotonic)` to grab a snapshot.
pub const WorkerStats = struct {
    /// Per-command call counts. Indexed by `cmd_table.lookup(name)`.
    cmd_calls: [N_CMDS]u64 = @splat(0),

    /// Total RESP error replies this worker has emitted.
    total_errors: u64 = 0,
    /// Connections accepted on this worker (cumulative).
    accepted_conns: u64 = 0,
    /// Connections rejected because the server hit `maxclients`.
    rejected_conns: u64 = 0,
    /// Cumulative bytes read from clients (RESP frames including headers).
    net_in_bytes: u64 = 0,
    /// Cumulative bytes written to clients.
    net_out_bytes: u64 = 0,

    /// Per-worker slowlog ring (single-owner writes, snapshot reads under
    /// the workers_mutex). slowlog_id is monotonic across the worker.
    slowlog: [SLOWLOG_RING_LEN]SlowlogEntry = std.mem.zeroes([SLOWLOG_RING_LEN]SlowlogEntry),
    /// Number of currently-occupied slowlog slots (≤ SLOWLOG_RING_LEN).
    slowlog_len: u32 = 0,
    /// Insertion cursor — wraps within SLOWLOG_RING_LEN.
    slowlog_head: u32 = 0,
    /// Next id to assign — monotonic across the worker's lifetime.
    slowlog_next_id: u64 = 0,

    pub fn init() WorkerStats {
        return .{};
    }

    /// Record that one command was dispatched. Caller passes the
    /// pre-resolved index from `cmd_table.lookup`.
    pub inline fn recordCall(self: *WorkerStats, cmd_idx: u8) void {
        // Single-owner write. No atomic needed.
        self.cmd_calls[cmd_idx] += 1;
    }

    /// Append a slowlog entry, evicting the oldest slot if the ring is
    /// full. Single-owner. `alloc` is used to dupe an args blob; the
    /// previous occupant's blob (if any) is freed.
    pub fn pushSlowlog(
        self: *WorkerStats,
        alloc: std.mem.Allocator,
        cmd_idx: u8,
        duration_us: u64,
        ts_ms: i64,
        args: []const []const u8,
    ) void {
        // Build the args blob into a small stack buffer first.
        var buf: [SLOWLOG_ARGS_MAX]u8 = undefined;
        const blob_len = packArgs(&buf, args);
        const blob = alloc.dupe(u8, buf[0..blob_len]) catch return;

        const slot = &self.slowlog[self.slowlog_head];
        // Free previous occupant's blob if this slot was used before.
        if (slot.args_blob.len > 0) alloc.free(slot.args_blob);

        slot.* = .{
            .id = self.slowlog_next_id,
            .ts_ms = ts_ms,
            .duration_us = duration_us,
            .cmd_idx = cmd_idx,
            .args_blob = blob,
        };
        self.slowlog_next_id += 1;
        self.slowlog_head = (self.slowlog_head + 1) % @as(u32, @intCast(SLOWLOG_RING_LEN));
        if (self.slowlog_len < SLOWLOG_RING_LEN) self.slowlog_len += 1;
    }

    /// Reset the slowlog ring. Frees all blobs.
    pub fn resetSlowlog(self: *WorkerStats, alloc: std.mem.Allocator) void {
        for (&self.slowlog) |*slot| {
            if (slot.args_blob.len > 0) {
                alloc.free(slot.args_blob);
                slot.args_blob = &.{};
            }
        }
        self.slowlog_len = 0;
        self.slowlog_head = 0;
        // slowlog_next_id stays monotonic across resets — match Redis.
    }
};

/// Pack command args into `<argc:u8><len0:u8><bytes0>...` with total cap.
/// Args are truncated individually if needed; trailing args may be dropped.
pub fn packArgs(buf: []u8, args: []const []const u8) usize {
    if (buf.len == 0) return 0;
    var pos: usize = 1;
    var written_argc: u8 = 0;
    const max_argc: usize = @min(args.len, 32);
    for (args[0..max_argc]) |a| {
        if (pos + 1 >= buf.len) break;
        const room = buf.len - pos - 1;
        const take = @min(a.len, @min(room, 64));
        buf[pos] = @intCast(take);
        pos += 1;
        @memcpy(buf[pos..][0..take], a[0..take]);
        pos += take;
        written_argc += 1;
    }
    buf[0] = written_argc;
    return pos;
}

/// Iterate args packed by `packArgs`. Calls `cb` with each (idx, bytes).
pub fn unpackArgs(blob: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), u8, []const u8) anyerror!void) !void {
    if (blob.len == 0) return;
    const argc = blob[0];
    var pos: usize = 1;
    var i: u8 = 0;
    while (i < argc and pos < blob.len) : (i += 1) {
        const alen = blob[pos];
        pos += 1;
        if (pos + alen > blob.len) return;
        try cb(ctx, i, blob[pos .. pos + alen]);
        pos += alen;
    }
}

/// Process-wide counters that don't fit per-worker ownership (events that
/// fire in shared code paths). Uses atomics — these fire on rare events
/// (eviction, expiration, accept/close) so contention is irrelevant.
pub var evicted_keys: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var expired_keys: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Currently-connected client count. Incremented on each accept,
/// decremented on each close. Mirrors the per-server active_connections
/// atomic for easy reader access from handler/INFO.
pub var connected_clients: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Wall-clock timestamp (ms since epoch) of the process start. Set once at
/// startup, read by INFO for `uptime_in_seconds`.
pub var start_time_ms: i64 = 0;

/// Set to true when the AOF flush path encountered an unrecoverable I/O
/// error (ENOSPC, EIO, etc.) and we can no longer guarantee durability.
/// Dispatch checks this and rejects write commands with -MISCONF; reads
/// continue. Cleared by CONFIG SET appendfsync no, or by restart after
/// the underlying issue is resolved.
pub var persistence_broken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Errno from the last fatal persistence failure (exposed via INFO).
pub var persistence_broken_errno: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

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

/// Aggregate snapshot of cross-worker scalars used by INFO.
pub const AggregateScalars = struct {
    total_errors: u64,
    accepted_conns: u64,
    rejected_conns: u64,
    net_in_bytes: u64,
    net_out_bytes: u64,
};

/// Total slowlog entries across all workers.
pub fn slowlogTotalLen() u64 {
    var sum: u64 = 0;
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    for (workers_buf[0..workers_len]) |w| {
        sum += @atomicLoad(u32, &w.slowlog_len, .monotonic);
    }
    return sum;
}

/// Snapshot the newest `n` slowlog entries across all workers, merged
/// newest-first by id. Returned slice owned by `alloc`; each entry's
/// args_blob is also duped into `alloc` so the snapshot is freestanding.
pub const SlowlogSnapshotEntry = SlowlogEntry;

pub fn slowlogSnapshot(alloc: std.mem.Allocator, n: usize) ![]SlowlogSnapshotEntry {
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);

    // Collect all entries from all workers into a temporary list.
    var all = std.array_list.Managed(SlowlogSnapshotEntry).init(alloc);
    defer all.deinit();
    for (workers_buf[0..workers_len]) |w| {
        const wlen = @atomicLoad(u32, &w.slowlog_len, .monotonic);
        if (wlen == 0) continue;
        // Reconstruct slot ordering: head points to next-write slot.
        // Oldest slot is at `(head - wlen) mod RING_LEN`.
        const head = @atomicLoad(u32, &w.slowlog_head, .monotonic);
        const ring_len_u32: u32 = @intCast(SLOWLOG_RING_LEN);
        const start: u32 = (head + ring_len_u32 - wlen) % ring_len_u32;
        var i: u32 = 0;
        while (i < wlen) : (i += 1) {
            const slot = w.slowlog[(start + i) % ring_len_u32];
            if (slot.args_blob.len == 0) continue;
            const blob_copy = try alloc.dupe(u8, slot.args_blob);
            try all.append(.{
                .id = slot.id,
                .ts_ms = slot.ts_ms,
                .duration_us = slot.duration_us,
                .cmd_idx = slot.cmd_idx,
                .args_blob = blob_copy,
            });
        }
    }

    // Sort newest-first by id (id is process-wide monotonic per worker
    // but workers' streams interleave — id is still a good proxy for
    // recency since all workers move forward).
    const Lt = struct {
        fn lt(_: void, a: SlowlogSnapshotEntry, b: SlowlogSnapshotEntry) bool {
            return a.id > b.id;
        }
    };
    std.mem.sort(SlowlogSnapshotEntry, all.items, {}, Lt.lt);

    const out_len = @min(n, all.items.len);
    const out = try alloc.alloc(SlowlogSnapshotEntry, out_len);
    @memcpy(out, all.items[0..out_len]);
    // Items beyond out_len are leaks if we just truncate — free their blobs.
    for (all.items[out_len..]) |trimmed| alloc.free(trimmed.args_blob);
    return out;
}

/// Reset every worker's slowlog. Each worker's slot blobs are freed via
/// its own allocator passed in — caller is responsible for ensuring
/// `alloc` matches what the workers used (in practice the global
/// allocator).
pub fn slowlogResetAll(alloc: std.mem.Allocator) void {
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    for (workers_buf[0..workers_len]) |w| {
        w.resetSlowlog(alloc);
    }
}

pub fn aggregateScalars() AggregateScalars {
    var out: AggregateScalars = .{
        .total_errors = 0,
        .accepted_conns = 0,
        .rejected_conns = 0,
        .net_in_bytes = 0,
        .net_out_bytes = 0,
    };
    _ = std.c.pthread_mutex_lock(&workers_mutex);
    defer _ = std.c.pthread_mutex_unlock(&workers_mutex);
    for (workers_buf[0..workers_len]) |w| {
        out.total_errors    +%= @atomicLoad(u64, &w.total_errors,    .monotonic);
        out.accepted_conns  +%= @atomicLoad(u64, &w.accepted_conns,  .monotonic);
        out.rejected_conns  +%= @atomicLoad(u64, &w.rejected_conns,  .monotonic);
        out.net_in_bytes    +%= @atomicLoad(u64, &w.net_in_bytes,    .monotonic);
        out.net_out_bytes   +%= @atomicLoad(u64, &w.net_out_bytes,   .monotonic);
    }
    return out;
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
