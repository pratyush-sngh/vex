const std = @import("std");
const Allocator = std.mem.Allocator;

/// Set storage: maps key -> unordered set of unique string members.
pub const SetStore = struct {
    sets: std.StringHashMap(MemberSet),
    allocator: Allocator,
    map_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    const MemberSet = struct {
        members: std.StringHashMap(void),
        allocator: Allocator,

        fn init(allocator: Allocator) MemberSet {
            return .{ .members = std.StringHashMap(void).init(allocator), .allocator = allocator };
        }

        fn deinit(self: *MemberSet) void {
            var it = self.members.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.members.deinit();
        }
    };

    pub fn init(allocator: Allocator) SetStore {
        var store = SetStore{ .sets = std.StringHashMap(MemberSet).init(allocator), .allocator = allocator };
        store.sets.ensureTotalCapacity(4096) catch {};
        return store;
    }

    pub fn flush(self: *SetStore) void {
        var it = self.sets.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.sets.clearRetainingCapacity();
    }

    pub fn deinit(self: *SetStore) void {
        var it = self.sets.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.sets.deinit();
    }

    /// SADD key member [member ...] — add members, returns count of NEW members added.
    pub fn sadd(self: *SetStore, key: []const u8, members: []const []const u8) !usize {
        const s = try self.getOrCreate(key);
        var added: usize = 0;
        for (members) |member| {
            const gop = try s.members.getOrPut(member);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, member);
                added += 1;
            }
        }
        return added;
    }

    /// SADD with pre-allocated owned members. Caller allocated, set takes ownership.
    /// Frees members that already exist (duplicates).
    pub fn saddOwned(self: *SetStore, key: []const u8, owned: []const []u8) !usize {
        const s = try self.getOrCreate(key);
        var added: usize = 0;
        for (owned) |member| {
            const gop = try s.members.getOrPut(member);
            if (!gop.found_existing) {
                gop.key_ptr.* = member; // take ownership
                added += 1;
            } else {
                self.allocator.free(member); // duplicate, free the pre-alloc
            }
        }
        return added;
    }

    /// SREM key member [member ...] — remove members, returns count removed.
    pub fn srem(self: *SetStore, key: []const u8, members: []const []const u8) usize {
        const s = self.sets.getPtr(key) orelse return 0;
        var removed: usize = 0;
        for (members) |member| {
            const entry = s.members.fetchRemove(member) orelse continue;
            self.allocator.free(entry.key);
            removed += 1;
        }
        if (s.members.count() == 0) self.removeKey(key);
        return removed;
    }

    /// SISMEMBER key member — check membership.
    pub fn sismember(self: *SetStore, key: []const u8, member: []const u8) bool {
        const s = self.sets.getPtr(key) orelse return false;
        return s.members.contains(member);
    }

    /// SCARD key — cardinality (number of members).
    pub fn scard(self: *SetStore, key: []const u8) usize {
        const s = self.sets.getPtr(key) orelse return 0;
        return s.members.count();
    }

    /// SMEMBERS key — return all members.
    pub fn smembers(self: *SetStore, key: []const u8, allocator: Allocator) ![]const []const u8 {
        const s = self.sets.getPtr(key) orelse return &[_][]const u8{};
        const count = s.members.count();
        if (count == 0) return &[_][]const u8{};
        const result = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        var it = s.members.iterator();
        while (it.next()) |entry| {
            result[i] = entry.key_ptr.*;
            i += 1;
        }
        return result;
    }

    /// SUNION key [key ...] — return union of all sets.
    pub fn sunion(self: *SetStore, keys: []const []const u8, allocator: Allocator) ![]const []const u8 {
        var union_set = std.StringHashMap(void).init(allocator);
        defer union_set.deinit();
        for (keys) |key| {
            const s = self.sets.getPtr(key) orelse continue;
            var it = s.members.iterator();
            while (it.next()) |entry| {
                try union_set.put(entry.key_ptr.*, {});
            }
        }
        if (union_set.count() == 0) return &[_][]const u8{};
        const result = try allocator.alloc([]const u8, union_set.count());
        var i: usize = 0;
        var it = union_set.iterator();
        while (it.next()) |entry| {
            result[i] = entry.key_ptr.*;
            i += 1;
        }
        return result;
    }

    /// SINTER key [key ...] — return intersection of all sets.
    pub fn sinter(self: *SetStore, keys: []const []const u8, allocator: Allocator) ![]const []const u8 {
        if (keys.len == 0) return &[_][]const u8{};
        // Start with the first set
        const first = self.sets.getPtr(keys[0]) orelse return &[_][]const u8{};
        var result_list = std.array_list.Managed([]const u8).init(allocator);
        defer result_list.deinit();
        var it = first.members.iterator();
        while (it.next()) |entry| {
            var in_all = true;
            for (keys[1..]) |other_key| {
                const other = self.sets.getPtr(other_key) orelse {
                    in_all = false;
                    break;
                };
                if (!other.members.contains(entry.key_ptr.*)) {
                    in_all = false;
                    break;
                }
            }
            if (in_all) try result_list.append(entry.key_ptr.*);
        }
        if (result_list.items.len == 0) return &[_][]const u8{};
        return try result_list.toOwnedSlice();
    }

    /// SDIFF key [key ...] — return members in first set but not in others.
    pub fn sdiff(self: *SetStore, keys: []const []const u8, allocator: Allocator) ![]const []const u8 {
        if (keys.len == 0) return &[_][]const u8{};
        const first = self.sets.getPtr(keys[0]) orelse return &[_][]const u8{};
        var result_list = std.array_list.Managed([]const u8).init(allocator);
        defer result_list.deinit();
        var it = first.members.iterator();
        while (it.next()) |entry| {
            var in_other = false;
            for (keys[1..]) |other_key| {
                const other = self.sets.getPtr(other_key) orelse continue;
                if (other.members.contains(entry.key_ptr.*)) {
                    in_other = true;
                    break;
                }
            }
            if (!in_other) try result_list.append(entry.key_ptr.*);
        }
        if (result_list.items.len == 0) return &[_][]const u8{};
        return try result_list.toOwnedSlice();
    }

    /// Check if a key exists as a set.
    pub fn exists(self: *SetStore, key: []const u8) bool {
        return self.sets.contains(key);
    }

    /// Delete a set key entirely.
    pub fn delete(self: *SetStore, key: []const u8) bool {
        var entry = self.sets.fetchRemove(key) orelse return false;
        entry.value.deinit();
        self.allocator.free(entry.key);
        return true;
    }

    fn getOrCreate(self: *SetStore, key: []const u8) !*MemberSet {
        if (self.sets.getPtr(key)) |existing| return existing;
        _ = std.c.pthread_mutex_lock(&self.map_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.map_mutex);
        if (self.sets.getPtr(key)) |existing| return existing;
        const gop = try self.sets.getOrPut(key);
        gop.key_ptr.* = try self.allocator.dupe(u8, key);
        var ms = MemberSet.init(self.allocator);
        ms.members.ensureTotalCapacity(32) catch {};
        gop.value_ptr.* = ms;
        return gop.value_ptr;
    }

    fn removeKey(self: *SetStore, key: []const u8) void {
        _ = std.c.pthread_mutex_lock(&self.map_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.map_mutex);
        var entry = self.sets.fetchRemove(key) orelse return;
        entry.value.deinit();
        self.allocator.free(entry.key);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────

test "SADD and SISMEMBER" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    const added = try store.sadd("s", &[_][]const u8{ "a", "b", "c", "a" });
    try std.testing.expectEqual(@as(usize, 3), added); // "a" duplicate ignored
    try std.testing.expect(store.sismember("s", "a"));
    try std.testing.expect(store.sismember("s", "b"));
    try std.testing.expect(!store.sismember("s", "x"));
}

test "SREM" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("s", &[_][]const u8{ "a", "b", "c" });
    const removed = store.srem("s", &[_][]const u8{ "a", "x" });
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 2), store.scard("s"));
    try std.testing.expect(!store.sismember("s", "a"));
}

test "SMEMBERS" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("s", &[_][]const u8{ "x", "y" });
    const members = try store.smembers("s", std.testing.allocator);
    defer std.testing.allocator.free(members);
    try std.testing.expectEqual(@as(usize, 2), members.len);
}

test "SUNION" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("a", &[_][]const u8{ "1", "2" });
    _ = try store.sadd("b", &[_][]const u8{ "2", "3" });
    const u = try store.sunion(&[_][]const u8{ "a", "b" }, std.testing.allocator);
    defer std.testing.allocator.free(u);
    try std.testing.expectEqual(@as(usize, 3), u.len);
}

test "SINTER" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("a", &[_][]const u8{ "1", "2", "3" });
    _ = try store.sadd("b", &[_][]const u8{ "2", "3", "4" });
    const inter = try store.sinter(&[_][]const u8{ "a", "b" }, std.testing.allocator);
    defer std.testing.allocator.free(inter);
    try std.testing.expectEqual(@as(usize, 2), inter.len);
}

test "SDIFF" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("a", &[_][]const u8{ "1", "2", "3" });
    _ = try store.sadd("b", &[_][]const u8{ "2", "4" });
    const d = try store.sdiff(&[_][]const u8{ "a", "b" }, std.testing.allocator);
    defer std.testing.allocator.free(d);
    try std.testing.expectEqual(@as(usize, 2), d.len);
}

test "empty after SREM auto-deletes" {
    var store = SetStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.sadd("tmp", &[_][]const u8{"x"});
    _ = store.srem("tmp", &[_][]const u8{"x"});
    try std.testing.expect(!store.exists("tmp"));
}
