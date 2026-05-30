// Migrated unit tests for src/engine/sorted_set.zig.

const std = @import("std");
const SortedSetStore = @import("../../../src/engine/sorted_set.zig").SortedSetStore;

test "ZADD and ZSCORE" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    const added = try store.zadd("lb", &[_][]const u8{ "10", "alice", "20", "bob", "15", "carol" });
    try std.testing.expectEqual(@as(usize, 3), added);
    try std.testing.expectEqual(@as(f64, 10.0), store.zscore("lb", "alice").?);
    try std.testing.expectEqual(@as(f64, 20.0), store.zscore("lb", "bob").?);
    try std.testing.expect(store.zscore("lb", "missing") == null);
}

test "ZADD updates score" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.zadd("z", &[_][]const u8{ "10", "a" });
    const added = try store.zadd("z", &[_][]const u8{ "99", "a" });
    try std.testing.expectEqual(@as(usize, 0), added); // not new
    try std.testing.expectEqual(@as(f64, 99.0), store.zscore("z", "a").?);
}

test "ZREM" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.zadd("z", &[_][]const u8{ "1", "a", "2", "b", "3", "c" });
    const removed = store.zrem("z", &[_][]const u8{ "a", "x" });
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 2), store.zcard("z"));
}

test "ZRANGE" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.zadd("z", &[_][]const u8{ "30", "c", "10", "a", "20", "b" });
    const range = try store.zrange("z", 0, -1, std.testing.allocator);
    defer std.testing.allocator.free(range);
    try std.testing.expectEqual(@as(usize, 3), range.len);
    try std.testing.expectEqualStrings("a", range[0].member); // score 10
    try std.testing.expectEqualStrings("b", range[1].member); // score 20
    try std.testing.expectEqualStrings("c", range[2].member); // score 30

    // Sub-range
    const sub = try store.zrange("z", 0, 1, std.testing.allocator);
    defer std.testing.allocator.free(sub);
    try std.testing.expectEqual(@as(usize, 2), sub.len);
}

test "ZRANK" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.zadd("z", &[_][]const u8{ "30", "c", "10", "a", "20", "b" });
    const rank_a = store.zrank("z", "a");
    try std.testing.expectEqual(@as(usize, 0), rank_a.?);
    const rank_c = store.zrank("z", "c");
    try std.testing.expectEqual(@as(usize, 2), rank_c.?);
    const rank_x = store.zrank("z", "missing");
    try std.testing.expect(rank_x == null);
}

test "ZINCRBY" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    const s1 = try store.zincrby("z", 5.0, "player");
    try std.testing.expectEqual(@as(f64, 5.0), s1);
    const s2 = try store.zincrby("z", 3.0, "player");
    try std.testing.expectEqual(@as(f64, 8.0), s2);
}

test "ZCOUNT" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.zadd("z", &[_][]const u8{ "1", "a", "5", "b", "10", "c", "15", "d" });
    try std.testing.expectEqual(@as(usize, 2), store.zcount("z", 5, 10));
    try std.testing.expectEqual(@as(usize, 4), store.zcount("z", 0, 100));
    try std.testing.expectEqual(@as(usize, 0), store.zcount("z", 50, 100));
}

test "empty after ZREM auto-deletes" {
    var store = SortedSetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.zadd("tmp", &[_][]const u8{ "1", "x" });
    _ = store.zrem("tmp", &[_][]const u8{"x"});
    try std.testing.expect(!store.exists("tmp"));
}
