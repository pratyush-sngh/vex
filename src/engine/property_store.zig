const std = @import("std");
const Allocator = std.mem.Allocator;
const string_intern = @import("string_intern.zig");
const StringIntern = string_intern.StringIntern;

/// Shared sparse property storage for graph entities (nodes and edges).
///
/// Instead of a HashMap per entity (56+ bytes overhead even when empty),
/// this uses a single HashMap keyed by (entity_id, prop_key_id) pair.
/// Entities with zero properties cost zero bytes.
pub const PropertyStore = struct {
    /// Key: (entity_id:u32 << 16) | prop_key_id:u16
    map: std.AutoHashMap(u64, []const u8),
    key_intern: StringIntern,
    allocator: Allocator,

    pub fn init(allocator: Allocator) PropertyStore {
        return .{
            .map = std.AutoHashMap(u64, []const u8).init(allocator),
            .key_intern = StringIntern.initWithCapacity(allocator, string_intern.MAX_PROPERTY_KEYS),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PropertyStore) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
        self.key_intern.deinit();
    }

    /// Compose the lookup key from entity ID and property key ID.
    fn compositeKey(entity_id: u32, key_id: u16) u64 {
        return (@as(u64, entity_id) << 16) | @as(u64, key_id);
    }

    /// Get a property value. Returns null if entity has no such property.
    pub fn get(self: *const PropertyStore, entity_id: u32, prop_key: []const u8) ?[]const u8 {
        const kid = self.key_intern.find(prop_key) orelse return null;
        return self.map.get(compositeKey(entity_id, kid));
    }

    /// Set a property value. Overwrites if exists. Interns the key name
    /// on first use.
    pub fn set(self: *PropertyStore, entity_id: u32, prop_key: []const u8, value: []const u8) !void {
        const kid = try self.key_intern.intern(prop_key);
        const ck = compositeKey(entity_id, kid);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const gop = try self.map.getOrPut(ck);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned_value;
    }

    /// Delete a single property. Returns true if it existed.
    pub fn delete(self: *PropertyStore, entity_id: u32, prop_key: []const u8) bool {
        const kid = self.key_intern.find(prop_key) orelse return false;
        const ck = compositeKey(entity_id, kid);

        if (self.map.fetchRemove(ck)) |kv| {
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    /// Delete all properties for an entity. Used when removing a node/edge.
    pub fn deleteAll(self: *PropertyStore, entity_id: u32) void {
        const base: u64 = @as(u64, entity_id) << 16;
        const num_keys = self.key_intern.count();

        for (0..num_keys) |i| {
            const ck = base | @as(u64, @as(u16, @intCast(i)));
            if (self.map.fetchRemove(ck)) |kv| {
                self.allocator.free(kv.value);
            }
        }
    }

    /// Count properties for an entity.
    pub fn countProps(self: *const PropertyStore, entity_id: u32) u32 {
        const base: u64 = @as(u64, entity_id) << 16;
        const num_keys = self.key_intern.count();
        var c: u32 = 0;

        for (0..num_keys) |i| {
            const ck = base | @as(u64, @as(u16, @intCast(i)));
            if (self.map.contains(ck)) c += 1;
        }
        return c;
    }

    /// Iterate all properties for an entity, calling the callback for each.
    pub fn iterate(
        self: *const PropertyStore,
        entity_id: u32,
        callback: *const fn (key: []const u8, value: []const u8) void,
    ) void {
        const base: u64 = @as(u64, entity_id) << 16;
        const num_keys = self.key_intern.count();

        for (0..num_keys) |i| {
            const kid: u16 = @intCast(i);
            const ck = base | @as(u64, kid);
            if (self.map.get(ck)) |val| {
                callback(self.key_intern.resolve(kid), val);
            }
        }
    }

    /// Collect all properties for an entity into a list of key-value pairs.
    pub fn collectAll(
        self: *const PropertyStore,
        entity_id: u32,
        allocator: Allocator,
    ) ![]PropPair {
        const base: u64 = @as(u64, entity_id) << 16;
        const num_keys = self.key_intern.count();

        var result = std.array_list.Managed(PropPair).init(allocator);
        errdefer result.deinit();

        for (0..num_keys) |i| {
            const kid: u16 = @intCast(i);
            const ck = base | @as(u64, kid);
            if (self.map.get(ck)) |val| {
                try result.append(.{
                    .key = self.key_intern.resolve(kid),
                    .value = val,
                });
            }
        }
        return result.toOwnedSlice();
    }

    pub const PropPair = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ─── Tests ────────────────────────────────────────────────────────────

test "property store set and get" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.set(0, "name", "auth-service");
    try store.set(0, "version", "2.1");
    try store.set(1, "name", "user-db");

    try std.testing.expectEqualStrings("auth-service", store.get(0, "name").?);
    try std.testing.expectEqualStrings("2.1", store.get(0, "version").?);
    try std.testing.expectEqualStrings("user-db", store.get(1, "name").?);
    try std.testing.expect(store.get(0, "missing") == null);
    try std.testing.expect(store.get(99, "name") == null);
}

test "property store overwrite" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.set(0, "v", "1.0");
    try store.set(0, "v", "2.0");

    try std.testing.expectEqualStrings("2.0", store.get(0, "v").?);
}

test "property store delete" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.set(0, "a", "1");
    try store.set(0, "b", "2");

    try std.testing.expect(store.delete(0, "a"));
    try std.testing.expect(!store.delete(0, "a")); // already deleted
    try std.testing.expect(store.get(0, "a") == null);
    try std.testing.expectEqualStrings("2", store.get(0, "b").?);
}

test "property store deleteAll" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.set(5, "x", "1");
    try store.set(5, "y", "2");
    try store.set(5, "z", "3");
    try store.set(6, "x", "other");

    store.deleteAll(5);

    try std.testing.expect(store.get(5, "x") == null);
    try std.testing.expect(store.get(5, "y") == null);
    try std.testing.expect(store.get(5, "z") == null);
    try std.testing.expectEqualStrings("other", store.get(6, "x").?);
}

test "property store count" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(u32, 0), store.countProps(0));

    try store.set(0, "a", "1");
    try store.set(0, "b", "2");
    try std.testing.expectEqual(@as(u32, 2), store.countProps(0));

    _ = store.delete(0, "a");
    try std.testing.expectEqual(@as(u32, 1), store.countProps(0));
}

test "property store collectAll" {
    var store = PropertyStore.init(std.testing.allocator);
    defer store.deinit();

    try store.set(0, "name", "svc");
    try store.set(0, "ver", "1.0");

    const pairs = try store.collectAll(0, std.testing.allocator);
    defer std.testing.allocator.free(pairs);

    try std.testing.expectEqual(@as(usize, 2), pairs.len);
}
