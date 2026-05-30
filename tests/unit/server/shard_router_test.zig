// Migrated unit tests for src/server/shard_router.zig.

const std = @import("std");
const sr = @import("../../../src/server/shard_router.zig");

const slotForKey = sr.slotForKey;
const workerForKey = sr.workerForKey;
const MpscQueue = sr.MpscQueue;
const TOTAL_SLOTS = sr.TOTAL_SLOTS;

test "slot computation is deterministic" {
    const s1 = slotForKey("hello");
    const s2 = slotForKey("hello");
    try std.testing.expectEqual(s1, s2);
}

test "slot distributes across range" {
    const s1 = slotForKey("key:0");
    const s2 = slotForKey("key:99999");
    try std.testing.expect(s1 != s2);
    try std.testing.expect(s1 < TOTAL_SLOTS);
    try std.testing.expect(s2 < TOTAL_SLOTS);
}

test "worker routing" {
    const w1 = workerForKey("key:a", 4);
    const w2 = workerForKey("key:b", 4);
    try std.testing.expect(w1 < 4);
    try std.testing.expect(w2 < 4);
}

test "mpsc queue push pop" {
    var q = MpscQueue(u32, 8){};
    try std.testing.expect(q.push(42));
    try std.testing.expect(q.push(99));
    try std.testing.expectEqual(@as(?u32, 42), q.pop());
    try std.testing.expectEqual(@as(?u32, 99), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "mpsc queue full" {
    var q = MpscQueue(u32, 4){};
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));
    try std.testing.expect(q.push(4));
    try std.testing.expect(!q.push(5)); // full
    _ = q.pop();
    try std.testing.expect(q.push(5)); // space available
}
