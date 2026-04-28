const std = @import("std");
const Allocator = std.mem.Allocator;

/// List storage: maps key -> doubly-ended list of string values.
/// Uses two-stack deque: head (reversed) + tail. O(1) amortized LPUSH/LPOP/RPUSH/RPOP.
pub const ListStore = struct {
    lists: std.StringHashMap(List),
    allocator: Allocator,
    /// Mutex for top-level HashMap mutations (new key creation).
    map_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    /// Quicklist: doubly-linked list of 8KB data blocks.
    /// Each block stores values as packed [len:u16][data...][len:u16] entries.
    /// The trailing u16 enables O(1) RPOP (walk backwards from tail).
    /// Per-block offset ring buffer enables O(1) LINDEX/LRANGE within a block.
    /// New blocks start from the middle — room for both LPUSH and RPUSH.
    /// No per-value heap allocation. O(1) push/pop/index at both ends.
    const List = struct {
        const BLOCK_SIZE: usize = 8192; // 8KB per block (matches Redis default)
        const HEADER_SIZE: usize = 2; // u16 length prefix per entry
        const TRAILER_SIZE: usize = 2; // u16 length suffix for O(1) backward scan
        const ENTRY_OVERHEAD: usize = HEADER_SIZE + TRAILER_SIZE; // 4 bytes per entry
        const MAX_ENTRIES: usize = 512; // max entries per block; forces new block if exceeded

        const Block = struct {
            data: [BLOCK_SIZE]u8,
            head: usize,
            tail: usize,
            entry_count: usize,
            prev: ?*Block,
            next: ?*Block,
            off_ring: [MAX_ENTRIES]u16,
            off_start: u16,
            ring_dirty: bool, // true = ring needs rebuild before LINDEX/LRANGE
        };

        first: ?*Block,
        last: ?*Block,
        total_count: usize,
        allocator: Allocator,

        fn init(allocator: Allocator) List {
            return .{ .first = null, .last = null, .total_count = 0, .allocator = allocator };
        }

        fn deinit(self: *List, _: Allocator) void {
            var cur = self.first;
            while (cur) |block| {
                const next = block.next;
                self.allocator.destroy(block);
                cur = next;
            }
            self.first = null;
            self.last = null;
            self.total_count = 0;
        }

        fn len(self: *const List) usize {
            return self.total_count;
        }

        fn newBlock(self: *List) !*Block {
            const block = try self.allocator.create(Block);
            block.* = .{
                .data = undefined,
                .head = BLOCK_SIZE / 2, // start from middle
                .tail = BLOCK_SIZE / 2,
                .entry_count = 0,
                .prev = null,
                .next = null,
                .off_ring = undefined,
                .off_start = 0,
                .ring_dirty = false,
            };
            return block;
        }

        /// RPUSH: append to tail of last block. If full or max entries, allocate new block.
        fn pushTail(self: *List, value: []const u8) !void {
            const needed = ENTRY_OVERHEAD + value.len;
            if (needed > BLOCK_SIZE) return error.ValueTooLarge;

            var block = self.last orelse blk: {
                const b = try self.newBlock();
                self.first = b;
                self.last = b;
                break :blk b;
            };

            // Check if room at tail of last block (space + entry limit)
            if (block.tail + needed > BLOCK_SIZE or block.entry_count >= MAX_ENTRIES) {
                const new = try self.newBlock();
                new.head = 0; // new tail block starts from beginning
                new.tail = 0;
                new.prev = block;
                block.next = new;
                self.last = new;
                block = new;
            }

            // Record offset in ring buffer (append at end)
            const ring_idx = (block.off_start +% @as(u16, @intCast(block.entry_count))) % MAX_ENTRIES;
            block.off_ring[ring_idx] = @intCast(block.tail);

            // Write [len:u16][value][len:u16] at tail
            const vlen: u16 = @intCast(value.len);
            @memcpy(block.data[block.tail..][0..2], std.mem.asBytes(&vlen));
            @memcpy(block.data[block.tail + HEADER_SIZE ..][0..value.len], value);
            @memcpy(block.data[block.tail + HEADER_SIZE + value.len ..][0..2], std.mem.asBytes(&vlen));
            block.tail += needed;
            block.entry_count += 1;
            self.total_count += 1;
        }

        /// LPUSH: prepend to head of first block. If full or max entries, allocate new block.
        fn pushHead(self: *List, value: []const u8) !void {
            const needed = ENTRY_OVERHEAD + value.len;
            if (needed > BLOCK_SIZE) return error.ValueTooLarge;

            var block = self.first orelse blk: {
                const b = try self.newBlock();
                self.first = b;
                self.last = b;
                break :blk b;
            };

            // Check if room at head of first block (space + entry limit)
            if (block.head < needed or block.entry_count >= MAX_ENTRIES) {
                const new = try self.newBlock();
                new.head = BLOCK_SIZE; // new head block starts from end
                new.tail = BLOCK_SIZE;
                new.next = block;
                block.prev = new;
                self.first = new;
                block = new;
            }

            // Write [len:u16][value][len:u16] growing leftward from head
            block.head -= needed;
            const vlen: u16 = @intCast(value.len);
            @memcpy(block.data[block.head..][0..2], std.mem.asBytes(&vlen));
            @memcpy(block.data[block.head + HEADER_SIZE ..][0..value.len], value);
            @memcpy(block.data[block.head + HEADER_SIZE + value.len ..][0..2], std.mem.asBytes(&vlen));

            // Prepend offset in ring buffer (decrement off_start)
            block.off_start = (block.off_start +% @as(u16, MAX_ENTRIES) -% 1) % @as(u16, MAX_ENTRIES);
            block.off_ring[block.off_start] = @intCast(block.head);
            block.entry_count += 1;
            self.total_count += 1;
        }

        /// LPOP: remove from head of first block.
        fn popHead(self: *List) ?[]const u8 {
            const block = self.first orelse return null;
            if (block.head >= block.tail) {
                // Block empty — remove it
                self.removeBlock(block);
                // Try next block
                const next = self.first orelse return null;
                return self.popHeadFromBlock(next);
            }
            return self.popHeadFromBlock(block);
        }

        fn popHeadFromBlock(self: *List, block: *Block) ?[]const u8 {
            if (block.head >= block.tail) return null;
            const vlen = std.mem.bytesAsValue(u16, block.data[block.head..][0..2]).*;
            const val = block.data[block.head + HEADER_SIZE ..][0 .. vlen];
            block.head += ENTRY_OVERHEAD + vlen;
            block.ring_dirty = true;
            block.entry_count -= 1;
            self.total_count -= 1;
            return val;
        }

        /// RPOP: remove from tail of last block.
        fn popTail(self: *List) ?[]const u8 {
            const block = self.last orelse return null;
            if (block.head >= block.tail) {
                self.removeBlock(block);
                const prev = self.last orelse return null;
                return self.popTailFromBlock(prev);
            }
            return self.popTailFromBlock(block);
        }

        fn popTailFromBlock(self: *List, block: *Block) ?[]const u8 {
            if (block.head >= block.tail) return null;
            const vlen = std.mem.bytesAsValue(u16, block.data[block.tail - TRAILER_SIZE ..][0..2]).*;
            block.tail -= ENTRY_OVERHEAD + vlen;
            const val = block.data[block.tail + HEADER_SIZE ..][0..vlen];
            block.ring_dirty = true;
            block.entry_count -= 1;
            self.total_count -= 1;
            return val;
        }

        /// Get element at logical index. O(blocks) to find block, O(1) within block via offset ring.
        fn get(self: *const List, logical_idx: usize) ?[]const u8 {
            if (logical_idx >= self.total_count) return null;
            var remaining = logical_idx;
            var cur = self.first;
            while (cur) |block| {
                if (remaining < block.entry_count) {
                    if (block.ring_dirty) rebuildRing(block);
                    const ring_idx = (block.off_start +% @as(u16, @intCast(remaining))) % MAX_ENTRIES;
                    const pos = block.off_ring[ring_idx];
                    const vlen = std.mem.bytesAsValue(u16, block.data[pos..][0..2]).*;
                    return block.data[pos + HEADER_SIZE ..][0..vlen];
                }
                remaining -= block.entry_count;
                cur = block.next;
            }
            return null;
        }

        fn rebuildRing(block: *Block) void {
            var pos = block.head;
            var i: usize = 0;
            while (pos < block.tail and i < MAX_ENTRIES) {
                block.off_ring[i] = @intCast(pos);
                const vlen = std.mem.bytesAsValue(u16, block.data[pos..][0..2]).*;
                pos += ENTRY_OVERHEAD + vlen;
                i += 1;
            }
            block.off_start = 0;
            block.ring_dirty = false;
        }

        fn removeBlock(self: *List, block: *Block) void {
            if (block.prev) |p| p.next = block.next else self.first = block.next;
            if (block.next) |n| n.prev = block.prev else self.last = block.prev;
            self.allocator.destroy(block);
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
        self.flush();
        self.lists.deinit();
    }


    /// LPUSH key value [value ...] — prepend values, returns new length.
    pub fn lpush(self: *ListStore, key: []const u8, values: []const []const u8) !usize {
        const list = try self.getOrCreate(key);
        for (values) |val| try list.pushHead(val);
        return list.len();
    }

/// RPUSH key value [value ...] — append values, returns new length.
    pub fn rpush(self: *ListStore, key: []const u8, values: []const []const u8) !usize {
        const list = try self.getOrCreate(key);
        for (values) |val| try list.pushTail(val);
        return list.len();
    }

/// LPOP key — remove and return the first element. Returns slice into internal buffer.
    /// Caller must NOT free the returned slice (it's not heap-allocated).
    /// Note: empty lists are NOT auto-deleted — the returned slice points into block memory
    /// that would be freed by removeKey. Cleanup happens on next push/pop or DEL/FLUSHALL.
    pub fn lpop(self: *ListStore, key: []const u8) ?[]const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        return list.popHead();
    }

    /// RPOP key — remove and return the last element.
    /// Note: see lpop comment about deferred cleanup.
    pub fn rpop(self: *ListStore, key: []const u8) ?[]const u8 {
        const list = self.lists.getPtr(key) orelse return null;
        return list.popTail();
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
        while (i < list.total_count) : (i += 1) {
            const v = list.get(i) orelse continue;
            if (i == ui) {
                try new_list.pushTail(value);
            } else {
                try new_list.pushTail(v);
            }
        }
        list.deinit(self.allocator);
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

        list.deinit(self.allocator);
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

    /// No-op. Quicklist values are slices into block memory, not heap-allocated.
    pub fn freeVal(_: Allocator, _: []const u8) void {}

    fn getOrCreate(self: *ListStore, key: []const u8) !*List {
        // Fast path: key exists — no mutex needed
        if (self.lists.getPtr(key)) |existing| return existing;
        // Slow path: new key — mutex protects HashMap mutation
        _ = std.c.pthread_mutex_lock(&self.map_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.map_mutex);
        // Double-check after acquiring mutex (another thread may have created it)
        if (self.lists.getPtr(key)) |existing| return existing;
        const gop = try self.lists.getOrPut(key);
        gop.key_ptr.* = try self.allocator.dupe(u8, key);
        gop.value_ptr.* = List.init(self.allocator);
        return gop.value_ptr;
    }

    fn removeKey(self: *ListStore, key: []const u8) void {
        _ = std.c.pthread_mutex_lock(&self.map_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.map_mutex);
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
