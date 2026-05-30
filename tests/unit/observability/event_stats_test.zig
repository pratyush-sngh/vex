// Migrated unit tests for src/observability/event_stats.zig.

const std = @import("std");
const event_stats = @import("../../../src/observability/event_stats.zig");

const EventKind = event_stats.EventKind;
const RING_LEN = event_stats.RING_LEN;
const threshold_us = &event_stats.threshold_us;
const record = event_stats.record;
const latest = event_stats.latest;
const history = event_stats.history;
const resetAll = event_stats.resetAll;

test "record + latest" {
    _ = resetAll();
    threshold_us.store(0, .monotonic);
    defer threshold_us.store(100_000, .monotonic);

    record(.aof_fsync, 1500);
    record(.aof_fsync, 2500);

    const li = latest(.aof_fsync);
    try std.testing.expect(li.sample != null);
    try std.testing.expectEqual(@as(u64, 2500), li.sample.?.duration_us);
    try std.testing.expectEqual(@as(u64, 2500), li.max_us);
}

test "threshold filters" {
    _ = resetAll();
    threshold_us.store(1_000, .monotonic);
    defer threshold_us.store(100_000, .monotonic);

    record(.aof_fsync, 500); // below threshold — dropped
    record(.aof_fsync, 2500); // above threshold — kept

    const li = latest(.aof_fsync);
    try std.testing.expectEqual(@as(u64, 2500), li.sample.?.duration_us);
}

test "history newest-first" {
    _ = resetAll();
    threshold_us.store(0, .monotonic);
    defer threshold_us.store(100_000, .monotonic);

    record(.snapshot_save, 100);
    record(.snapshot_save, 200);
    record(.snapshot_save, 300);

    const h = try history(std.testing.allocator, .snapshot_save);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqual(@as(usize, 3), h.len);
    try std.testing.expectEqual(@as(u64, 300), h[0].duration_us);
    try std.testing.expectEqual(@as(u64, 200), h[1].duration_us);
    try std.testing.expectEqual(@as(u64, 100), h[2].duration_us);
}

test "ring wraps preserving newest" {
    _ = resetAll();
    threshold_us.store(0, .monotonic);
    defer threshold_us.store(100_000, .monotonic);

    var i: u64 = 0;
    while (i < RING_LEN + 5) : (i += 1) {
        record(.eviction_cycle, i);
    }
    const h = try history(std.testing.allocator, .eviction_cycle);
    defer std.testing.allocator.free(h);
    try std.testing.expectEqual(RING_LEN, h.len);
    try std.testing.expectEqual(@as(u64, RING_LEN + 4), h[0].duration_us);
    try std.testing.expectEqual(@as(u64, 5), h[RING_LEN - 1].duration_us);
}

test "EventKind round-trip" {
    inline for ([_]EventKind{ .aof_fsync, .aof_rewrite, .snapshot_save, .snapshot_load, .eviction_cycle }) |k| {
        try std.testing.expectEqual(k, EventKind.fromName(k.name()).?);
    }
    try std.testing.expect(EventKind.fromName("definitely-not-a-kind") == null);
}
