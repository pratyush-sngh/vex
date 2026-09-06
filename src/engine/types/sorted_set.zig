const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sorted Set storage: maps key -> set of (member, score) pairs ordered by score.
/// Uses HashMap for O(1) score lookup + sorted slice for range queries.
pub const SortedSetStore = struct {
    zsets: std.StringHashMap(ZSet),
    allocator: Allocator,
    map_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub const Entry = struct {
        member: []const u8,
        score: f64,
    };

    const ZSet = struct {
        scores: std.StringHashMap(f64), // member → score (O(1) lookup)
        sorted_cache: ?[]Entry, // lazily rebuilt sorted array
        cache_dirty: bool,
        allocator: Allocator,

        fn init(allocator: Allocator) ZSet {
            return .{
                .scores = std.StringHashMap(f64).init(allocator),
                .sorted_cache = null,
                .cache_dirty = true,
                .allocator = allocator,
            };
        }

        fn deinit(self: *ZSet) void {
            if (self.sorted_cache) |cache| self.allocator.free(cache);
            var it = self.scores.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.scores.deinit();
        }

        fn invalidateCache(self: *ZSet) void {
            if (self.sorted_cache) |cache| self.allocator.free(cache);
            self.sorted_cache = null;
            self.cache_dirty = true;
        }

        fn ensureSorted(self: *ZSet) ?[]const Entry {
            if (!self.cache_dirty) {
                return self.sorted_cache;
            }
            // Rebuild sorted cache
            const count = self.scores.count();
            if (count == 0) {
                self.sorted_cache = null;
                self.cache_dirty = false;
                return null;
            }
            const entries = self.allocator.alloc(Entry, count) catch return null;
            var i: usize = 0;
            var it = self.scores.iterator();
            while (it.next()) |entry| {
                entries[i] = .{ .member = entry.key_ptr.*, .score = entry.value_ptr.* };
                i += 1;
            }
            std.mem.sort(Entry, entries, {}, struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    if (a.score != b.score) return a.score < b.score;
                    return std.mem.order(u8, a.member, b.member) == .lt;
                }
            }.lessThan);
            self.sorted_cache = entries;
            self.cache_dirty = false;
            return entries;
        }
    };

    pub fn init(allocator: Allocator) SortedSetStore {
        return .{ .zsets = std.StringHashMap(ZSet).init(allocator), .allocator = allocator };
    }

    pub fn flush(self: *SortedSetStore) void {
        var it = self.zsets.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.zsets.clearRetainingCapacity();
    }

    pub fn deinit(self: *SortedSetStore) void {
        self.flush();
        self.zsets.deinit();
    }

    /// ZADD key score member [score member ...] — add members with scores. Returns count of NEW members.
    pub fn zadd(self: *SortedSetStore, key: []const u8, score_members: []const []const u8) !usize {
        const zs = try self.getOrCreate(key);
        var added: usize = 0;
        var i: usize = 0;
        while (i + 1 < score_members.len) : (i += 2) {
            const score = std.fmt.parseFloat(f64, score_members[i]) catch continue;
            const member = score_members[i + 1];
            const gop = try zs.scores.getOrPut(member);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, member);
                added += 1;
            }
            gop.value_ptr.* = score;
        }
        zs.invalidateCache();
        return added;
    }

    /// ZREM key member [member ...] — remove members. Returns count removed.
    pub fn zrem(self: *SortedSetStore, key: []const u8, members: []const []const u8) usize {
        const zs = self.zsets.getPtr(key) orelse return 0;
        var removed: usize = 0;
        for (members) |member| {
            const entry = zs.scores.fetchRemove(member) orelse continue;
            self.allocator.free(entry.key);
            removed += 1;
        }
        if (removed > 0) zs.invalidateCache();
        if (zs.scores.count() == 0) self.removeKey(key);
        return removed;
    }

    /// ZSCORE key member — return score of member, or null if not found.
    pub fn zscore(self: *SortedSetStore, key: []const u8, member: []const u8) ?f64 {
        const zs = self.zsets.getPtr(key) orelse return null;
        return zs.scores.get(member);
    }

    /// ZCARD key — number of members.
    pub fn zcard(self: *SortedSetStore, key: []const u8) usize {
        const zs = self.zsets.getPtr(key) orelse return 0;
        return zs.scores.count();
    }

    /// ZRANK key member — 0-based rank (by ascending score). Returns null if not found.
    pub fn zrank(self: *SortedSetStore, key: []const u8, member: []const u8) ?usize {
        const zs = self.zsets.getPtr(key) orelse return null;
        _ = zs.scores.get(member) orelse return null;
        const sorted = zs.ensureSorted() orelse return null;
        for (sorted, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.member, member)) return i;
        }
        return null;
    }

    /// ZRANGE key start stop [WITHSCORES] — return members in rank range (ascending score).
    pub fn zrange(self: *SortedSetStore, key: []const u8, start_in: i64, stop_in: i64, allocator: Allocator) ![]const Entry {
        const zs = self.zsets.getPtr(key) orelse return &[_]Entry{};
        const sorted = zs.ensureSorted() orelse return &[_]Entry{};
        const len: i64 = @intCast(sorted.len);
        var start = start_in;
        var stop = stop_in;
        if (start < 0) start += len;
        if (stop < 0) stop += len;
        if (start < 0) start = 0;
        if (stop >= len) stop = len - 1;
        if (start > stop) return &[_]Entry{};
        const s: usize = @intCast(start);
        const e: usize = @intCast(stop + 1);
        // Copy the slice for the caller
        const result = try allocator.alloc(Entry, e - s);
        @memcpy(result, sorted[s..e]);
        return result;
    }

    /// ZINCRBY key increment member — increment score of member.
    pub fn zincrby(self: *SortedSetStore, key: []const u8, delta: f64, member: []const u8) !f64 {
        const zs = try self.getOrCreate(key);
        const gop = try zs.scores.getOrPut(member);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, member);
            gop.value_ptr.* = delta;
        } else {
            gop.value_ptr.* += delta;
        }
        zs.invalidateCache();
        return gop.value_ptr.*;
    }

    /// ZCOUNT key min max — count members with score between min and max (inclusive).
    pub fn zcount(self: *SortedSetStore, key: []const u8, min: f64, max: f64) usize {
        const zs = self.zsets.getPtr(key) orelse return 0;
        var count: usize = 0;
        var it = zs.scores.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* >= min and entry.value_ptr.* <= max) count += 1;
        }
        return count;
    }

    /// Check if a key exists as a sorted set.
    pub fn exists(self: *SortedSetStore, key: []const u8) bool {
        return self.zsets.contains(key);
    }

    /// Delete a sorted set key entirely.
    pub fn delete(self: *SortedSetStore, key: []const u8) bool {
        var entry = self.zsets.fetchRemove(key) orelse return false;
        entry.value.deinit();
        self.allocator.free(entry.key);
        return true;
    }

    fn getOrCreate(self: *SortedSetStore, key: []const u8) !*ZSet {
        // Fast path: key exists — no mutex needed
        if (self.zsets.getPtr(key)) |existing| return existing;
        // Slow path: new key — mutex protects HashMap mutation
        _ = std.c.pthread_mutex_lock(&self.map_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.map_mutex);
        // Double-check after acquiring mutex
        if (self.zsets.getPtr(key)) |existing| return existing;
        const gop = try self.zsets.getOrPut(key);
        gop.key_ptr.* = try self.allocator.dupe(u8, key);
        gop.value_ptr.* = ZSet.init(self.allocator);
        return gop.value_ptr;
    }

    fn removeKey(self: *SortedSetStore, key: []const u8) void {
        _ = std.c.pthread_mutex_lock(&self.map_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.map_mutex);
        var entry = self.zsets.fetchRemove(key) orelse return;
        entry.value.deinit();
        self.allocator.free(entry.key);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────

