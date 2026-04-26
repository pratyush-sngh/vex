const std = @import("std");
const Allocator = std.mem.Allocator;

/// List storage: maps key -> doubly-ended list of string values.
/// Uses two-stack deque: head (reversed) + tail. O(1) amortized LPUSH/LPOP/RPUSH/RPOP.
pub const ListStore = struct {
    lists: std.StringHashMap(List),
    allocator: Allocator,

    /// Flat-buffer list. Values stored contiguously as [len:u16][data...] entries.
    /// No per-value heap allocation. RPUSH/LPOP are memcpy/pointer-advance.
    /// Uses a ring buffer with head/tail offsets for O(1) push/pop at both ends.
    const List = struct {
        /// Entries stored as: [len:u16][value bytes][len:u16][value bytes]...
        /// Index stores the byte offset of each entry's length prefix.
        index: std.array_list.Managed(u32), // byte offset of each entry in buf
        buf: std.array_list.Managed(u8), // flat value storage
        head_idx: usize, // logical first element in index
        count: usize,

        fn init(allocator: Allocator) List {
            return .{
                .index = std.array_list.Managed(u32).init(allocator),
                .buf = std.array_list.Managed(u8).init(allocator),
                .head_idx = 0,
                .count = 0,
            };
        }

        fn deinit(self: *List, _: Allocator) void {
            self.index.deinit();
            self.buf.deinit();
        }

        fn len(self: *const List) usize {
            return self.count;
        }

        /// Get the value at a logical index (0 = first element).
        fn get(self: *const List, logical_idx: usize) ?[]const u8 {
            if (logical_idx >= self.count) return null;
            const actual = self.head_idx + logical_idx;
            if (actual >= self.index.items.len) return null;
            const off = self.index.items[actual];
            return self.entryAt(off);
        }

        /// Append value to the tail. O(1) amortized.
        fn pushTail(self: *List, value: []const u8) !void {
            const off: u32 = @intCast(self.buf.items.len);
            // Write [len:u16][value]
            const vlen: u16 = @intCast(@min(value.len, 65535));
            try self.buf.appendSlice(std.mem.asBytes(&vlen));
            try self.buf.appendSlice(value);
            try self.index.append(off);
            self.count += 1;
        }

        /// Prepend value to the head. Uses a reserved slot if available, else shifts.
        fn pushHead(self: *List, value: []const u8) !void {
            // Simple approach: append to buf (values are out of order in buf, index tracks order)
            const off: u32 = @intCast(self.buf.items.len);
            const vlen: u16 = @intCast(@min(value.len, 65535));
            try self.buf.appendSlice(std.mem.asBytes(&vlen));
            try self.buf.appendSlice(value);
            // Insert at head_idx position in index
            if (self.head_idx > 0) {
                self.head_idx -= 1;
                self.index.items[self.head_idx] = off;
            } else {
                try self.index.insert(0, off);
            }
            self.count += 1;
        }

        /// Pop from head. Returns a slice into buf (valid until next compact).
        fn popHead(self: *List) ?[]const u8 {
            if (self.count == 0) return null;
            const off = self.index.items[self.head_idx];
            const val = self.entryAt(off);
            self.head_idx += 1;
            self.count -= 1;
            return val;
        }

        /// Pop from tail. Returns a slice into buf.
        fn popTail(self: *List) ?[]const u8 {
            if (self.count == 0) return null;
            const tail_idx = self.head_idx + self.count - 1;
            const off = self.index.items[tail_idx];
            const val = self.entryAt(off);
            self.count -= 1;
            return val;
        }

        fn entryAt(self: *const List, off: u32) ?[]const u8 {
            const o: usize = off;
            if (o + 2 > self.buf.items.len) return null;
            const vlen = std.mem.bytesAsValue(u16, self.buf.items[o..][0..2]).*;
            const start = o + 2;
            if (start + vlen > self.buf.items.len) return null;
            return self.buf.items[start .. start + vlen];
        }

        /// Compact: remove consumed head entries to reclaim buf space.
        fn compact(self: *List) void {
            if (self.head_idx < 64) return; // not worth compacting yet
            // Shift index
            const remaining = self.index.items[self.head_idx .. self.head_idx + self.count];
            std.mem.copyForwards(u32, self.index.items[0..self.count], remaining);
            self.index.shrinkRetainingCapacity(self.count);
            self.head_idx = 0;
            // Note: buf doesn't compact (values are referenced by offset).
            // Full compact would require rewriting buf + updating all offsets.
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

    /// Clear all data but retain HashMap capacity for reuse.
    pub fn flush(self: *ListStore) void {
        var it = self.lists.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr.*;
            list.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.lists.clearRetainingCapacity();
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
        for (values) |val| try list.pushHead(val);
        return list.len();
    }

    /// LPUSH with pre-allocated owned values. Same as lpush for flat buffer (just copies data).
    pub fn lpushOwned(self: *ListStore, key: []const u8, owned: []const []u8) !usize {
        const list = try self.getOrCreate(key);
        for (owned) |val| try list.pushHead(val);
        return list.len();
    }

    /// RPUSH key value [value ...] — append values, returns new length.
    pub fn rpush(self: *ListStore, key: []const u8, values: []const []const u8) !usize {
        const list = try self.getOrCreate(key);
        for (values) |val| try list.pushTail(val);
        return list.len();
    }

    /// RPUSH with pre-allocated owned values. Same as rpush for flat buffer.
    pub fn rpushOwned(self: *ListStore, key: []const u8, owned: []const []u8) !usize {
        const list = try self.getOrCreate(key);
        for (owned) |val| try list.pushTail(val);
        return list.len();
    }

    /// LPOP key — remove and return the first element. Returns slice into internal buffer.
    /// Caller must NOT free the returned slice (it's not heap-allocated).
    pub fn lpop(self: *ListStore, key: []const u8) ?[]const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        const val = list.popHead() orelse return null;
        if (list.len() == 0) self.removeKey(key);
        return val;
    }

    /// RPOP key — remove and return the last element.
    pub fn rpop(self: *ListStore, key: []const u8) ?[]const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        const val = list.popTail() orelse return null;
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

    /// LSET key index value — rebuild list with updated element.
    pub fn lset(self: *ListStore, key: []const u8, index: i64, value: []const u8) !void {
        const list = self.lists.getPtr(key) orelse return error.NoSuchKey;
        const total: i64 = @intCast(list.len());
        var idx = index;
        if (idx < 0) idx += total;
        if (idx < 0 or idx >= total) return error.IndexOutOfRange;
        // Rebuild: collect all elements, replace target, rebuild flat buffer
        const ui: usize = @intCast(idx);
        var new_list = List.init(self.allocator);
        var i: usize = 0;
        while (i < list.count) : (i += 1) {
            const v = list.get(i) orelse continue;
            if (i == ui) {
                try new_list.pushTail(value);
            } else {
                try new_list.pushTail(v);
            }
        }
        list.buf.deinit();
        list.index.deinit();
        list.* = new_list;
    }

    /// LREM key count value — rebuild list without matching elements.
    pub fn lrem(self: *ListStore, key: []const u8, count_in: i64, value: []const u8) usize {
        const list = self.lists.getPtr(key) orelse return 0;
        const total = list.len();
        if (total == 0) return 0;

        var removed: usize = 0;
        const max_remove: usize = if (count_in == 0) total else @intCast(if (count_in < 0) -count_in else count_in);

        // Collect all values, skip matches
        var new_list = List.init(self.allocator);
        if (count_in >= 0) {
            var i: usize = 0;
            while (i < total) : (i += 1) {
                const v = list.get(i) orelse continue;
                if (removed < max_remove and std.mem.eql(u8, v, value)) {
                    removed += 1;
                } else {
                    new_list.pushTail(v) catch {};
                }
            }
        } else {
            // Remove from tail: collect all, then remove from end
            var items = std.array_list.Managed([]const u8).init(self.allocator);
            defer items.deinit();
            var i: usize = 0;
            while (i < total) : (i += 1) {
                if (list.get(i)) |v| items.append(v) catch {};
            }
            var j: usize = items.items.len;
            while (j > 0 and removed < max_remove) {
                j -= 1;
                if (std.mem.eql(u8, items.items[j], value)) {
                    _ = items.orderedRemove(j);
                    removed += 1;
                }
            }
            for (items.items) |v| new_list.pushTail(v) catch {};
        }

        list.buf.deinit();
        list.index.deinit();
        list.* = new_list;

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

    /// No-op for flat buffer lists. Values are slices into internal buffer, not heap-allocated.
    pub fn freeVal(_: Allocator, _: []const u8) void {}

    fn getOrCreate(self: *ListStore, key: []const u8) !*List {
        const gop = try self.lists.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            var list = List.init(self.allocator);
            // Pre-allocate index and buffer capacity
            list.index.ensureTotalCapacity(64) catch {};
            list.buf.ensureTotalCapacity(512) catch {};
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
