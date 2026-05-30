// Migrated unit tests for src/engine/set.zig.

const std = @import("std");
const SetStore = @import("../../../src/engine/set.zig").SetStore;

test "SADD and SISMEMBER" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    const added = try store.sadd("s", &[_][]const u8{ "a", "b", "c", "a" });
    try std.testing.expectEqual(@as(usize, 3), added); // "a" duplicate ignored
    try std.testing.expect(store.sismember("s", "a"));
    try std.testing.expect(store.sismember("s", "b"));
    try std.testing.expect(!store.sismember("s", "x"));
}

test "SREM" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("s", &[_][]const u8{ "a", "b", "c" });
    const removed = store.srem("s", &[_][]const u8{ "a", "x" });
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 2), store.scard("s"));
    try std.testing.expect(!store.sismember("s", "a"));
}

test "SMEMBERS" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("s", &[_][]const u8{ "x", "y" });
    const members = try store.smembers("s", std.testing.allocator);
    defer std.testing.allocator.free(members);
    try std.testing.expectEqual(@as(usize, 2), members.len);
}

test "SUNION" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("a", &[_][]const u8{ "1", "2" });
    _ = try store.sadd("b", &[_][]const u8{ "2", "3" });
    const u = try store.sunion(&[_][]const u8{ "a", "b" }, std.testing.allocator);
    defer std.testing.allocator.free(u);
    try std.testing.expectEqual(@as(usize, 3), u.len);
}

test "SINTER" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("a", &[_][]const u8{ "1", "2", "3" });
    _ = try store.sadd("b", &[_][]const u8{ "2", "3", "4" });
    const inter = try store.sinter(&[_][]const u8{ "a", "b" }, std.testing.allocator);
    defer std.testing.allocator.free(inter);
    try std.testing.expectEqual(@as(usize, 2), inter.len);
}

test "SDIFF" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("a", &[_][]const u8{ "1", "2", "3" });
    _ = try store.sadd("b", &[_][]const u8{ "2", "4" });
    const d = try store.sdiff(&[_][]const u8{ "a", "b" }, std.testing.allocator);
    defer std.testing.allocator.free(d);
    try std.testing.expectEqual(@as(usize, 2), d.len);
}

test "empty after SREM auto-deletes" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("tmp", &[_][]const u8{"x"});
    _ = store.srem("tmp", &[_][]const u8{"x"});
    try std.testing.expect(!store.exists("tmp"));
}
