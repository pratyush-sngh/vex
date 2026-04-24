const std = @import("std");
const Allocator = std.mem.Allocator;

/// List storage: maps key -> doubly-ended list of string values.
/// Backed by ArrayList per key (O(1) RPUSH/RPOP, O(n) LPUSH/LPOP).
pub const ListStore = struct {
    lists: std.StringHashMap(List),
    allocator: Allocator,

    const List = struct {
        items: std.array_list.Managed([]u8),

        fn init(allocator: Allocator) List {
            return .{ .items = std.array_list.Managed([]u8).init(allocator) };
        }

        fn deinit(self: *List, allocator: Allocator) void {
            for (self.items.items) |v| allocator.free(v);
            self.items.deinit();
        }
    };

    pub fn init(allocator: Allocator) ListStore {
        return .{
            .lists = std.StringHashMap(List).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ListStore) void {
        var it = self.lists.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr.*;
            list.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.lists.deinit();
    }

    /// LPUSH key value [value ...] — prepend values, returns new length.
    pub fn lpush(self: *ListStore, key: []const u8, values: []const []const u8) !usize {
        const list = try self.getOrCreate(key);
        // Insert values at front (in order, so last arg ends up at head — Redis behavior)
        for (values) |val| {
            const copy = try self.allocator.dupe(u8, val);
            errdefer self.allocator.free(copy);
            try list.items.insert(0, copy);
        }
        return list.items.items.len;
    }

    /// RPUSH key value [value ...] — append values, returns new length.
    pub fn rpush(self: *ListStore, key: []const u8, values: []const []const u8) !usize {
        const list = try self.getOrCreate(key);
        for (values) |val| {
            const copy = try self.allocator.dupe(u8, val);
            errdefer self.allocator.free(copy);
            try list.items.append(copy);
        }
        return list.items.items.len;
    }

    /// LPOP key — remove and return the first element.
    pub fn lpop(self: *ListStore, key: []const u8) ?[]u8 {
        const list = self.lists.getPtr(key) orelse return null;
        if (list.items.items.len == 0) return null;
        const val = list.items.orderedRemove(0);
        if (list.items.items.len == 0) self.removeKey(key);
        return val;
    }

    /// RPOP key — remove and return the last element.
    pub fn rpop(self: *ListStore, key: []const u8) ?[]u8 {
        const list = self.lists.getPtr(key) orelse return null;
        if (list.items.items.len == 0) return null;
        const val = list.items.pop();
        if (list.items.items.len == 0) self.removeKey(key);
        return val;
    }

    /// LLEN key — return list length.
    pub fn llen(self: *ListStore, key: []const u8) usize {
        const list = self.lists.getPtr(key) orelse return 0;
        return list.items.items.len;
    }

    /// LINDEX key index — return element at index (negative indexes from tail).
    pub fn lindex(self: *ListStore, key: []const u8, index: i64) ?[]const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        const len: i64 = @intCast(list.items.items.len);
        var idx = index;
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) return null;
        return list.items.items[@intCast(idx)];
    }

    /// LRANGE key start stop — return elements in range (inclusive, negative indexes supported).
    pub fn lrange(self: *ListStore, key: []const u8, start_in: i64, stop_in: i64) ?[]const []const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        const len: i64 = @intCast(list.items.items.len);
        if (len == 0) return &[_][]const u8{};

        var start = start_in;
        var stop = stop_in;
        if (start < 0) start += len;
        if (stop < 0) stop += len;
        if (start < 0) start = 0;
        if (stop >= len) stop = len - 1;
        if (start > stop) return &[_][]const u8{};

        const s: usize = @intCast(start);
        const e: usize = @intCast(stop + 1);
        // Return a slice of the underlying items — caller must not modify
        const items: []const []u8 = list.items.items[s..e];
        return @ptrCast(items);
    }

    /// LSET key index value — set element at index.
    pub fn lset(self: *ListStore, key: []const u8, index: i64, value: []const u8) !void {
        const list = self.lists.getPtr(key) orelse return error.NoSuchKey;
        const len: i64 = @intCast(list.items.items.len);
        var idx = index;
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) return error.IndexOutOfRange;
        const i: usize = @intCast(idx);
        const copy = try self.allocator.dupe(u8, value);
        self.allocator.free(list.items.items[i]);
        list.items.items[i] = copy;
    }

    /// LREM key count value — remove count occurrences of value.
    /// count > 0: remove from head, count < 0: remove from tail, count == 0: remove all.
    pub fn lrem(self: *ListStore, key: []const u8, count_in: i64, value: []const u8) usize {
        const list = self.lists.getPtr(key) orelse return 0;
        var removed: usize = 0;
        const max_remove: usize = if (count_in == 0) list.items.items.len else @intCast(if (count_in < 0) -count_in else count_in);

        if (count_in >= 0) {
            // Remove from head
            var i: usize = 0;
            while (i < list.items.items.len and removed < max_remove) {
                if (std.mem.eql(u8, list.items.items[i], value)) {
                    self.allocator.free(list.items.orderedRemove(i));
                    removed += 1;
                } else {
                    i += 1;
                }
            }
        } else {
            // Remove from tail
            var i: usize = list.items.items.len;
            while (i > 0 and removed < max_remove) {
                i -= 1;
                if (std.mem.eql(u8, list.items.items[i], value)) {
                    self.allocator.free(list.items.orderedRemove(i));
                    removed += 1;
                }
            }
        }
        if (list.items.items.len == 0) self.removeKey(key);
        return removed;
    }

    /// Check if a key exists as a list.
    pub fn exists(self: *ListStore, key: []const u8) bool {
        return self.lists.contains(key);
    }

    /// Delete a list key entirely.
    pub fn delete(self: *ListStore, key: []const u8) bool {
        var entry = self.lists.fetchRemove(key) orelse return false;
        entry.value.deinit(self.allocator);
        self.allocator.free(entry.key);
        return true;
    }

    fn getOrCreate(self: *ListStore, key: []const u8) !*List {
        const gop = try self.lists.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            gop.value_ptr.* = List.init(self.allocator);
        }
        return gop.value_ptr;
    }

    fn removeKey(self: *ListStore, key: []const u8) void {
        var entry = self.lists.fetchRemove(key) orelse return;
        entry.value.deinit(self.allocator);
        self.allocator.free(entry.key);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────

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
    defer std.testing.allocator.free(left);
    try std.testing.expectEqualStrings("1", left);

    const right = store.rpop("q").?;
    defer std.testing.allocator.free(right);
    try std.testing.expectEqualStrings("3", right);

    try std.testing.expectEqual(@as(usize, 1), store.llen("q"));
}

test "LRANGE" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("r", &[_][]const u8{ "a", "b", "c", "d", "e" });

    const range = store.lrange("r", 1, 3).?;
    try std.testing.expectEqual(@as(usize, 3), range.len);
    try std.testing.expectEqualStrings("b", range[0]);
    try std.testing.expectEqualStrings("d", range[2]);

    // Negative indexes
    const tail = store.lrange("r", -2, -1).?;
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

test "empty after pop auto-deletes" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("tmp", &[_][]const u8{"x"});
    const v = store.rpop("tmp").?;
    defer std.testing.allocator.free(v);
    try std.testing.expect(!store.exists("tmp"));
}
