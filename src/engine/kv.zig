const std = @import("std");
const Allocator = std.mem.Allocator;
const obs_stats = @import("../observability/stats.zig");
const event_stats = @import("../observability/event_stats.zig");

/// Core key-value store backed by a hash map.
/// All keys and values are owned byte slices.
/// Single-threaded by design (Redis model): the event loop guarantees
/// serial command execution, so no locks are needed on hot paths.
///
/// Optimizations over naive HashMap:
///   - Tombstone DEL: delete sets a flag (~25ns) instead of free+remove (~140ns)
///   - Cached clock: TTL checks use a cached timestamp, not a syscall per GET
///   - ttl_count: skip expiry checks entirely when no keys have TTL
///   - getOrPut: single hash per SET instead of two (getPtr + put)
///   - Compact Entry: i64 (8B) instead of ?i64 (16B) for expires_at
pub const EvictionPolicy = enum {
    noeviction,
    allkeys_lru,
};

pub const KVStore = struct {
    map: std.StringHashMap(Entry),
    allocator: Allocator,
    io: std.Io,
    cached_now_ms: i64,
    ttl_count: u32,
    tombstone_count: u32,
    live_count: u32,
    maxmemory: usize,
    eviction_policy: EvictionPolicy,

    pub const EntryFlags = packed struct {
        deleted: bool = false,
        has_ttl: bool = false,
        is_integer: bool = false,
        is_inline: bool = false, // value stored in inline_buf (no heap alloc)
        _padding: u4 = 0,
    };

    /// Inline buffer size for small values. Values ≤ this are stored in-place
    /// (no heap allocation, enables lock-free GET via SeqLock).
    /// 32 bytes covers redis-benchmark default (3 bytes) + most real-world keys.
    /// Kept small to minimize Entry size for cache efficiency.
    pub const INLINE_BUF_SIZE = 32;

    pub const Entry = struct {
        value: []const u8, // heap-allocated for large values, points into inline_buf for small
        expires_at: i64 = 0,
        last_access: i64 = 0,
        int_value: i64 = 0, // cached native integer (valid when flags.is_integer)
        /// SeqLock: odd = write in progress, even = stable. Readers retry if changed.
        seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Inline buffer for small values (≤ 128 bytes). Avoids heap alloc + enables lock-free GET.
        inline_buf: [INLINE_BUF_SIZE]u8 = undefined,
        inline_len: u8 = 0,
        flags: EntryFlags = .{},
    };

    pub fn init(allocator: Allocator, io: std.Io) KVStore {
        return .{
            .map = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
            .io = io,
            .cached_now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            .ttl_count = 0,
            .tombstone_count = 0,
            .live_count = 0,
            .maxmemory = 0, // 0 = unlimited
            .eviction_policy = .noeviction,
        };
    }

    /// Update the cached clock. Call once per event loop tick, not per operation.
    /// Eliminates ~20ns clock_gettime syscall from every GET/EXISTS/TTL.
    pub fn updateClock(self: *KVStore) void {
        self.cached_now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    }

    fn nowMillis(self: *const KVStore) i64 {
        return self.cached_now_ms;
    }

    pub fn deinit(self: *KVStore) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.value.len > 0 or !entry.value_ptr.flags.deleted) {
                self.allocator.free(entry.value_ptr.value);
            }
        }
        self.map.deinit();
    }

    /// One row of a frozen kv snapshot. Owned by the snapshot slice; freed
    /// via freeSnapshot. Used by the background persistence paths (BGSAVE,
    /// BGREWRITEAOF) so they can iterate without holding kv_mutex through
    /// disk I/O.
    pub const SnapshotEntry = struct {
        key: []u8,
        value: []u8,
        expires_at: i64,
        has_ttl: bool,
    };

    /// Take a point-in-time snapshot of all live entries. The caller is
    /// responsible for holding any lock that excludes writers while this
    /// runs (kv_mutex in the current architecture). The returned slice and
    /// its bytes must be released via freeSnapshot.
    pub fn snapshot(self: *KVStore, allocator: Allocator) ![]SnapshotEntry {
        var list = std.array_list.Managed(SnapshotEntry).init(allocator);
        errdefer {
            for (list.items) |e| {
                allocator.free(e.key);
                allocator.free(e.value);
            }
            list.deinit();
        }

        try list.ensureTotalCapacity(self.live_count);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
            if (entry.value_ptr.flags.has_ttl) {
                const remaining = entry.value_ptr.expires_at - self.cached_now_ms;
                if (remaining <= 0) continue; // already expired
            }
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);
            const val_copy = try allocator.dupe(u8, entry.value_ptr.value);
            errdefer allocator.free(val_copy);
            try list.append(.{
                .key = key_copy,
                .value = val_copy,
                .expires_at = entry.value_ptr.expires_at,
                .has_ttl = entry.value_ptr.flags.has_ttl,
            });
        }

        return list.toOwnedSlice();
    }

    pub fn freeSnapshot(entries: []SnapshotEntry, allocator: Allocator) void {
        for (entries) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        allocator.free(entries);
    }

    pub fn set(self: *KVStore, key: []const u8, value: []const u8) !void {
        return self.setInternal(key, value, 0);
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

    /// SET with single-hash getOrPut, tombstone reuse, and compact entry.
    fn setInternal(self: *KVStore, key: []const u8, value: []const u8, expires_at: i64) !void {
        // LRU eviction: if maxmemory is set, evict before inserting
        if (self.maxmemory > 0) {
            try self.evictIfNeeded();
        }

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const has_ttl = expires_at != 0;
        const now = self.cached_now_ms;

        // Single hash via getOrPut (was: getPtr + put = two hashes on insert)
        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) {
            const old = gop.value_ptr;
            if (old.flags.deleted) {
                // Reuse tombstoned slot — key is already allocated, skip key alloc
                self.tombstone_count -= 1;
                self.live_count += 1;
            } else {
                // Normal update — free old value
                self.allocator.free(old.value);
                if (old.flags.has_ttl and !has_ttl) self.ttl_count -= 1;
                if (!old.flags.has_ttl and has_ttl) self.ttl_count += 1;
            }
            gop.value_ptr.* = .{
                .value = owned_value,
                .expires_at = expires_at,
                .last_access = now,
                .flags = .{ .has_ttl = has_ttl },
            };
        } else {
            // New key — allocate and insert
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{
                .value = owned_value,
                .expires_at = expires_at,
                .last_access = now,
                .flags = .{ .has_ttl = has_ttl },
            };
            self.live_count += 1;
            if (has_ttl) self.ttl_count += 1;
        }
    }

    /// Estimate total memory used by all live entries.
    pub fn memoryUsage(self: *const KVStore) usize {
        var total: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
            total += entry.key_ptr.*.len + entry.value_ptr.value.len + @sizeOf(Entry);
        }
        return total;
    }

    /// Evict keys using approximate LRU (sample 5, evict oldest) until under maxmemory.
    pub fn evictIfNeeded(self: *KVStore) !void {
        if (self.maxmemory == 0) return;
        if (self.eviction_policy == .noeviction) {
            if (self.memoryUsage() > self.maxmemory) return error.OutOfMemory;
            return;
        }

        // Time the eviction cycle as a LATENCY event — only fires when we
        // actually need to evict at least one key. Cheap when memory is below
        // maxmemory because the while-loop body never executes.
        const needs_eviction = self.memoryUsage() > self.maxmemory;
        const ev_span: ?event_stats.Span = if (needs_eviction) event_stats.Span.begin() else null;
        defer if (ev_span) |s| s.end(.eviction_cycle);

        // allkeys-lru: sample 5 random keys, evict the one with oldest last_access
        while (self.memoryUsage() > self.maxmemory) {
            if (self.live_count == 0) break;

            var oldest_key: ?[]const u8 = null;
            var oldest_access: i64 = std.math.maxInt(i64);
            var samples: usize = 0;
            var it = self.map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.flags.deleted) continue;
                if (entry.value_ptr.last_access < oldest_access) {
                    oldest_access = entry.value_ptr.last_access;
                    oldest_key = entry.key_ptr.*;
                }
                samples += 1;
                if (samples >= 5) break;
            }

            if (oldest_key) |key| {
                if (self.map.getPtr(key)) |entry| {
                    self.tombstoneEntry(key, entry);
                    _ = obs_stats.evicted_keys.fetchAdd(1, .monotonic);
                }
            } else break;
        }
    }

    /// GET with cached clock and ttl_count fast path.
    pub fn get(self: *KVStore, key: []const u8) ?[]const u8 {
        const entry = self.map.getPtr(key) orelse return null;
        if (entry.flags.deleted) return null;
        // Skip expiry check entirely when no keys have TTL
        if (self.ttl_count > 0 and entry.flags.has_ttl) {
            if (self.nowMillis() > entry.expires_at) {
                self.tombstoneEntry(key, entry);
                _ = obs_stats.expired_keys.fetchAdd(1, .monotonic);
                return null;
            }
        }
        entry.last_access = self.cached_now_ms;
        return entry.value;
    }

    /// Tombstone DEL: set flag, no fetchRemove, no free.
    /// ~25ns vs ~140ns for full delete.
    pub fn delete(self: *KVStore, key: []const u8) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (entry.flags.deleted) return false;
        // Check expiry first
        if (self.ttl_count > 0 and entry.flags.has_ttl) {
            if (self.nowMillis() > entry.expires_at) {
                self.tombstoneEntry(key, entry);
                return false; // was already expired
            }
        }
        self.tombstoneEntry(key, entry);
        return true;
    }

    pub fn exists(self: *KVStore, key: []const u8) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (entry.flags.deleted) return false;
        if (self.ttl_count > 0 and entry.flags.has_ttl) {
            if (self.nowMillis() > entry.expires_at) {
                self.tombstoneEntry(key, entry);
                return false;
            }
        }
        entry.last_access = self.cached_now_ms;
        return true;
    }

    pub fn ttl(self: *KVStore, key: []const u8) ?i64 {
        const entry = self.map.getPtr(key) orelse return null;
        if (entry.flags.deleted) return null;
        if (!entry.flags.has_ttl) return -1; // no expiry
        if (self.nowMillis() > entry.expires_at) {
            self.tombstoneEntry(key, entry);
            return null;
        }
        return @divTrunc(entry.expires_at - self.nowMillis(), 1000);
    }

    pub fn dbsize(self: *KVStore) usize {
        return self.live_count;
    }

    pub fn keys(self: *KVStore, allocator: Allocator, pattern: []const u8) ![][]const u8 {
        var result = std.array_list.Managed([]const u8).init(allocator);
        errdefer result.deinit();

        const match_all = std.mem.eql(u8, pattern, "*");
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
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
        self.map.clearRetainingCapacity();
        self.ttl_count = 0;
        self.tombstone_count = 0;
        self.live_count = 0;
    }

    pub fn restoreEntry(self: *KVStore, key: []const u8, value: []const u8, expires_at: ?i64) !void {
        return self.setInternal(key, value, expires_at orelse 0);
    }

    /// Compact tombstones: actually remove deleted entries and free memory.
    /// Call periodically or when tombstone_count > live_count * 0.25.
    pub fn compactTombstones(self: *KVStore) void {
        if (self.tombstone_count == 0) return;

        // Collect keys to remove (can't remove during iteration)
        var to_remove = std.array_list.Managed([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.flags.deleted) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.value);
            }
        }

        self.tombstone_count = 0;
    }

    /// Whether compaction should be triggered.
    pub fn needsCompaction(self: *const KVStore) bool {
        if (self.live_count == 0) return self.tombstone_count > 0;
        return self.tombstone_count > self.live_count / 4;
    }

    // ─── Internal ─────────────────────────────────────────────────────

    fn tombstoneEntry(self: *KVStore, key: []const u8, entry: *Entry) void {
        _ = key;
        // Free the value memory but keep the key in the HashMap
        self.allocator.free(entry.value);
        entry.value = &.{};
        if (entry.flags.has_ttl) self.ttl_count -= 1;
        entry.flags.deleted = true;
        entry.flags.has_ttl = false;
        self.tombstone_count += 1;
        self.live_count -= 1;
    }

    fn isExpired(self: *KVStore, entry: *const Entry) bool {
        if (!entry.flags.has_ttl) return false;
        return self.nowMillis() > entry.expires_at;
    }
};

/// Minimal glob matcher supporting '*' (match any) and '?' (match one).
pub fn globMatch(pattern: []const u8, string: []const u8) bool {
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

