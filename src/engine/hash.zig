const std = @import("std");
const Allocator = std.mem.Allocator;

/// Hash storage: maps key -> { field -> value }.
/// Each hash is a StringHashMap of field-value pairs.
pub const HashStore = struct {
    hashes: std.StringHashMap(FieldMap),
    allocator: Allocator,

    const FieldMap = struct {
        fields: std.StringHashMap([]u8),
        allocator: Allocator,

        fn init(allocator: Allocator) FieldMap {
            return .{
                .fields = std.StringHashMap([]u8).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: *FieldMap) void {
            var it = self.fields.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.fields.deinit();
        }

        fn set(self: *FieldMap, field: []const u8, value: []const u8) !bool {
            const gop = try self.fields.getOrPut(field);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = try self.allocator.dupe(u8, value);
                return false; // updated existing
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, field);
                gop.value_ptr.* = try self.allocator.dupe(u8, value);
                return true; // new field
            }
        }
    };

    pub fn init(allocator: Allocator) HashStore {
        return .{
            .hashes = std.StringHashMap(FieldMap).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HashStore) void {
        var it = self.hashes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.hashes.deinit();
    }

    /// HSET key field value [field value ...] — set fields, returns count of NEW fields added.
    pub fn hset(self: *HashStore, key: []const u8, field_values: []const []const u8) !usize {
        const fm = try self.getOrCreate(key);
        var new_count: usize = 0;
        var i: usize = 0;
        while (i + 1 < field_values.len) : (i += 2) {
            if (try fm.set(field_values[i], field_values[i + 1])) new_count += 1;
        }
        return new_count;
    }

    /// HSET with pre-allocated owned field+value pairs. No allocation under lock.
    /// owned_fv is [field0, value0, field1, value1, ...] — all owned by caller.
    pub fn hsetOwned(self: *HashStore, key: []const u8, owned_fv: []const []u8) !usize {
        const fm = try self.getOrCreate(key);
        var new_count: usize = 0;
        var i: usize = 0;
        while (i + 1 < owned_fv.len) : (i += 2) {
            const field = owned_fv[i];
            const value = owned_fv[i + 1];
            const gop = try fm.fields.getOrPut(field);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                self.allocator.free(field); // unused pre-alloc
                gop.value_ptr.* = value;
            } else {
                gop.key_ptr.* = field; // take ownership
                gop.value_ptr.* = value; // take ownership
                new_count += 1;
            }
        }
        return new_count;
    }

    /// HGET key field — get a single field value.
    pub fn hget(self: *HashStore, key: []const u8, field: []const u8) ?[]const u8 {
        const fm = self.hashes.getPtr(key) orelse return null;
        return fm.fields.get(field);
    }

    /// HDEL key field [field ...] — delete fields, returns count deleted.
    pub fn hdel(self: *HashStore, key: []const u8, fields: []const []const u8) usize {
        const fm = self.hashes.getPtr(key) orelse return 0;
        var count: usize = 0;
        for (fields) |field| {
            const entry = fm.fields.fetchRemove(field) orelse continue;
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            count += 1;
        }
        if (fm.fields.count() == 0) self.removeKey(key);
        return count;
    }

    /// HGETALL key — return all field-value pairs as flat array [f1, v1, f2, v2, ...].
    pub fn hgetall(self: *HashStore, key: []const u8, allocator: Allocator) ![]const []const u8 {
        const fm = self.hashes.getPtr(key) orelse return &[_][]const u8{};
        const count = fm.fields.count();
        if (count == 0) return &[_][]const u8{};
        const result = try allocator.alloc([]const u8, count * 2);
        var i: usize = 0;
        var it = fm.fields.iterator();
        while (it.next()) |entry| {
            result[i] = entry.key_ptr.*;
            result[i + 1] = entry.value_ptr.*;
            i += 2;
        }
        return result;
    }

    /// HLEN key — number of fields.
    pub fn hlen(self: *HashStore, key: []const u8) usize {
        const fm = self.hashes.getPtr(key) orelse return 0;
        return fm.fields.count();
    }

    /// HEXISTS key field — check if field exists.
    pub fn hexists(self: *HashStore, key: []const u8, field: []const u8) bool {
        const fm = self.hashes.getPtr(key) orelse return false;
        return fm.fields.contains(field);
    }

    /// HKEYS key — return all field names.
    pub fn hkeys(self: *HashStore, key: []const u8, allocator: Allocator) ![]const []const u8 {
        const fm = self.hashes.getPtr(key) orelse return &[_][]const u8{};
        const count = fm.fields.count();
        if (count == 0) return &[_][]const u8{};
        const result = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        var it = fm.fields.iterator();
        while (it.next()) |entry| {
            result[i] = entry.key_ptr.*;
            i += 1;
        }
        return result;
    }

    /// HVALS key — return all values.
    pub fn hvals(self: *HashStore, key: []const u8, allocator: Allocator) ![]const []const u8 {
        const fm = self.hashes.getPtr(key) orelse return &[_][]const u8{};
        const count = fm.fields.count();
        if (count == 0) return &[_][]const u8{};
        const result = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        var it = fm.fields.iterator();
        while (it.next()) |entry| {
            result[i] = entry.value_ptr.*;
            i += 1;
        }
        return result;
    }

    /// HINCRBY key field increment — increment field's integer value.
    pub fn hincrby(self: *HashStore, key: []const u8, field: []const u8, delta: i64) !i64 {
        const fm = try self.getOrCreate(key);
        var current: i64 = 0;
        if (fm.fields.get(field)) |val| {
            current = std.fmt.parseInt(i64, val, 10) catch return error.NotAnInteger;
        }
        const new_val = current + delta;
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{new_val}) catch return error.InternalError;
        _ = try fm.set(field, s);
        return new_val;
    }

    /// Check if a key exists as a hash.
    pub fn exists(self: *HashStore, key: []const u8) bool {
        return self.hashes.contains(key);
    }

    /// Delete a hash key entirely.
    pub fn delete(self: *HashStore, key: []const u8) bool {
        var entry = self.hashes.fetchRemove(key) orelse return false;
        entry.value.deinit();
        self.allocator.free(entry.key);
        return true;
    }

    fn getOrCreate(self: *HashStore, key: []const u8) !*FieldMap {
        const gop = try self.hashes.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            gop.value_ptr.* = FieldMap.init(self.allocator);
        }
        return gop.value_ptr;
    }

    fn removeKey(self: *HashStore, key: []const u8) void {
        var entry = self.hashes.fetchRemove(key) orelse return;
        entry.value.deinit();
        self.allocator.free(entry.key);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────

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
