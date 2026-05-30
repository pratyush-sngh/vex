//! Latency event tracking for "rare slow events" — fsyncs, snapshots,
//! AOF rewrites, eviction sweeps. Things that aren't per-request commands
//! (SLOWLOG covers those) but can stall the server and need to be visible
//! to operators.
//!
//! Process-wide single instance. Events fire at most a few per second, so
//! the mutex is irrelevant for hot-path perf.

const std = @import("std");

pub const EventKind = enum(u8) {
    aof_fsync = 0,
    aof_rewrite = 1,
    snapshot_save = 2,
    snapshot_load = 3,
    eviction_cycle = 4,

    pub fn name(self: EventKind) []const u8 {
        return switch (self) {
            .aof_fsync => "aof-fsync",
            .aof_rewrite => "aof-rewrite",
            .snapshot_save => "snapshot-save",
            .snapshot_load => "snapshot-load",
            .eviction_cycle => "eviction-cycle",
        };
    }

    /// Returns the EventKind for a name string (Redis-style hyphenated),
    /// or null if unknown.
    pub fn fromName(s: []const u8) ?EventKind {
        if (std.ascii.eqlIgnoreCase(s, "aof-fsync")) return .aof_fsync;
        if (std.ascii.eqlIgnoreCase(s, "aof-rewrite")) return .aof_rewrite;
        if (std.ascii.eqlIgnoreCase(s, "snapshot-save")) return .snapshot_save;
        if (std.ascii.eqlIgnoreCase(s, "snapshot-load")) return .snapshot_load;
        if (std.ascii.eqlIgnoreCase(s, "eviction-cycle")) return .eviction_cycle;
        return null;
    }
};

pub const N_EVENT_KINDS: usize = 5;
pub const RING_LEN: usize = 32;

pub const EventSample = struct {
    ts_ms: i64,
    duration_us: u64,
};

const RingState = struct {
    samples: [RING_LEN]EventSample = std.mem.zeroes([RING_LEN]EventSample),
    /// Number of valid samples (≤ RING_LEN).
    len: u32 = 0,
    /// Insertion cursor, wraps mod RING_LEN.
    head: u32 = 0,
    /// Max duration ever observed for this kind, lifetime of process.
    max_us: u64 = 0,
};

/// Threshold below which events are NOT recorded. Default 100ms (Redis
/// `latency-monitor-threshold` default).
pub var threshold_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(100_000);

var rings: [N_EVENT_KINDS]RingState = @splat(.{});
var mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

/// Record an event. Cheap branch checks the threshold first so cold-path
/// callers pay nothing when the threshold isn't met.
pub fn record(kind: EventKind, duration_us: u64) void {
    if (duration_us < threshold_us.load(.monotonic)) return;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);

    const idx: usize = @intFromEnum(kind);
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    const r = &rings[idx];
    r.samples[r.head] = .{ .ts_ms = now_ms, .duration_us = duration_us };
    r.head = (r.head + 1) % @as(u32, @intCast(RING_LEN));
    if (r.len < RING_LEN) r.len += 1;
    if (duration_us > r.max_us) r.max_us = duration_us;
}

/// Most recent sample for `kind`, or null if none. Also returns the
/// all-time max for context.
pub const LatestInfo = struct {
    sample: ?EventSample,
    max_us: u64,
};

pub fn latest(kind: EventKind) LatestInfo {
    const idx: usize = @intFromEnum(kind);
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    const r = &rings[idx];
    if (r.len == 0) return .{ .sample = null, .max_us = r.max_us };
    const last_idx: u32 = (r.head + @as(u32, @intCast(RING_LEN)) - 1) % @as(u32, @intCast(RING_LEN));
    return .{ .sample = r.samples[last_idx], .max_us = r.max_us };
}

/// Copy the history of `kind` into a freshly-allocated slice (newest-first).
pub fn history(alloc: std.mem.Allocator, kind: EventKind) ![]EventSample {
    const idx: usize = @intFromEnum(kind);
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    const r = &rings[idx];
    const out = try alloc.alloc(EventSample, r.len);
    const start: u32 = (r.head + @as(u32, @intCast(RING_LEN)) - r.len) % @as(u32, @intCast(RING_LEN));
    var i: u32 = 0;
    while (i < r.len) : (i += 1) {
        // Newest-first: index out from the back of the ordered slice.
        const src_idx = (start + r.len - 1 - i) % @as(u32, @intCast(RING_LEN));
        out[i] = r.samples[src_idx];
    }
    return out;
}

/// Reset one ring. Returns true if any samples were cleared.
pub fn reset(kind: EventKind) bool {
    const idx: usize = @intFromEnum(kind);
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    const r = &rings[idx];
    const had_samples = r.len > 0;
    r.* = .{};
    return had_samples;
}

/// Reset every ring. Returns count of kinds that had samples.
pub fn resetAll() u32 {
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    var n: u32 = 0;
    for (&rings) |*r| {
        if (r.len > 0) n += 1;
        r.* = .{};
    }
    return n;
}

/// Helper for instrumented sites. Captures start time on construction;
/// caller calls `.end(kind)` on defer.
pub const Span = struct {
    start_ns: i128,

    pub fn begin() Span {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return .{ .start_ns = @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec)) };
    }

    pub fn end(self: Span, kind: EventKind) void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        const end_ns: i128 = @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
        const dur_us: u64 = @intCast(@max(0, @divTrunc(end_ns - self.start_ns, 1000)));
        record(kind, dur_us);
    }
};

