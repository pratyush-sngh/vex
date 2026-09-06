// Migrated unit tests for src/engine/types/list.zig.

const std = @import("std");
const ListStore = @import("../../../src/engine/types/list.zig").ListStore;

test "LPUSH and RPUSH" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("mylist", &[_][]const u8{ "a", "b" });
    _ = try store.lpush("mylist", &[_][]const u8{"z"});

    try std.testing.expectEqual(@as(usize, 3), store.llen("mylist"));
    try std.testing.expectEqualStrings("z", store.lindex("mylist", 0).?);
    try std.testing.expectEqualStrings("a", store.lindex("mylist", 1).?);
    try std.testing.expectEqualStrings("b", store.lindex("mylist", 2).?);
}

test "LPOP and RPOP" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("q", &[_][]const u8{ "1", "2", "3" });

    const left = store.lpop("q").?;
    defer ListStore.freeVal(std.testing.allocator, left);
    try std.testing.expectEqualStrings("1", left);

    const right = store.rpop("q").?;
    defer ListStore.freeVal(std.testing.allocator, right);
    try std.testing.expectEqualStrings("3", right);

    try std.testing.expectEqual(@as(usize, 1), store.llen("q"));
}

test "LRANGE" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("r", &[_][]const u8{ "a", "b", "c", "d", "e" });

    const range = store.lrange("r", 1, 3).?;
    defer std.testing.allocator.free(range);
    try std.testing.expectEqual(@as(usize, 3), range.len);
    try std.testing.expectEqualStrings("b", range[0]);
    try std.testing.expectEqualStrings("d", range[2]);

    // Negative indexes
    const tail = store.lrange("r", -2, -1).?;
    defer std.testing.allocator.free(tail);
    try std.testing.expectEqual(@as(usize, 2), tail.len);
    try std.testing.expectEqualStrings("d", tail[0]);
    try std.testing.expectEqualStrings("e", tail[1]);
}

test "LSET and LREM" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("s", &[_][]const u8{ "a", "b", "a", "c", "a" });

    try store.lset("s", 1, "B");
    try std.testing.expectEqualStrings("B", store.lindex("s", 1).?);

    const removed = store.lrem("s", 2, "a");
    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expectEqual(@as(usize, 3), store.llen("s"));
}

test "LINDEX negative" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("n", &[_][]const u8{ "x", "y", "z" });
    try std.testing.expectEqualStrings("z", store.lindex("n", -1).?);
    try std.testing.expectEqualStrings("x", store.lindex("n", -3).?);
    try std.testing.expect(store.lindex("n", -4) == null);
    try std.testing.expect(store.lindex("n", 3) == null);
}

test "empty after pop keeps key (deferred cleanup)" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("tmp", &[_][]const u8{"x"});
    const v = store.rpop("tmp").?;
    defer ListStore.freeVal(std.testing.allocator, v);
    try std.testing.expectEqualStrings("x", v);
    // Key still exists (empty list) — block memory keeps val alive.
    // Cleanup happens on next operation or DEL/FLUSHALL.
    try std.testing.expectEqual(@as(usize, 0), store.llen("tmp"));
}

// Regression: popTail must decrement cumcount[last] symmetrically to
// pushTail's bump. Sequence: fill past one block, RPOP a few to drift the
// last block's cumcount, then RPUSH enough to overflow into a new block.
// Without the fix, the new block inherits the drift via prev_cum and
// binary search routes near-boundary reads to the wrong block.
test "RPOP then RPUSH across block boundary keeps reads correct" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    // ~155 bytes per entry → ~52 entries per 8KB block (size-limited).
    var buf: [200]u8 = undefined;

    var i: usize = 0;
    while (i < 70) : (i += 1) {
        const s = try std.fmt.bufPrint(&buf, "v{d:0>150}", .{i});
        _ = try store.rpush("L", &[_][]const u8{s});
    }

    var p: usize = 0;
    while (p < 5) : (p += 1) _ = store.rpop("L").?;

    i = 0;
    while (i < 50) : (i += 1) {
        const s = try std.fmt.bufPrint(&buf, "w{d:0>149}", .{i});
        _ = try store.rpush("L", &[_][]const u8{s});
    }

    try std.testing.expectEqual(@as(usize, 115), store.llen("L"));

    var verify_buf: [200]u8 = undefined;
    const expected_v64 = try std.fmt.bufPrint(&verify_buf, "v{d:0>150}", .{64});
    try std.testing.expectEqualStrings(expected_v64, store.lindex("L", 64).?);

    const expected_w0 = try std.fmt.bufPrint(&verify_buf, "w{d:0>149}", .{0});
    try std.testing.expectEqualStrings(expected_w0, store.lindex("L", 65).?);

    const expected_w39 = try std.fmt.bufPrint(&verify_buf, "w{d:0>149}", .{39});
    try std.testing.expectEqualStrings(expected_w39, store.lindex("L", 104).?);

    const expected_w44 = try std.fmt.bufPrint(&verify_buf, "w{d:0>149}", .{44});
    try std.testing.expectEqualStrings(expected_w44, store.lindex("L", 109).?);

    const expected_w49 = try std.fmt.bufPrint(&verify_buf, "w{d:0>149}", .{49});
    try std.testing.expectEqualStrings(expected_w49, store.lindex("L", 114).?);

    try std.testing.expect(store.lindex("L", 115) == null);
}
