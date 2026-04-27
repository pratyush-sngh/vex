const std = @import("std");
const Allocator = std.mem.Allocator;
const KVStore = @import("kv.zig").KVStore;

/// Lock-free open-addressing hash table for ConcurrentKV.
/// Uses atomic CAS on entry pointers for lock-free insert.
/// Linear probing with pre-allocated capacity (no resize).
/// GET: atomic load → probe → key compare (~20ns)
/// SET existing: atomic load → SeqLock write (already lock-free)
/// SET new key: atomic CAS on empty slot (~10ns)
pub const LockFreeMap = struct {
    slots: []std.atomic.Value(usize), // 0 = empty, else = @intFromPtr(*Entry)
    keys: [][]const u8, // key storage per slot (written once on insert, never moved)
    capacity: usize,
    count: std.atomic.Value(u32),
    allocator: Allocator,

    pub const Entry = KVStore.Entry;

    /// Tombstone marker — slot was deleted, can be skipped during probe but not reused for insert
    /// (reuse requires careful ordering). Use high bit of pointer.
    const EMPTY: usize = 0;
    const TOMBSTONE: usize = 1;

    pub fn init(allocator: Allocator, capacity: usize) !LockFreeMap {
        const slots = try allocator.alloc(std.atomic.Value(usize), capacity);
        for (slots) |*s| s.* = std.atomic.Value(usize).init(EMPTY);
        const keys = try allocator.alloc([]const u8, capacity);
        for (keys) |*k| k.* = &[_]u8{};
        return .{
            .slots = slots,
            .keys = keys,
            .capacity = capacity,
            .count = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LockFreeMap) void {
        for (self.slots, 0..) |*s, i| {
            const ptr = s.load(.monotonic);
            if (ptr > TOMBSTONE) {
                const entry: *Entry = @ptrFromInt(ptr);
                // Free heap value if not inline
                if (!entry.flags.is_inline and entry.value.len > 0) {
                    self.allocator.free(entry.value);
                }
                self.allocator.destroy(entry);
            }
            if (self.keys[i].len > 0) {
                self.allocator.free(self.keys[i]);
            }
        }
        self.allocator.free(self.slots);
        self.allocator.free(self.keys);
    }

    fn hash(key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    /// Lock-free GET. Returns pointer to Entry (caller must NOT free).
    pub fn getPtr(self: *LockFreeMap, key: []const u8) ?*Entry {
        const h = hash(key);
        var idx = h % self.capacity;
        var probes: usize = 0;
        while (probes < self.capacity) : (probes += 1) {
            const ptr = self.slots[idx].load(.acquire);
            if (ptr == EMPTY) return null; // empty slot = key doesn't exist
            if (ptr != TOMBSTONE) {
                // Compare key
                if (self.keys[idx].len == key.len and std.mem.eql(u8, self.keys[idx], key)) {
                    return @ptrFromInt(ptr);
                }
            }
            idx = (idx + 1) % self.capacity;
        }
        return null; // table full, key not found
    }

    /// Lock-free insert or update. Returns the Entry pointer (new or existing).
    /// For new keys: allocates Entry + key via CAS on empty slot.
    /// For existing keys: returns existing Entry (caller updates via SeqLock).
    pub fn getOrPut(self: *LockFreeMap, key: []const u8) !struct { entry: *Entry, found: bool } {
        const h = hash(key);
        var idx = h % self.capacity;
        var probes: usize = 0;
        while (probes < self.capacity) : (probes += 1) {
            const ptr = self.slots[idx].load(.acquire);
            if (ptr == EMPTY) {
                // Empty slot — try to insert via CAS
                const entry = try self.allocator.create(Entry);
                entry.* = .{
                    .value = &[_]u8{},
                };
                const new_ptr = @intFromPtr(entry);

                if (self.slots[idx].cmpxchgStrong(EMPTY, new_ptr, .acq_rel, .acquire)) |_| {
                    // CAS failed — someone else inserted here. Free our entry, retry.
                    self.allocator.destroy(entry);
                    // Check if the winner inserted OUR key
                    const winner_ptr = self.slots[idx].load(.acquire);
                    if (winner_ptr > TOMBSTONE and
                        self.keys[idx].len == key.len and
                        std.mem.eql(u8, self.keys[idx], key))
                    {
                        return .{ .entry = @ptrFromInt(winner_ptr), .found = true };
                    }
                    // Different key won this slot — continue probing
                    idx = (idx + 1) % self.capacity;
                    probes += 1;
                    continue;
                }

                // CAS succeeded — we own this slot. Write the key.
                self.keys[idx] = try self.allocator.dupe(u8, key);
                _ = self.count.fetchAdd(1, .monotonic);
                return .{ .entry = entry, .found = false };
            }

            if (ptr == TOMBSTONE) {
                // Skip tombstones during probe (don't insert here to maintain probe chains)
                idx = (idx + 1) % self.capacity;
                continue;
            }

            // Occupied slot — check if it's our key
            if (self.keys[idx].len == key.len and std.mem.eql(u8, self.keys[idx], key)) {
                return .{ .entry = @ptrFromInt(ptr), .found = true };
            }

            idx = (idx + 1) % self.capacity;
        }
        return error.TableFull;
    }

    /// Lock-free delete. Returns true if key was found and deleted.
    pub fn remove(self: *LockFreeMap, key: []const u8) ?*Entry {
        const h = hash(key);
        var idx = h % self.capacity;
        var probes: usize = 0;
        while (probes < self.capacity) : (probes += 1) {
            const ptr = self.slots[idx].load(.acquire);
            if (ptr == EMPTY) return null;
            if (ptr != TOMBSTONE and
                self.keys[idx].len == key.len and
                std.mem.eql(u8, self.keys[idx], key))
            {
                // Found — CAS to tombstone
                if (self.slots[idx].cmpxchgStrong(ptr, TOMBSTONE, .acq_rel, .acquire)) |_| {
                    return null; // someone else deleted it
                }
                _ = self.count.fetchSub(1, .monotonic);
                return @ptrFromInt(ptr);
            }
            idx = (idx + 1) % self.capacity;
        }
        return null;
    }

    pub fn getCount(self: *LockFreeMap) u32 {
        return self.count.load(.monotonic);
    }

    /// Iterate over all live entries. NOT thread-safe for mutations during iteration.
    pub fn iterator(self: *LockFreeMap) Iterator {
        return .{ .map = self, .idx = 0 };
    }

    pub const IterEntry = struct {
        key: []const u8,
        entry: *Entry,
    };

    pub const Iterator = struct {
        map: *LockFreeMap,
        idx: usize,

        pub fn next(self: *Iterator) ?IterEntry {
            while (self.idx < self.map.capacity) {
                const i = self.idx;
                self.idx += 1;
                const ptr = self.map.slots[i].load(.acquire);
                if (ptr > TOMBSTONE) {
                    return .{ .key = self.map.keys[i], .entry = @ptrFromInt(ptr) };
                }
            }
            return null;
        }
    };

    /// Clear all entries. NOT thread-safe — call only during FLUSHDB.
    pub fn clear(self: *LockFreeMap) void {
        for (self.slots, 0..) |*s, i| {
            const ptr = s.load(.monotonic);
            if (ptr > TOMBSTONE) {
                const entry: *Entry = @ptrFromInt(ptr);
                if (!entry.flags.is_inline and entry.value.len > 0) {
                    self.allocator.free(entry.value);
                }
                self.allocator.destroy(entry);
            }
            s.store(EMPTY, .monotonic);
            if (self.keys[i].len > 0) {
                self.allocator.free(self.keys[i]);
                self.keys[i] = &[_]u8{};
            }
        }
        self.count.store(0, .monotonic);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────

test "lock-free map basic insert and get" {
    var map = try LockFreeMap.init(std.testing.allocator, 64);
    defer map.deinit();

    const r1 = try map.getOrPut("hello");
    try std.testing.expect(!r1.found);

    const r2 = try map.getOrPut("hello");
    try std.testing.expect(r2.found);
    try std.testing.expectEqual(r1.entry, r2.entry);

    try std.testing.expect(map.getPtr("hello") != null);
    try std.testing.expect(map.getPtr("missing") == null);
    try std.testing.expectEqual(@as(u32, 1), map.getCount());
}

test "lock-free map remove" {
    var map = try LockFreeMap.init(std.testing.allocator, 64);
    defer map.deinit();

    _ = try map.getOrPut("key1");
    _ = try map.getOrPut("key2");
    try std.testing.expectEqual(@as(u32, 2), map.getCount());

    const removed = map.remove("key1");
    try std.testing.expect(removed != null);
    std.testing.allocator.destroy(removed.?);
    try std.testing.expect(map.getPtr("key1") == null);
    try std.testing.expect(map.getPtr("key2") != null);
    try std.testing.expectEqual(@as(u32, 1), map.getCount());
}

test "lock-free map probe chain" {
    // Small capacity to force collisions
    var map = try LockFreeMap.init(std.testing.allocator, 8);
    defer map.deinit();

    _ = try map.getOrPut("a");
    _ = try map.getOrPut("b");
    _ = try map.getOrPut("c");
    _ = try map.getOrPut("d");

    try std.testing.expect(map.getPtr("a") != null);
    try std.testing.expect(map.getPtr("b") != null);
    try std.testing.expect(map.getPtr("c") != null);
    try std.testing.expect(map.getPtr("d") != null);
    try std.testing.expect(map.getPtr("e") == null);
    try std.testing.expectEqual(@as(u32, 4), map.getCount());
}

test "lock-free map clear" {
    var map = try LockFreeMap.init(std.testing.allocator, 32);
    defer map.deinit();

    _ = try map.getOrPut("x");
    _ = try map.getOrPut("y");
    map.clear();

    try std.testing.expectEqual(@as(u32, 0), map.getCount());
    try std.testing.expect(map.getPtr("x") == null);
}
