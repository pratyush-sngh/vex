const std = @import("std");
const Allocator = std.mem.Allocator;
const string_intern = @import("string_intern.zig");
const StringIntern = string_intern.StringIntern;

/// Sparse property storage for graph entities (nodes and edges).
///
/// HashMap for O(1) get/set, per-entity key-id index for O(k) range queries.
/// Composite key: (entity_id:u32 << 16) | prop_key_id:u16
pub const PropertyStore = struct {
    /// Primary store: O(1) point get/set.
    map: std.AutoHashMap(u64, []const u8),
    /// Per-entity index: entity_id → list of key_ids that entity has.
    /// Enables O(k) collectAll/countProps without scanning the full map.
    entity_index: std.AutoHashMap(u32, std.ArrayListUnmanaged(u16)),
    key_intern: StringIntern,
    allocator: Allocator,

    pub fn init(allocator: Allocator) PropertyStore {
        return .{
            .map = std.AutoHashMap(u64, []const u8).init(allocator),
            .entity_index = std.AutoHashMap(u32, std.ArrayListUnmanaged(u16)).init(allocator),
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

        var idx_iter = self.entity_index.iterator();
        while (idx_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.entity_index.deinit();
        self.key_intern.deinit();
    }

    fn compositeKey(entity_id: u32, key_id: u16) u64 {
        return (@as(u64, entity_id) << 16) | @as(u64, key_id);
    }

    /// Get a property value. O(1).
    pub fn get(self: *const PropertyStore, entity_id: u32, prop_key: []const u8) ?[]const u8 {
        const kid = self.key_intern.find(prop_key) orelse return null;
        return self.map.get(compositeKey(entity_id, kid));
    }

    /// Set a property value. O(1) amortized.
    pub fn set(self: *PropertyStore, entity_id: u32, prop_key: []const u8, value: []const u8) !void {
        const kid = try self.key_intern.intern(prop_key);
        const ck = compositeKey(entity_id, kid);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const gop = try self.map.getOrPut(ck);
        if (gop.found_existing) {
            // Update: free old value, no index change needed
            self.allocator.free(gop.value_ptr.*);
        } else {
            // Insert: add key_id to entity's index
            const idx_gop = try self.entity_index.getOrPut(entity_id);
            if (!idx_gop.found_existing) {
                idx_gop.value_ptr.* = .{ .items = &.{}, .capacity = 0 };
            }
            try idx_gop.value_ptr.append(self.allocator, kid);
        }
        gop.value_ptr.* = owned_value;
    }

    /// Delete a single property. O(k) where k = props on entity.
    pub fn delete(self: *PropertyStore, entity_id: u32, prop_key: []const u8) bool {
        const kid = self.key_intern.find(prop_key) orelse return false;
        const ck = compositeKey(entity_id, kid);

        if (self.map.fetchRemove(ck)) |kv| {
            self.allocator.free(kv.value);
            // Remove from entity index
            if (self.entity_index.getPtr(entity_id)) |list| {
                for (list.items, 0..) |id, i| {
                    if (id == kid) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
            }
            return true;
        }
        return false;
    }

    /// Delete all properties for an entity. O(k).
    pub fn deleteAll(self: *PropertyStore, entity_id: u32) void {
        if (self.entity_index.fetchRemove(entity_id)) |kv| {
            var list = kv.value;
            const base: u64 = @as(u64, entity_id) << 16;
            for (list.items) |kid| {
                if (self.map.fetchRemove(base | @as(u64, kid))) |prop| {
                    self.allocator.free(prop.value);
                }
            }
            list.deinit(self.allocator);
        }
    }

    /// Count properties for an entity. O(1).
    pub fn countProps(self: *const PropertyStore, entity_id: u32) u32 {
        const list = self.entity_index.get(entity_id) orelse return 0;
        return @intCast(list.items.len);
    }

    /// Iterate all properties for an entity. O(k).
    pub fn iterate(
        self: *const PropertyStore,
        entity_id: u32,
        callback: *const fn (key: []const u8, value: []const u8) void,
    ) void {
        const list = self.entity_index.get(entity_id) orelse return;
        const base: u64 = @as(u64, entity_id) << 16;
        for (list.items) |kid| {
            if (self.map.get(base | @as(u64, kid))) |val| {
                callback(self.key_intern.resolve(kid), val);
            }
        }
    }

    /// Collect all properties for an entity. O(k).
    pub fn collectAll(
        self: *const PropertyStore,
        entity_id: u32,
        allocator: Allocator,
    ) ![]PropPair {
        const list = self.entity_index.get(entity_id) orelse {
            return try allocator.alloc(PropPair, 0);
        };
        const base: u64 = @as(u64, entity_id) << 16;
        const result = try allocator.alloc(PropPair, list.items.len);
        var count: usize = 0;
        for (list.items) |kid| {
            if (self.map.get(base | @as(u64, kid))) |val| {
                result[count] = .{
                    .key = self.key_intern.resolve(kid),
                    .value = val,
                };
                count += 1;
            }
        }
        if (count < result.len) {
            return allocator.realloc(result, count) catch result[0..count];
        }
        return result;
    }

    pub const PropPair = struct {
        key: []const u8,
        value: []const u8,
    };
};
