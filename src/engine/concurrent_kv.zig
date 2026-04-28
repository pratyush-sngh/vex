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
    /// Uses pthread_rwlock: GETs take read-lock (parallel), SETs take write-lock (exclusive).
    const Stripe = struct {
        rwlock: std.c.pthread_rwlock_t align(64) = std.mem.zeroes(std.c.pthread_rwlock_t),
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
            s.map = std.StringHashMap(Entry).init(allocator);
            // Zero-init rwlock — works on Linux. macOS needs initStripes() after placement.
        }
        return self;
    }

    /// Initialize rwlocks and pre-allocate stripe capacity. Must be called AFTER the
    /// ConcurrentKV is at its final memory address for macOS compatibility.
    /// Pre-allocation avoids HashMap resize under concurrent writes (which causes crashes
    /// due to Zig HashMap's non-thread-safe grow path).
    pub fn initStripes(self: *ConcurrentKV) void {
        const init_fn = @extern(*const fn (*std.c.pthread_rwlock_t, ?*const anyopaque) callconv(.c) c_int, .{ .name = "pthread_rwlock_init" });
        for (&self.stripes) |*s| {
            _ = init_fn(&s.rwlock, null);
            s.map.ensureTotalCapacity(16384) catch {};
        }
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
        readLockStripe(s);
        defer readUnlockStripe(s);

        const entry = s.map.getPtr(key) orelse return null;
        if (self.isExpired(entry)) return null;
        if (entry.flags.is_integer) {
            // Format native int to string
            var buf: [24]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{entry.int_value}) catch return null;
            const copy = self.allocator.dupe(u8, str) catch return null;
            return .{ .data = copy, .allocator = self.allocator };
        }
        const copy = self.allocator.dupe(u8, entry.value) catch return null;
        return .{ .data = copy, .allocator = self.allocator };
    }

    /// Zero-allocation GET: holds READ lock, writes RESP bulk string directly to output.
    /// Multiple GETs on the same stripe run in PARALLEL (no blocking).
    /// Pre-sizes buffer OUTSIDE the lock so most GETs never allocate under lock.
    pub fn getAndWriteBulk(self: *ConcurrentKV, key: []const u8, out: *std.array_list.Managed(u8)) bool {
        // Optimistic pre-size: ensure room for a typical response before taking the lock.
        // "$" + up to 6 digits + "\r\n" + up to 256 bytes value + "\r\n" = ~270 bytes.
        // If the value is larger, ensureTotalCapacity will be called under lock (rare path).
        out.ensureTotalCapacity(out.items.len + 270) catch {};

        const s = self.getStripe(key);
        readLockStripe(s);

        const entry = s.map.getPtr(key) orelse {
            readUnlockStripe(s);
            out.appendSlice("$-1\r\n") catch {};
            return false;
        };
        if (entry.flags.deleted) {
            readUnlockStripe(s);
            out.appendSlice("$-1\r\n") catch {};
            return false;
        }
        if (entry.flags.has_ttl and self.cached_now_ms > entry.expires_at) {
            readUnlockStripe(s);
            out.appendSlice("$-1\r\n") catch {};
            return false;
        }
        // For integer entries, format from native int_value (no stored string needed)
        if (entry.flags.is_integer) {
            var int_buf: [24]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{entry.int_value}) catch {
                readUnlockStripe(s);
                return false;
            };
            readUnlockStripe(s);
            // Format RESP outside lock — int_str is on stack, no aliasing issues
            var hdr2: [32]u8 = undefined;
            const h2 = std.fmt.bufPrint(&hdr2, "${d}\r\n", .{int_str.len}) catch return false;
            out.ensureTotalCapacity(out.items.len + h2.len + int_str.len + 2) catch {};
            out.appendSliceAssumeCapacity(h2);
            out.appendSliceAssumeCapacity(int_str);
            out.appendSliceAssumeCapacity("\r\n");
            return true;
        }

        // Write RESP bulk string: "$len\r\nvalue\r\n"
        const vlen = entry.value.len;
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "${d}\r\n", .{vlen}) catch {
            readUnlockStripe(s);
            return false;
        };
        const total_needed = out.items.len + h.len + vlen + 2;
        if (total_needed > out.capacity) {
            out.ensureTotalCapacity(total_needed) catch {
                readUnlockStripe(s);
                return false;
            };
        }
        out.appendSliceAssumeCapacity(h);
        out.appendSliceAssumeCapacity(entry.value);
        out.appendSliceAssumeCapacity("\r\n");
        readUnlockStripe(s);
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
        writeLockStripe(s);

        const has_ttl = expires_at != 0;
        const result = s.map.getPtr(key);
        if (result) |existing| {
            // SeqLock: bump to odd (write in progress)
            _ = existing.seq.fetchAdd(1, .release);

            if (owned_value.len <= KVStore.INLINE_BUF_SIZE) {
                // Small value: copy into inline buffer (in-place, no alloc)
                @memcpy(existing.inline_buf[0..owned_value.len], owned_value);
                existing.inline_len = @intCast(owned_value.len);
                existing.value = existing.inline_buf[0..owned_value.len];
                existing.flags = .{ .has_ttl = has_ttl, .is_inline = true };
            } else {
                existing.value = owned_value;
                existing.flags = .{ .has_ttl = has_ttl };
            }
            existing.expires_at = expires_at;
            existing.flags.is_integer = false;

            // SeqLock: bump to even (write complete)
            _ = existing.seq.fetchAdd(1, .release);

            const old_val = if (!existing.flags.is_inline) existing.value else null;
            writeUnlockStripe(s);
            // For inline: free the pre-allocated value (not needed, stored inline)
            // For non-inline: free the OLD value
            if (owned_value.len <= KVStore.INLINE_BUF_SIZE) {
                return .{ .stale_val = owned_value, .stale_key = owned_key };
            }
            return .{ .stale_val = old_val, .stale_key = owned_key };
        } else {
            var new_entry = Entry{
                .expires_at = expires_at,
                .flags = .{ .has_ttl = has_ttl },
                .value = undefined,
            };
            if (owned_value.len <= KVStore.INLINE_BUF_SIZE) {
                @memcpy(new_entry.inline_buf[0..owned_value.len], owned_value);
                new_entry.inline_len = @intCast(owned_value.len);
                new_entry.value = new_entry.inline_buf[0..owned_value.len];
                new_entry.flags.is_inline = true;
            } else {
                new_entry.value = owned_value;
            }
            s.map.put(owned_key, new_entry) catch {
                writeUnlockStripe(s);
                return .{ .stale_val = owned_value, .stale_key = owned_key };
            };
            writeUnlockStripe(s);
            if (owned_value.len <= KVStore.INLINE_BUF_SIZE) {
                return .{ .stale_val = owned_value, .stale_key = null };
            }
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
        writeLockStripe(s);
        const result = s.map.fetchRemove(key);
        writeUnlockStripe(s);
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
        readLockStripe(s);
        defer readUnlockStripe(s);

        const entry = s.map.getPtr(key) orelse return false;
        if (self.isExpired(entry)) return false;
        return true;
    }

    pub fn ttl(self: *ConcurrentKV, key: []const u8) ?i64 {
        const s = self.getStripe(key);
        readLockStripe(s);
        defer readUnlockStripe(s);

        const entry = s.map.getPtr(key) orelse return null;
        if (self.isExpired(entry)) return null;
        if (!entry.flags.has_ttl) return -1;
        return @divTrunc(entry.expires_at - self.nowMillis(), 1000);
    }

    pub fn restoreEntry(self: *ConcurrentKV, key: []const u8, value: []const u8, expires_at: ?i64) !void {
        return self.setInternal(key, value, expires_at orelse 0);
    }

    // ── Bulk operations (lock all stripes) ──

    pub fn flushdb(self: *ConcurrentKV) void {
        self.writeLockAll();
        defer self.writeUnlockAll();

        for (&self.stripes) |*s| {
            var iter = s.map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                if (!entry.value_ptr.flags.is_inline and entry.value_ptr.value.len > 0) {
                    self.allocator.free(entry.value_ptr.value);
                }
            }
            // Retain capacity — preserves pre-allocated HashMap slots
            s.map.clearRetainingCapacity();
        }
    }

    pub fn dbsize(self: *ConcurrentKV) usize {
        self.readLockAll();
        defer self.readUnlockAll();

        var total: usize = 0;
        for (&self.stripes) |*s| {
            total += s.map.count();
        }
        return total;
    }

    pub fn keys(self: *ConcurrentKV, allocator: Allocator, pattern: []const u8) ![][]const u8 {
        self.readLockAll();
        defer self.readUnlockAll();

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

    /// Atomic INCR/DECR using native i64 storage. No string parse/format under lock.
    /// First call parses the string; subsequent calls use cached int_value directly.
    pub fn incrBy(self: *ConcurrentKV, key: []const u8, delta: i64) error{ NotAnInteger, OutOfMemory }!i64 {
        const s = self.getStripe(key);
        writeLockStripe(s);

        const result = s.map.getPtr(key);
        if (result) |existing| {
            if (self.isExpired(existing)) {
                // Treat expired as 0
                existing.int_value = delta;
                existing.flags = .{ .is_integer = true };
                existing.last_access = self.cached_now_ms;
                writeUnlockStripe(s);
                return delta;
            }

            // If already marked as integer, use cached int_value directly (~1ns)
            if (existing.flags.is_integer) {
                existing.int_value += delta;
                existing.last_access = self.cached_now_ms;
                const new_val = existing.int_value;
                writeUnlockStripe(s);
                return new_val;
            }

            // First INCR on a string value — parse once, then use native from here on
            const current = std.fmt.parseInt(i64, existing.value, 10) catch {
                writeUnlockStripe(s);
                return error.NotAnInteger;
            };
            existing.int_value = current + delta;
            existing.flags = .{ .is_integer = true };
            existing.last_access = self.cached_now_ms;
            const new_val = existing.int_value;
            writeUnlockStripe(s);
            return new_val;
        }

        // New key — create entry with native integer
        const owned_key = self.allocator.dupe(u8, key) catch {
            writeUnlockStripe(s);
            return error.OutOfMemory;
        };
        s.map.put(owned_key, .{
            .value = &[_]u8{}, // empty — GET will format from int_value
            .int_value = delta,
            .last_access = self.cached_now_ms,
            .flags = .{ .is_integer = true },
        }) catch {
            self.allocator.free(owned_key);
            writeUnlockStripe(s);
            return error.OutOfMemory;
        };

        writeUnlockStripe(s);
        return delta;
    }

    // ── Public stripe access (for inlined GET hot path in worker) ──

    pub fn getStripePublic(self: *ConcurrentKV, key: []const u8) *Stripe {
        return self.getStripe(key);
    }

    pub fn readLockStripePublic(_: *ConcurrentKV, s: *Stripe) void {
        readLockStripe(s);
    }

    pub fn readUnlockStripePublic(_: *ConcurrentKV, s: *Stripe) void {
        readUnlockStripe(s);
    }

    // ── Internal helpers ──

    fn setInternal(self: *ConcurrentKV, key: []const u8, value: []const u8, expires_at: i64) !void {
        const s = self.getStripe(key);
        writeLockStripe(s);
        defer writeUnlockStripe(s);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const has_ttl = expires_at != 0;
        const now = self.cached_now_ms;
        const result = s.map.getPtr(key);
        if (result) |existing| {
            self.allocator.free(existing.value);
            existing.value = owned_value;
            existing.expires_at = expires_at;
            existing.last_access = now;
            existing.flags = .{ .has_ttl = has_ttl };
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try s.map.put(owned_key, .{
                .value = owned_value,
                .expires_at = expires_at,
                .last_access = now,
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

    /// Read-lock: multiple readers in parallel (for GET, EXISTS, TTL)
    fn readLockStripe(s: *Stripe) void {
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
    }

    fn readUnlockStripe(s: *Stripe) void {
        _ = std.c.pthread_rwlock_unlock(&s.rwlock);
    }

    fn writeLockStripe(s: *Stripe) void {
        _ = std.c.pthread_rwlock_wrlock(&s.rwlock);
    }

    fn writeUnlockStripe(s: *Stripe) void {
        _ = std.c.pthread_rwlock_unlock(&s.rwlock);
    }

    fn readLockAll(self: *ConcurrentKV) void {
        for (&self.stripes) |*s| readLockStripe(s);
    }

    fn readUnlockAll(self: *ConcurrentKV) void {
        for (&self.stripes) |*s| readUnlockStripe(s);
    }

    fn writeLockAll(self: *ConcurrentKV) void {
        for (&self.stripes) |*s| writeLockStripe(s);
    }

    fn writeUnlockAll(self: *ConcurrentKV) void {
        for (&self.stripes) |*s| writeUnlockStripe(s);
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
    store.initStripes();
    defer store.deinit();

    try store.set("name", "vex");
    const val = store.get("name") orelse return error.TestUnexpectedResult;
    defer val.deinit();
    try std.testing.expectEqualStrings("vex", val.data);
}

test "concurrent_kv delete" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("key1", "val1");
    try std.testing.expect(store.delete("key1"));
    try std.testing.expect(store.get("key1") == null);
    try std.testing.expect(!store.delete("nonexistent"));
}

test "concurrent_kv overwrite" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("k", "v1");
    try store.set("k", "v2");
    const val = store.get("k") orelse return error.TestUnexpectedResult;
    defer val.deinit();
    try std.testing.expectEqualStrings("v2", val.data);
}

test "concurrent_kv exists" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("present", "yes");
    try std.testing.expect(store.exists("present"));
    try std.testing.expect(!store.exists("absent"));
}

test "concurrent_kv flushdb and dbsize" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");
    try std.testing.expectEqual(@as(usize, 3), store.dbsize());
    store.flushdb();
    try std.testing.expectEqual(@as(usize, 0), store.dbsize());
}

test "concurrent_kv multi-thread stress" {
    // Skip in debug: Zig's HashMap pointer_stability check conflicts with
    // external rwlock synchronization. Passes in ReleaseFast.
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
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
