// Migrated unit tests for src/engine/types/hash.zig.

const std = @import("std");
const HashStore = @import("../../../src/engine/types/hash.zig").HashStore;

test "HSET and HGET" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    const added = try store.hset("user:1", &[_][]const u8{ "name", "Alice", "age", "30" });
    try std.testing.expectEqual(@as(usize, 2), added);

    try std.testing.expectEqualStrings("Alice", store.hget("user:1", "name").?);
    try std.testing.expectEqualStrings("30", store.hget("user:1", "age").?);
    try std.testing.expect(store.hget("user:1", "missing") == null);
}

test "HSET overwrites" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "f", "old" });
    const added = try store.hset("k", &[_][]const u8{ "f", "new" });
    try std.testing.expectEqual(@as(usize, 0), added); // no new fields
    try std.testing.expectEqualStrings("new", store.hget("k", "f").?);
}

test "HDEL" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "a", "1", "b", "2", "c", "3" });
    const removed = store.hdel("k", &[_][]const u8{ "a", "c", "nonexistent" });
    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expectEqual(@as(usize, 1), store.hlen("k"));
    try std.testing.expectEqualStrings("2", store.hget("k", "b").?);
}

test "HGETALL serializes complete RESP2 reply into buffer" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "x", "1", "y", "2" });
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try store.hgetallWrite("k", &out, false);

    try std.testing.expect(std.mem.startsWith(u8, out.items, "*4\r\n"));
    // Order is not guaranteed, just check both pairs exist as wire frames
    try std.testing.expect(std.mem.indexOf(u8, out.items, "$1\r\nx\r\n$1\r\n1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "$1\r\ny\r\n$1\r\n2\r\n") != null);
}

test "HGETALL RESP3 uses map header" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "x", "1" });
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try store.hgetallWrite("k", &out, true);
    try std.testing.expectEqualStrings("%1\r\n$1\r\nx\r\n$1\r\n1\r\n", out.items);
}

test "HGETALL missing key writes empty header" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try store.hgetallWrite("nope", &out, false);
    try std.testing.expectEqualStrings("*0\r\n", out.items);
    out.clearRetainingCapacity();
    try store.hgetallWrite("nope", &out, true);
    try std.testing.expectEqualStrings("%0\r\n", out.items);
}

test "HGETALL wire cache: repeated reads identical, mutation invalidates" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    // ≥16 fields so the wire-cache path engages.
    var field_bufs: [20][8]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const f = try std.fmt.bufPrint(&field_bufs[i], "f{d}", .{i});
        _ = try store.hset("k", &[_][]const u8{ f, "old" });
    }

    var first = std.array_list.Managed(u8).init(std.testing.allocator);
    defer first.deinit();
    try store.hgetallWrite("k", &first, false);

    // Second read must be byte-identical (served from cache).
    var second = std.array_list.Managed(u8).init(std.testing.allocator);
    defer second.deinit();
    try store.hgetallWrite("k", &second, false);
    try std.testing.expectEqualStrings(first.items, second.items);

    // RESP3 form is cached independently and uses the map header.
    var r3 = std.array_list.Managed(u8).init(std.testing.allocator);
    defer r3.deinit();
    try store.hgetallWrite("k", &r3, true);
    try std.testing.expect(std.mem.startsWith(u8, r3.items, "%20\r\n"));

    // Mutation invalidates: new value must appear, old must be gone.
    _ = try store.hset("k", &[_][]const u8{ "f0", "newvalue" });
    var third = std.array_list.Managed(u8).init(std.testing.allocator);
    defer third.deinit();
    try store.hgetallWrite("k", &third, false);
    try std.testing.expect(std.mem.indexOf(u8, third.items, "$8\r\nnewvalue\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, third.items, "$2\r\nf0\r\n$3\r\nold\r\n") == null);

    // HDEL also invalidates and the count drops.
    _ = store.hdel("k", &[_][]const u8{"f1"});
    var fourth = std.array_list.Managed(u8).init(std.testing.allocator);
    defer fourth.deinit();
    try store.hgetallWrite("k", &fourth, false);
    try std.testing.expect(std.mem.startsWith(u8, fourth.items, "*38\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, fourth.items, "$2\r\nf1\r\n") == null);
}

test "HGETALL small hash below cache threshold stays correct" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "a", "1", "b", "2" });
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try store.hgetallWrite("k", &out, false);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "*4\r\n"));
    _ = try store.hset("k", &[_][]const u8{ "a", "9" });
    out.clearRetainingCapacity();
    try store.hgetallWrite("k", &out, false);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "$1\r\na\r\n$1\r\n9\r\n") != null);
}

test "HGETALL large values are never truncated" {
    // Regression: the old fast path budgeted 64 bytes per element and
    // silently broke out of the serialization loop when the budget ran
    // out, emitting a reply with fewer elements than the header claimed.
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    const big: [300]u8 = @splat('v'); // 300 bytes/value blows the old 64-byte budget
    var field_bufs: [40][8]u8 = undefined;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const f = try std.fmt.bufPrint(&field_bufs[i], "f{d}", .{i});
        _ = try store.hset("k", &[_][]const u8{ f, &big });
    }

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try store.hgetallWrite("k", &out, false);

    try std.testing.expect(std.mem.startsWith(u8, out.items, "*80\r\n"));
    // Every element frame present: 80 bulk-string '$' markers.
    var dollars: usize = 0;
    for (out.items) |ch| {
        if (ch == '$') dollars += 1;
    }
    try std.testing.expectEqual(@as(usize, 80), dollars);
    // 40 values of 300 bytes each must be fully present.
    try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, out.items, "$300\r\n"));
}

test "HLEN and HEXISTS" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.hlen("k"));
    _ = try store.hset("k", &[_][]const u8{ "a", "1" });
    try std.testing.expectEqual(@as(usize, 1), store.hlen("k"));
    try std.testing.expect(store.hexists("k", "a"));
    try std.testing.expect(!store.hexists("k", "b"));
}

test "HKEYS and HVALS" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    _ = try store.hset("k", &[_][]const u8{ "name", "Bob", "age", "25" });

    var keys_list: std.ArrayList(u8) = .empty;
    var kw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &keys_list);
    defer kw.deinit();
    try store.hkeysWriteIo("k", &kw.writer);
    try std.testing.expect(std.mem.startsWith(u8, kw.written(), "*2\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, kw.written(), "$4\r\nname\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, kw.written(), "$3\r\nage\r\n") != null);

    var vals_list: std.ArrayList(u8) = .empty;
    var vw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &vals_list);
    defer vw.deinit();
    try store.hvalsWriteIo("k", &vw.writer);
    try std.testing.expect(std.mem.startsWith(u8, vw.written(), "*2\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, vw.written(), "$3\r\nBob\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, vw.written(), "$2\r\n25\r\n") != null);
}

test "HINCRBY" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    // New field defaults to 0
    const v1 = try store.hincrby("k", "counter", 5);
    try std.testing.expectEqual(@as(i64, 5), v1);

    const v2 = try store.hincrby("k", "counter", -3);
    try std.testing.expectEqual(@as(i64, 2), v2);

    try std.testing.expectEqualStrings("2", store.hget("k", "counter").?);
}

test "empty after HDEL auto-deletes" {
    var store = HashStore.init(std.testing.allocator); store.initStripes();
    defer store.deinit();

    _ = try store.hset("tmp", &[_][]const u8{ "f", "v" });
    _ = store.hdel("tmp", &[_][]const u8{"f"});
    try std.testing.expect(!store.exists("tmp"));
}
