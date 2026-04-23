const std = @import("std");
const Allocator = std.mem.Allocator;
const KVStore = @import("kv.zig").KVStore;

const STRIPE_COUNT = 256;
const STRIPE_MASK = STRIPE_COUNT - 1;

/// Thread-safe KV store using bucket-striped locking.
/// 256 stripes, each with its own mutex + HashMap.
/// Any thread can access any key with minimal contention.
pub const ConcurrentKV = struct {
    stripes: [STRIPE_COUNT]Stripe,
    allocator: Allocator,
    io: std.Io,
    cached_now_ms: i64 = 0,

    pub const Entry = KVStore.Entry;

    /// Cache-line aligned to prevent false sharing between workers.
    /// Without alignment, two adjacent stripes share a cache line and
    /// CAS operations bounce that line between cores (~30-60ns per bounce).
    const Stripe = struct {
        mutex: std.atomic.Mutex align(64),
        map: std.StringHashMap(Entry),
        ttl_count: u32 = 0,
        tombstone_count: u32 = 0,
    };

    /// Owned value returned by get(). Caller must call deinit() to free.
    pub const OwnedValue = struct {
        data: []const u8,
        allocator: Allocator,

        pub fn deinit(self: OwnedValue) void {
            self.allocator.free(self.data);
        }
    };

    pub fn init(allocator: Allocator, io: std.Io) ConcurrentKV {
        var self: ConcurrentKV = .{
            .stripes = undefined,
            .allocator = allocator,
            .io = io,
        };
        for (&self.stripes) |*s| {
            s.* = .{
                .mutex = .unlocked,
                .map = std.StringHashMap(Entry).init(allocator),
            };
        }
        return self;
    }

    pub fn deinit(self: *ConcurrentKV) void {
        for (&self.stripes) |*s| {
            var iter = s.map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.value);
            }
            s.map.deinit();
        }
    }

    /// Import all entries from an existing KVStore (single-threaded, at startup).
    pub fn importFrom(self: *ConcurrentKV, source: *KVStore) !void {
        var iter = source.map.iterator();
        while (iter.next()) |entry| {
            const idx = stripeIndex(entry.key_ptr.*);
            const s = &self.stripes[idx];
            const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(owned_key);
            const owned_val = try self.allocator.dupe(u8, entry.value_ptr.value);
            errdefer self.allocator.free(owned_val);
            if (entry.value_ptr.flags.deleted) continue; // skip tombstones
            try s.map.put(owned_key, .{
                .value = owned_val,
                .expires_at = entry.value_ptr.expires_at,
                .flags = entry.value_ptr.flags,
            });
        }
    }

    // ── Single-key operations (lock one stripe) ──

    pub fn get(self: *ConcurrentKV, key: []const u8) ?OwnedValue {
        const s = self.getStripe(key);
        lockStripe(s);
        defer unlockStripe(s);

        const entry = s.map.getPtr(key) orelse return null;
        if (self.isExpired(entry)) {
            self.evictLocked(s, key);
            return null;
        }
        const copy = self.allocator.dupe(u8, entry.value) catch return null;
        return .{ .data = copy, .allocator = self.allocator };
    }

    /// Zero-allocation GET: holds stripe lock, writes RESP bulk string directly to output.
    /// Returns true if key existed (response written), false if miss ($-1 written).
    pub fn getAndWriteBulk(self: *ConcurrentKV, key: []const u8, out: *std.array_list.Managed(u8)) bool {
        const s = self.getStripe(key);
        lockStripe(s);
        defer unlockStripe(s);

        const entry = s.map.getPtr(key) orelse {
            out.appendSlice("$-1\r\n") catch {};
            return false;
        };
        if (entry.flags.deleted) {
            out.appendSlice("$-1\r\n") catch {};
            return false;
        }
        if (entry.flags.has_ttl and self.cached_now_ms > entry.expires_at) {
            self.evictLocked(s, key);
            out.appendSlice("$-1\r\n") catch {};
            return false;
        }
        // Write RESP bulk string: "$len\r\nvalue\r\n"
        // Pre-allocate total needed to avoid multiple capacity checks
        const vlen = entry.value.len;
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "${d}\r\n", .{vlen}) catch return false;
        out.ensureTotalCapacity(out.items.len + h.len + vlen + 2) catch {};
        out.appendSliceAssumeCapacity(h);
        out.appendSliceAssumeCapacity(entry.value);
        out.appendSliceAssumeCapacity("\r\n");
        return true;
    }

    pub fn set(self: *ConcurrentKV, key: []const u8, value: []const u8) !void {
        return self.setInternal(key, value, 0);
    }

    /// SET with pre-allocated key+value. Caller provides owned memory.
    /// ConcurrentKV takes ownership. Old value freed OUTSIDE the lock.
    /// On insert, owned_key is used. On update, owned_key is freed by caller
    /// (returned as stale_key).
    pub fn setPrealloc(
        self: *ConcurrentKV,
        key: []const u8,
        owned_key: []u8,
        owned_value: []u8,
        expires_at: i64,
    ) struct { stale_val: ?[]const u8, stale_key: ?[]const u8 } {
        const s = self.getStripe(key);
        lockStripe(s);

        const has_ttl = expires_at != 0;
        const result = s.map.getPtr(key);
        if (result) |existing| {
            const old_val = existing.value;
            existing.value = owned_value;
            existing.expires_at = expires_at;
            existing.flags = .{ .has_ttl = has_ttl };
            unlockStripe(s);
            // Free old value + unused key OUTSIDE lock
            return .{ .stale_val = old_val, .stale_key = owned_key };
        } else {
            s.map.put(owned_key, .{
                .value = owned_value,
                .expires_at = expires_at,
                .flags = .{ .has_ttl = has_ttl },
            }) catch {
                unlockStripe(s);
                return .{ .stale_val = owned_value, .stale_key = owned_key };
            };
            unlockStripe(s);
            return .{ .stale_val = null, .stale_key = null };
        }
    }

    pub fn setEx(self: *ConcurrentKV, key: []const u8, value: []const u8, ttl_seconds: i64) !void {
        const expires = self.nowMillis() + ttl_seconds * 1000;
        return self.setInternal(key, value, expires);
    }

    pub fn setPx(self: *ConcurrentKV, key: []const u8, value: []const u8, ttl_millis: i64) !void {
        return self.setInternal(key, value, self.nowMillis() + ttl_millis);
    }

    /// Delete a key. Returns stale key+value for caller to free OUTSIDE any lock.
    pub fn deleteStale(self: *ConcurrentKV, key: []const u8) struct { found: bool, stale_key: ?[]const u8, stale_val: ?[]const u8 } {
        const s = self.getStripe(key);
        lockStripe(s);
        const result = s.map.fetchRemove(key);
        unlockStripe(s);
        if (result) |kv| {
            return .{ .found = true, .stale_key = kv.key, .stale_val = kv.value.value };
        }
        return .{ .found = false, .stale_key = null, .stale_val = null };
    }

    pub fn delete(self: *ConcurrentKV, key: []const u8) bool {
        const stale = self.deleteStale(key);
        if (stale.stale_key) |k| self.allocator.free(k);
        if (stale.stale_val) |v| self.allocator.free(v);
        return stale.found;
    }

    pub fn exists(self: *ConcurrentKV, key: []const u8) bool {
        const s = self.getStripe(key);
        lockStripe(s);
        defer unlockStripe(s);

        const entry = s.map.getPtr(key) orelse return false;
        if (self.isExpired(entry)) {
            self.evictLocked(s, key);
            return false;
        }
        return true;
    }

    pub fn ttl(self: *ConcurrentKV, key: []const u8) ?i64 {
        const s = self.getStripe(key);
        lockStripe(s);
        defer unlockStripe(s);

        const entry = s.map.getPtr(key) orelse return null;
        if (self.isExpired(entry)) {
            self.evictLocked(s, key);
            return null;
        }
        if (!entry.flags.has_ttl) return -1;
        return @divTrunc(entry.expires_at - self.nowMillis(), 1000);
    }

    pub fn restoreEntry(self: *ConcurrentKV, key: []const u8, value: []const u8, expires_at: ?i64) !void {
        return self.setInternal(key, value, expires_at orelse 0);
    }

    // ── Bulk operations (lock all stripes) ──

    pub fn flushdb(self: *ConcurrentKV) void {
        self.lockAll();
        defer self.unlockAll();

        for (&self.stripes) |*s| {
            var iter = s.map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.value);
            }
            s.map.clearAndFree();
        }
    }

    pub fn dbsize(self: *ConcurrentKV) usize {
        self.lockAll();
        defer self.unlockAll();

        var total: usize = 0;
        for (&self.stripes) |*s| {
            total += s.map.count();
        }
        return total;
    }

    pub fn keys(self: *ConcurrentKV, allocator: Allocator, pattern: []const u8) ![][]const u8 {
        self.lockAll();
        defer self.unlockAll();

        var result = std.array_list.Managed([]const u8).init(allocator);
        errdefer result.deinit();

        const match_all = std.mem.eql(u8, pattern, "*");
        for (&self.stripes) |*s| {
            var iter = s.map.iterator();
            while (iter.next()) |entry| {
                if (match_all or globMatch(pattern, entry.key_ptr.*)) {
                    try result.append(entry.key_ptr.*);
                }
            }
        }
        return result.toOwnedSlice();
    }

    // ── Internal helpers ──

    fn setInternal(self: *ConcurrentKV, key: []const u8, value: []const u8, expires_at: i64) !void {
        const s = self.getStripe(key);
        lockStripe(s);
        defer unlockStripe(s);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const has_ttl = expires_at != 0;
        const result = s.map.getPtr(key);
        if (result) |existing| {
            self.allocator.free(existing.value);
            existing.value = owned_value;
            existing.expires_at = expires_at;
            existing.flags = .{ .has_ttl = has_ttl };
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try s.map.put(owned_key, .{
                .value = owned_value,
                .expires_at = expires_at,
                .flags = .{ .has_ttl = has_ttl },
            });
        }
    }

    fn stripeIndex(key: []const u8) usize {
        return @as(usize, std.hash.Wyhash.hash(0, key)) & STRIPE_MASK;
    }

    fn getStripe(self: *ConcurrentKV, key: []const u8) *Stripe {
        return &self.stripes[stripeIndex(key)];
    }

    fn lockStripe(s: *Stripe) void {
        if (s.mutex.tryLock()) return;
        // Contended: spin 4 times then yield
        var spin: u32 = 0;
        while (!s.mutex.tryLock()) {
            if (spin < 4) {
                std.atomic.spinLoopHint();
                spin += 1;
            } else {
                std.Thread.yield() catch {};
                spin = 0;
            }
        }
    }

    fn unlockStripe(s: *Stripe) void {
        s.mutex.unlock();
    }

    fn lockAll(self: *ConcurrentKV) void {
        for (&self.stripes) |*s| lockStripe(s);
    }

    fn unlockAll(self: *ConcurrentKV) void {
        for (&self.stripes) |*s| unlockStripe(s);
    }

    /// Update cached clock. Call once per event loop tick.
    pub fn updateClock(self: *ConcurrentKV) void {
        self.cached_now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    }

    pub fn nowMillis(self: *const ConcurrentKV) i64 {
        return self.cached_now_ms;
    }

    fn isExpired(self: *const ConcurrentKV, entry: *const Entry) bool {
        if (!entry.flags.has_ttl) return false;
        return self.cached_now_ms > entry.expires_at;
    }

    /// Remove an expired entry while the stripe is already locked.
    fn evictLocked(self: *ConcurrentKV, s: *Stripe, key: []const u8) void {
        const result = s.map.fetchRemove(key);
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

test "concurrent_kv basic set/get" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("name", "vex");
    const val = store.get("name") orelse return error.TestUnexpectedResult;
    defer val.deinit();
    try std.testing.expectEqualStrings("vex", val.data);
}

test "concurrent_kv delete" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("key1", "val1");
    try std.testing.expect(store.delete("key1"));
    try std.testing.expect(store.get("key1") == null);
    try std.testing.expect(!store.delete("nonexistent"));
}

test "concurrent_kv overwrite" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("k", "v1");
    try store.set("k", "v2");
    const val = store.get("k") orelse return error.TestUnexpectedResult;
    defer val.deinit();
    try std.testing.expectEqualStrings("v2", val.data);
}

test "concurrent_kv exists" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("present", "yes");
    try std.testing.expect(store.exists("present"));
    try std.testing.expect(!store.exists("absent"));
}

test "concurrent_kv flushdb and dbsize" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");
    try std.testing.expectEqual(@as(usize, 3), store.dbsize());
    store.flushdb();
    try std.testing.expectEqual(@as(usize, 0), store.dbsize());
}

test "concurrent_kv multi-thread stress" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    const num_threads = 8;
    const ops_per_thread = 1000;

    const Worker = struct {
        fn run(s: *ConcurrentKV, thread_id: usize) void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "t{d}:k{d}", .{ thread_id, i }) catch continue;
                var val_buf: [32]u8 = undefined;
                const val = std.fmt.bufPrint(&val_buf, "v{d}", .{i}) catch continue;

                s.set(key, val) catch continue;
                if (s.get(key)) |v| v.deinit();
                _ = s.exists(key);
                _ = s.delete(key);
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |t| {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &store, t });
    }
    for (&threads) |thread| {
        thread.join();
    }

    // Should not crash or leak (testing allocator checks leaks on deinit)
}
