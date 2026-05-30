// Migrated unit tests for src/engine/hash.zig.

const std = @import("std");
const HashStore = @import("../../../src/engine/hash.zig").HashStore;

test "HSET and HGET" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    const added = try store.hset("user:1", &[_][]const u8{ "name", "Alice", "age", "30" });
    try std.testing.expectEqual(@as(usize, 2), added);

    try std.testing.expectEqualStrings("Alice", store.hget("user:1", "name").?);
    try std.testing.expectEqualStrings("30", store.hget("user:1", "age").?);
    try std.testing.expect(store.hget("user:1", "missing") == null);
}

test "HSET overwrites" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "f", "old" });
    const added = try store.hset("k", &[_][]const u8{ "f", "new" });
    try std.testing.expectEqual(@as(usize, 0), added); // no new fields
    try std.testing.expectEqualStrings("new", store.hget("k", "f").?);
}

test "HDEL" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "a", "1", "b", "2", "c", "3" });
    const removed = store.hdel("k", &[_][]const u8{ "a", "c", "nonexistent" });
    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expectEqual(@as(usize, 1), store.hlen("k"));
    try std.testing.expectEqualStrings("2", store.hget("k", "b").?);
}

test "HGETALL" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "x", "1", "y", "2" });
    const pairs = try store.hgetall("k", std.testing.allocator);
    defer std.testing.allocator.free(pairs);

    try std.testing.expectEqual(@as(usize, 4), pairs.len);
    // Order is not guaranteed, just check both pairs exist
    var found_x = false;
    var found_y = false;
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        if (std.mem.eql(u8, pairs[i], "x")) {
            try std.testing.expectEqualStrings("1", pairs[i + 1]);
            found_x = true;
        }
        if (std.mem.eql(u8, pairs[i], "y")) {
            try std.testing.expectEqualStrings("2", pairs[i + 1]);
            found_y = true;
        }
    }
    try std.testing.expect(found_x);
    try std.testing.expect(found_y);
}

test "HLEN and HEXISTS" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.hlen("k"));
    _ = try store.hset("k", &[_][]const u8{ "a", "1" });
    try std.testing.expectEqual(@as(usize, 1), store.hlen("k"));
    try std.testing.expect(store.hexists("k", "a"));
    try std.testing.expect(!store.hexists("k", "b"));
}

test "HKEYS and HVALS" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "name", "Bob", "age", "25" });

    const keys = try store.hkeys("k", std.testing.allocator);
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);

    const vals = try store.hvals("k", std.testing.allocator);
    defer std.testing.allocator.free(vals);
    try std.testing.expectEqual(@as(usize, 2), vals.len);
}

test "HINCRBY" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    // New field defaults to 0
    const v1 = try store.hincrby("k", "counter", 5);
    try std.testing.expectEqual(@as(i64, 5), v1);

    const v2 = try store.hincrby("k", "counter", -3);
    try std.testing.expectEqual(@as(i64, 2), v2);

    try std.testing.expectEqualStrings("2", store.hget("k", "counter").?);
}

test "empty after HDEL auto-deletes" {
    var store = HashStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.hset("tmp", &[_][]const u8{ "f", "v" });
    _ = store.hdel("tmp", &[_][]const u8{"f"});
    try std.testing.expect(!store.exists("tmp"));
}
