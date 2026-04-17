const std = @import("std");
const Allocator = std.mem.Allocator;

/// Core key-value store backed by a hash map.
/// All keys and values are owned byte slices.
/// Single-threaded by design (Redis model): the event loop guarantees
/// serial command execution, so no locks are needed on hot paths.
pub const KVStore = struct {
    map: std.StringHashMap(Entry),
    allocator: Allocator,
    io: std.Io,

    pub const Entry = struct {
        value: []const u8,
        expires_at: ?i64, // unix millis, null = no expiry
    };

    pub fn init(allocator: Allocator, io: std.Io) KVStore {
        return .{
            .map = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
            .io = io,
        };
    }

    fn nowMillis(self: *const KVStore) i64 {
        return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    }

    pub fn deinit(self: *KVStore) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.map.deinit();
    }

    pub fn set(self: *KVStore, key: []const u8, value: []const u8) !void {
        return self.setInternal(key, value, null);
    }

    pub fn setEx(self: *KVStore, key: []const u8, value: []const u8, ttl_seconds: i64) !void {
        const now = self.nowMillis();
        const expires = now + ttl_seconds * 1000;
        return self.setInternal(key, value, expires);
    }

    pub fn setPx(self: *KVStore, key: []const u8, value: []const u8, ttl_millis: i64) !void {
        const now = self.nowMillis();
        return self.setInternal(key, value, now + ttl_millis);
    }

    fn setInternal(self: *KVStore, key: []const u8, value: []const u8, expires_at: ?i64) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const result = self.map.getPtr(key);
        if (result) |existing| {
            self.allocator.free(existing.value);
            existing.value = owned_value;
            existing.expires_at = expires_at;
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try self.map.put(owned_key, .{
                .value = owned_value,
                .expires_at = expires_at,
            });
        }
    }

    pub fn get(self: *KVStore, key: []const u8) ?[]const u8 {
        const entry = self.map.getPtr(key) orelse return null;
        if (self.isExpired(entry)) {
            self.lazyEvict(key);
            return null;
        }
        return entry.value;
    }

    pub fn delete(self: *KVStore, key: []const u8) bool {
        const result = self.map.fetchRemove(key);
        if (result) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.value);
            return true;
        }
        return false;
    }

    pub fn exists(self: *KVStore, key: []const u8) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (self.isExpired(entry)) {
            self.lazyEvict(key);
            return false;
        }
        return true;
    }

    pub fn ttl(self: *KVStore, key: []const u8) ?i64 {
        const entry = self.map.getPtr(key) orelse return null;
        if (self.isExpired(entry)) {
            self.lazyEvict(key);
            return null;
        }
        const exp = entry.expires_at orelse return -1; // -1 means no expiry
        return @divTrunc(exp - self.nowMillis(), 1000);
    }

    pub fn dbsize(self: *KVStore) usize {
        return self.map.count();
    }

    pub fn keys(self: *KVStore, allocator: Allocator, pattern: []const u8) ![][]const u8 {
        var result = std.array_list.Managed([]const u8).init(allocator);
        errdefer result.deinit();

        const match_all = std.mem.eql(u8, pattern, "*");
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (match_all or globMatch(pattern, entry.key_ptr.*)) {
                try result.append(entry.key_ptr.*);
            }
        }
        return result.toOwnedSlice();
    }

    pub fn flushdb(self: *KVStore) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.map.clearAndFree();
    }

    pub fn restoreEntry(self: *KVStore, key: []const u8, value: []const u8, expires_at: ?i64) !void {
        return self.setInternal(key, value, expires_at);
    }

    fn isExpired(self: *KVStore, entry: *const Entry) bool {
        const exp = entry.expires_at orelse return false;
        return self.nowMillis() > exp;
    }

    fn lazyEvict(self: *KVStore, key: []const u8) void {
        const result = self.map.fetchRemove(key);
        if (result) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.value);
        }
    }
};

/// Minimal glob matcher supporting '*' (match any) and '?' (match one).
fn globMatch(pattern: []const u8, string: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;

    while (si < string.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == string[si])) {
            pi += 1;
            si += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_p = pi;
            star_s = si;
            pi += 1;
        } else if (star_p) |sp| {
            pi = sp + 1;
            star_s += 1;
            si = star_s;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ─── Tests ────────────────────────────────────────────────────────────

test "kv basic set/get" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("name", "zigraph");
    const val = store.get("name");
    try std.testing.expectEqualStrings("zigraph", val.?);
}

test "kv delete" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("key1", "val1");
    try std.testing.expect(store.delete("key1"));
    try std.testing.expect(store.get("key1") == null);
    try std.testing.expect(!store.delete("nonexistent"));
}

test "kv overwrite" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("k", "v1");
    try store.set("k", "v2");
    try std.testing.expectEqualStrings("v2", store.get("k").?);
}

test "kv exists" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("present", "yes");
    try std.testing.expect(store.exists("present"));
    try std.testing.expect(!store.exists("absent"));
}

test "glob matcher" {
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("hello*", "helloworld"));
    try std.testing.expect(globMatch("h?llo", "hello"));
    try std.testing.expect(!globMatch("h?llo", "hllo"));
    try std.testing.expect(globMatch("user:*:name", "user:42:name"));
}
