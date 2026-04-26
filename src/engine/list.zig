const std = @import("std");
const Allocator = std.mem.Allocator;

/// List storage: maps key -> doubly-ended list of string values.
/// Uses two-stack deque: head (reversed) + tail. O(1) amortized LPUSH/LPOP/RPUSH/RPOP.
pub const ListStore = struct {
    lists: std.StringHashMap(List),
    allocator: Allocator,

    const List = struct {
        head: std.array_list.Managed([]u8), // reversed: head.pop() gives first element
        tail: std.array_list.Managed([]u8), // tail.pop() gives last element

        fn init(allocator: Allocator) List {
            return .{
                .head = std.array_list.Managed([]u8).init(allocator),
                .tail = std.array_list.Managed([]u8).init(allocator),
            };
        }

        fn deinit(self: *List, allocator: Allocator) void {
            for (self.head.items) |v| allocator.free(v);
            self.head.deinit();
            for (self.tail.items) |v| allocator.free(v);
            self.tail.deinit();
        }

        fn len(self: *const List) usize {
            return self.head.items.len + self.tail.items.len;
        }

        /// Get element at logical index (0 = first).
        fn get(self: *const List, index: usize) ?[]const u8 {
            const hlen = self.head.items.len;
            if (index < hlen) {
                return self.head.items[hlen - 1 - index];
            }
            const ti = index - hlen;
            if (ti < self.tail.items.len) {
                return self.tail.items[ti];
            }
            return null;
        }

        /// Rebalance: move half of tail to head (when head is empty and we need lpop).
        fn rebalanceToHead(self: *List) void {
            // Reverse tail into head
            const tlen = self.tail.items.len;
            if (tlen == 0) return;
            const half = tlen; // move all to head
            var i: usize = 0;
            while (i < half) : (i += 1) {
                const idx = tlen - 1 - i;
                self.head.append(self.tail.items[idx]) catch return;
            }
            // Remove moved items from tail
            self.tail.shrinkRetainingCapacity(tlen - half);
        }

        /// Rebalance: move half of head to tail (when tail is empty and we need rpop).
        fn rebalanceToTail(self: *List) void {
            const hlen = self.head.items.len;
            if (hlen == 0) return;
            const half = hlen;
            var i: usize = 0;
            while (i < half) : (i += 1) {
                const idx = hlen - 1 - i;
                self.tail.append(self.head.items[idx]) catch return;
            }
            self.head.shrinkRetainingCapacity(hlen - half);
        }
    };

    pub fn init(allocator: Allocator) ListStore {
        var store = ListStore{
            .lists = std.StringHashMap(List).init(allocator),
            .allocator = allocator,
        };
        store.lists.ensureTotalCapacity(4096) catch {};
        return store;
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


    /// LPUSH key value [value ...] — prepend values (O(1) each), returns new length.
    pub fn lpush(self: *ListStore, key: []const u8, values: []const []const u8) !usize {
        const list = try self.getOrCreate(key);
        for (values) |val| {
            const copy = try self.allocator.dupe(u8, val);
            errdefer self.allocator.free(copy);
            try list.head.append(copy);
        }
        return list.len();
    }

    /// LPUSH with pre-allocated owned values. Caller allocated, list takes ownership.
    /// No allocation under lock — only the ArrayList append (~20ns).
    pub fn lpushOwned(self: *ListStore, key: []const u8, owned: []const []u8) !usize {
        const list = try self.getOrCreate(key);
        for (owned) |val| try list.head.append(val);
        return list.len();
    }

    /// RPUSH key value [value ...] — append values (O(1) each), returns new length.
    pub fn rpush(self: *ListStore, key: []const u8, values: []const []const u8) !usize {
        const list = try self.getOrCreate(key);
        for (values) |val| {
            const copy = try self.allocator.dupe(u8, val);
            errdefer self.allocator.free(copy);
            try list.tail.append(copy);
        }
        return list.len();
    }

    /// RPUSH with pre-allocated owned values. No allocation under lock.
    pub fn rpushOwned(self: *ListStore, key: []const u8, owned: []const []u8) !usize {
        const list = try self.getOrCreate(key);
        for (owned) |val| try list.tail.append(val);
        return list.len();
    }

    /// LPOP key — remove and return the first element (O(1) amortized).
    pub fn lpop(self: *ListStore, key: []const u8) ?[]u8 {
        const list = self.lists.getPtr(key) orelse return null;
        if (list.len() == 0) return null;
        if (list.head.items.len == 0) list.rebalanceToHead();
        if (list.head.items.len == 0) return null;
        const val = list.head.pop();
        if (list.len() == 0) self.removeKey(key);
        return val;
    }

    /// RPOP key — remove and return the last element (O(1) amortized).
    pub fn rpop(self: *ListStore, key: []const u8) ?[]u8 {
        const list = self.lists.getPtr(key) orelse return null;
        if (list.len() == 0) return null;
        if (list.tail.items.len == 0) list.rebalanceToTail();
        if (list.tail.items.len == 0) return null;
        const val = list.tail.pop();
        if (list.len() == 0) self.removeKey(key);
        return val;
    }

    /// LLEN key — return list length.
    pub fn llen(self: *ListStore, key: []const u8) usize {
        const list = self.lists.getPtr(key) orelse return 0;
        return list.len();
    }

    /// LINDEX key index — return element at index (negative indexes from tail).
    pub fn lindex(self: *ListStore, key: []const u8, index: i64) ?[]const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        const total: i64 = @intCast(list.len());
        var idx = index;
        if (idx < 0) idx += total;
        if (idx < 0 or idx >= total) return null;
        return list.get(@intCast(idx));
    }

    /// LRANGE key start stop — return elements in range (inclusive, negative indexes supported).
    pub fn lrange(self: *ListStore, key: []const u8, start_in: i64, stop_in: i64) ?[]const []const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        const total: i64 = @intCast(list.len());
        if (total == 0) return &[_][]const u8{};

        var start = start_in;
        var stop = stop_in;
        if (start < 0) start += total;
        if (stop < 0) stop += total;
        if (start < 0) start = 0;
        if (stop >= total) stop = total - 1;
        if (start > stop) return &[_][]const u8{};

        // Build result by indexing through the deque
        const count: usize = @intCast(stop - start + 1);
        const result = self.allocator.alloc([]const u8, count) catch return null;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            result[i] = list.get(@as(usize, @intCast(start)) + i) orelse "";
        }
        return result;
    }

    /// LSET key index value — set element at index.
    pub fn lset(self: *ListStore, key: []const u8, index: i64, value: []const u8) !void {
        const list = self.lists.getPtr(key) orelse return error.NoSuchKey;
        const total: i64 = @intCast(list.len());
        var idx = index;
        if (idx < 0) idx += total;
        if (idx < 0 or idx >= total) return error.IndexOutOfRange;
        const ui: usize = @intCast(idx);
        const hlen = list.head.items.len;
        const copy = try self.allocator.dupe(u8, value);
        if (ui < hlen) {
            self.allocator.free(list.head.items[hlen - 1 - ui]);
            list.head.items[hlen - 1 - ui] = copy;
        } else {
            const ti = ui - hlen;
            self.allocator.free(list.tail.items[ti]);
            list.tail.items[ti] = copy;
        }
    }

    /// LREM key count value — remove count occurrences of value.
    /// For the deque, we linearize, remove, then rebuild. O(n) but correct.
    pub fn lrem(self: *ListStore, key: []const u8, count_in: i64, value: []const u8) usize {
        const list = self.lists.getPtr(key) orelse return 0;
        const total = list.len();
        if (total == 0) return 0;

        // Linearize into a temporary buffer
        var linear = std.array_list.Managed([]u8).init(self.allocator);
        defer linear.deinit();
        // Head is reversed
        var hi: usize = list.head.items.len;
        while (hi > 0) : (hi -= 1) {
            linear.append(list.head.items[hi - 1]) catch return 0;
        }
        for (list.tail.items) |item| {
            linear.append(item) catch return 0;
        }

        var removed: usize = 0;
        const max_remove: usize = if (count_in == 0) total else @intCast(if (count_in < 0) -count_in else count_in);

        if (count_in >= 0) {
            var i: usize = 0;
            while (i < linear.items.len and removed < max_remove) {
                if (std.mem.eql(u8, linear.items[i], value)) {
                    self.allocator.free(linear.orderedRemove(i));
                    removed += 1;
                } else {
                    i += 1;
                }
            }
        } else {
            var i: usize = linear.items.len;
            while (i > 0 and removed < max_remove) {
                i -= 1;
                if (std.mem.eql(u8, linear.items[i], value)) {
                    self.allocator.free(linear.orderedRemove(i));
                    removed += 1;
                }
            }
        }

        // Rebuild deque from linear
        list.head.clearRetainingCapacity();
        list.tail.clearRetainingCapacity();
        for (linear.items) |item| {
            list.tail.append(item) catch {};
        }
        // Clear linear without freeing items (they're now in tail)
        linear.clearRetainingCapacity();

        if (list.len() == 0) self.removeKey(key);
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

    pub fn freeVal(allocator: Allocator, v: []u8) void {
        allocator.free(v);
    }

    fn getOrCreate(self: *ListStore, key: []const u8) !*List {
        const gop = try self.lists.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            var list = List.init(self.allocator);
            // Pre-allocate 64 slots per side to avoid realloc under write lock
            list.head.ensureTotalCapacity(64) catch {};
            list.tail.ensureTotalCapacity(64) catch {};
            gop.value_ptr.* = list;
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

test "empty after pop auto-deletes" {
    var store = ListStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.rpush("tmp", &[_][]const u8{"x"});
    const v = store.rpop("tmp").?;
    defer ListStore.freeVal(std.testing.allocator, v);
    try std.testing.expect(!store.exists("tmp"));
}
