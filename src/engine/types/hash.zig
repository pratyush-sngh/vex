const std = @import("std");
const Allocator = std.mem.Allocator;
const probes = @import("../../observability/probes.zig");

const STRIPE_COUNT: usize = 32;
const STRIPE_MASK: usize = STRIPE_COUNT - 1;

/// Hash storage: maps key -> { field -> value }.
///
/// 32-stripe layout: each stripe owns its own rwlock + StringHashMap(FieldMap).
/// Concurrent HSET/HGET/HDEL on different keys take different stripes — no
/// coordination required. Replaces the old single-mutex + DsStripeLocks-lease
/// scheme; on the c=8 probe run the lease acquire alone cost ~300ns per op.
/// Per-stripe rwlock acquire on the common (uncontended) case is ~30ns.
pub const HashStore = struct {
    stripes: [STRIPE_COUNT]Stripe,
    allocator: Allocator,

    /// Cache-line aligned to keep adjacent stripes' locks on separate lines.
    const Stripe = struct {
        rwlock: std.c.pthread_rwlock_t align(64) = std.mem.zeroes(std.c.pthread_rwlock_t),
        map: std.StringHashMap(FieldMap),
    };

    /// Hashes with at least this many fields get a wire cache; smaller ones
    /// serialize directly (caching tiny replies costs more than it saves).
    const WIRE_CACHE_MIN_FIELDS: usize = 16;

    const FieldMap = struct {
        fields: std.StringHashMap([]u8),
        allocator: Allocator,
        /// Cached fully-serialized HGETALL replies (RESP2 / RESP3 forms).
        /// Built lazily under the stripe WRITE lock on first HGETALL of a
        /// large hash; any mutation frees them. Trades ~1x the hash's wire
        /// size in memory (while read-hot) for HGETALL becoming a single
        /// memcpy instead of a full map walk + per-element formatting.
        wire2: ?[]u8 = null,
        wire3: ?[]u8 = null,

        fn init(allocator: Allocator) FieldMap {
            return .{
                .fields = std.StringHashMap([]u8).init(allocator),
                .allocator = allocator,
            };
        }

        fn invalidateWire(self: *FieldMap) void {
            if (self.wire2) |w| {
                self.allocator.free(w);
                self.wire2 = null;
            }
            if (self.wire3) |w| {
                self.allocator.free(w);
                self.wire3 = null;
            }
        }

        /// Each field+value pair is stored in a single allocation laid out as
        /// `[field bytes][value bytes]`. `key_ptr` points at the field slice;
        /// `value_ptr` at the value slice. They share one underlying buffer,
        /// so freeing always goes through `key.ptr[0..key.len + value.len]`.
        fn freePair(self: *FieldMap, key: []const u8, value: []const u8) void {
            const total = key.len + value.len;
            self.allocator.free(@as([*]u8, @constCast(key.ptr))[0..total]);
        }

        fn deinit(self: *FieldMap) void {
            self.invalidateWire();
            var it = self.fields.iterator();
            while (it.next()) |entry| {
                self.freePair(entry.key_ptr.*, entry.value_ptr.*);
            }
            self.fields.deinit();
        }

        fn set(self: *FieldMap, field: []const u8, value: []const u8) !bool {
            self.invalidateWire();
            const probe_on = probes.isEnabled();
            const wp: ?*probes.WorkerProbes = if (probe_on) probes.current else null;

            const lookup_t0: u64 = if (wp != null) probes.start() else 0;
            const gop = try self.fields.getOrPut(field);
            if (wp) |p| probes.finish(&p.hset_fieldmap_lookup, lookup_t0);

            if (gop.found_existing) {
                const old_field = gop.key_ptr.*;
                const old_value = gop.value_ptr.*;
                const alloc_t0: u64 = if (wp != null) probes.start() else 0;
                const combined = try self.allocator.alloc(u8, field.len + value.len);
                @memcpy(combined[0..field.len], field);
                @memcpy(combined[field.len..], value);
                if (wp) |p| probes.finish(&p.hset_alloc_copy, alloc_t0);

                const free_t0: u64 = if (wp != null) probes.start() else 0;
                self.freePair(old_field, old_value);
                if (wp) |p| probes.finish(&p.hset_old_free, free_t0);

                gop.key_ptr.* = combined[0..field.len];
                gop.value_ptr.* = combined[field.len..];
                return false;
            } else {
                const alloc_t0: u64 = if (wp != null) probes.start() else 0;
                const combined = try self.allocator.alloc(u8, field.len + value.len);
                @memcpy(combined[0..field.len], field);
                @memcpy(combined[field.len..], value);
                if (wp) |p| probes.finish(&p.hset_alloc_copy, alloc_t0);

                gop.key_ptr.* = combined[0..field.len];
                gop.value_ptr.* = combined[field.len..];
                return true;
            }
        }

        fn remove(self: *FieldMap, field: []const u8) bool {
            const entry = self.fields.fetchRemove(field) orelse return false;
            self.invalidateWire();
            self.freePair(entry.key, entry.value);
            return true;
        }
    };

    pub fn init(allocator: Allocator) HashStore {
        var self: HashStore = .{
            .stripes = undefined,
            .allocator = allocator,
        };
        for (&self.stripes) |*s| {
            s.map = std.StringHashMap(FieldMap).init(allocator);
        }
        return self;
    }

    /// Initialize rwlocks. Must be called after the HashStore is at its final
    /// memory address (macOS rwlocks don't survive struct copy via init+return).
    pub fn initStripes(self: *HashStore) void {
        const init_fn = @extern(*const fn (*std.c.pthread_rwlock_t, ?*const anyopaque) callconv(.c) c_int, .{ .name = "pthread_rwlock_init" });
        for (&self.stripes) |*s| {
            _ = init_fn(&s.rwlock, null);
            s.map.ensureTotalCapacity(128) catch {};
        }
    }

    pub fn flush(self: *HashStore) void {
        for (&self.stripes) |*s| {
            _ = std.c.pthread_rwlock_wrlock(&s.rwlock);
            var it = s.map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
                self.allocator.free(entry.key_ptr.*);
            }
            s.map.clearRetainingCapacity();
            _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        }
    }

    pub fn deinit(self: *HashStore) void {
        self.flush();
        for (&self.stripes) |*s| {
            s.map.deinit();
            _ = std.c.pthread_rwlock_destroy(&s.rwlock);
        }
    }

    inline fn stripeOf(self: *HashStore, key: []const u8) *Stripe {
        // FNV-1a 32-bit — same hash family as DsStripeLocks.stripeIndex.
        var h: u32 = 0x811c9dc5;
        for (key) |b| {
            h ^= b;
            h *%= 0x01000193;
        }
        return &self.stripes[@as(usize, h) & STRIPE_MASK];
    }

    /// HSET key field value [field value ...] — set fields, returns count of NEW fields added.
    pub fn hset(self: *HashStore, key: []const u8, field_values: []const []const u8) !usize {
        const probe_on = probes.isEnabled();
        const wp: ?*probes.WorkerProbes = if (probe_on) probes.current else null;

        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_wrlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);

        const goc_t0: u64 = if (wp != null) probes.start() else 0;
        const fm = try getOrCreateInStripe(s, self.allocator, key);
        if (wp) |p| probes.finish(&p.hset_get_or_create, goc_t0);

        var new_count: usize = 0;
        var i: usize = 0;
        while (i + 1 < field_values.len) : (i += 2) {
            if (try fm.set(field_values[i], field_values[i + 1])) new_count += 1;
        }
        return new_count;
    }

    /// HGET key field — get a single field value.
    /// NOTE: returns a slice into the stripe's storage. Caller must finish
    /// using the slice before releasing the rdlock. For the worker hot path
    /// the slice is immediately memcpy'd into the connection's write buffer.
    pub fn hget(self: *HashStore, key: []const u8, field: []const u8) ?[]const u8 {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return null;
        return fm.fields.get(field);
    }

    /// HDEL key field [field ...] — delete fields, returns count deleted.
    pub fn hdel(self: *HashStore, key: []const u8, fields: []const []const u8) usize {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_wrlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return 0;
        var count: usize = 0;
        for (fields) |field| {
            if (fm.remove(field)) count += 1;
        }
        if (fm.fields.count() == 0) {
            if (s.map.fetchRemove(key)) |entry| {
                var v = entry.value;
                v.deinit();
                self.allocator.free(entry.key);
            }
        }
        return count;
    }

    /// HGETALL key — serialize the full RESP reply directly into `out`.
    /// Field/value bytes are only read while a stripe lock is held, so a
    /// concurrent HSET/HDEL can't free them mid-copy. Exact-sized: on OOM
    /// nothing has been appended (no torn reply), and the reply is never
    /// truncated regardless of field/value sizes.
    /// `resp3` selects the map header (`%N`) over the flat-array header (`*2N`).
    ///
    /// Large hashes (≥ WIRE_CACHE_MIN_FIELDS) cache the serialized reply on
    /// the FieldMap: the common read-hot case is one rdlock + one memcpy.
    /// The cache is built under the stripe WRITE lock (so installing the
    /// pointer can't race other readers) and freed by any mutation.
    pub fn hgetallWrite(self: *HashStore, key: []const u8, out: *std.array_list.Managed(u8), resp3: bool) !void {
        const empty_hdr: []const u8 = if (resp3) "%0\r\n" else "*0\r\n";
        const s = self.stripeOf(key);

        // Read path: cached reply, or direct serialization for small hashes.
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        var need_cache_build = false;
        {
            defer if (!need_cache_build) {
                _ = std.c.pthread_rwlock_unlock(&s.rwlock);
            };
            const fm = s.map.getPtr(key) orelse return out.appendSlice(empty_hdr);
            if (if (resp3) fm.wire3 else fm.wire2) |wire| return out.appendSlice(wire);
            const count = fm.fields.count();
            if (count == 0) return out.appendSlice(empty_hdr);
            if (count < WIRE_CACHE_MIN_FIELDS) return serializeAll(fm, out, resp3, count);
            need_cache_build = true;
        }
        _ = std.c.pthread_rwlock_unlock(&s.rwlock);

        // Large hash, no cache yet: build it under the write lock. Recheck
        // everything — the world may have changed between the locks.
        _ = std.c.pthread_rwlock_wrlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return out.appendSlice(empty_hdr);
        const count = fm.fields.count();
        if (count == 0) return out.appendSlice(empty_hdr);
        const slot = if (resp3) &fm.wire3 else &fm.wire2;
        if (slot.* == null and count >= WIRE_CACHE_MIN_FIELDS) {
            slot.* = try buildWire(fm, self.allocator, resp3, count);
        }
        if (slot.*) |wire| return out.appendSlice(wire);
        return serializeAll(fm, out, resp3, count);
    }

    /// Serialize the full HGETALL reply for `fm` into `out` (two passes:
    /// exact size, reserve once, append). Caller must hold a stripe lock.
    fn serializeAll(fm: *FieldMap, out: *std.array_list.Managed(u8), resp3: bool, count: usize) !void {
        var hdr_buf: [24]u8 = undefined;
        const hdr = if (resp3)
            std.fmt.bufPrint(&hdr_buf, "%{d}\r\n", .{count}) catch unreachable
        else
            std.fmt.bufPrint(&hdr_buf, "*{d}\r\n", .{count * 2}) catch unreachable;

        var total: usize = hdr.len;
        var it = fm.fields.iterator();
        while (it.next()) |entry| {
            total += bulkWireLen(entry.key_ptr.len) + bulkWireLen(entry.value_ptr.len);
        }
        try out.ensureUnusedCapacity(total);

        out.appendSliceAssumeCapacity(hdr);
        it = fm.fields.iterator();
        while (it.next()) |entry| {
            appendBulkAssumeCapacity(out, entry.key_ptr.*);
            appendBulkAssumeCapacity(out, entry.value_ptr.*);
        }
    }

    /// Build the exact-sized serialized HGETALL reply as one owned buffer.
    /// Caller must hold the stripe write lock.
    fn buildWire(fm: *FieldMap, allocator: Allocator, resp3: bool, count: usize) ![]u8 {
        var hdr_buf: [24]u8 = undefined;
        const hdr = if (resp3)
            std.fmt.bufPrint(&hdr_buf, "%{d}\r\n", .{count}) catch unreachable
        else
            std.fmt.bufPrint(&hdr_buf, "*{d}\r\n", .{count * 2}) catch unreachable;

        var total: usize = hdr.len;
        var it = fm.fields.iterator();
        while (it.next()) |entry| {
            total += bulkWireLen(entry.key_ptr.len) + bulkWireLen(entry.value_ptr.len);
        }

        const buf = try allocator.alloc(u8, total);
        var pos: usize = 0;
        @memcpy(buf[pos .. pos + hdr.len], hdr);
        pos += hdr.len;
        it = fm.fields.iterator();
        while (it.next()) |entry| {
            pos = writeBulkAt(buf, pos, entry.key_ptr.*);
            pos = writeBulkAt(buf, pos, entry.value_ptr.*);
        }
        std.debug.assert(pos == total);
        return buf;
    }

    fn writeBulkAt(buf: []u8, pos0: usize, bytes: []const u8) usize {
        var pos = pos0;
        const h = std.fmt.bufPrint(buf[pos..], "${d}\r\n", .{bytes.len}) catch unreachable;
        pos += h.len;
        @memcpy(buf[pos .. pos + bytes.len], bytes);
        pos += bytes.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        return pos + 2;
    }

    /// HGETALL serialized to a std.Io.Writer under the stripe read lock.
    /// Slow-path (command handler) twin of `hgetallWrite`. Uses the wire
    /// cache when present but never builds it (this path is cold).
    pub fn hgetallWriteIo(self: *HashStore, key: []const u8, w: *std.Io.Writer, resp3: bool) !void {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return w.writeAll(if (resp3) "%0\r\n" else "*0\r\n");
        if (if (resp3) fm.wire3 else fm.wire2) |wire| return w.writeAll(wire);
        const count = fm.fields.count();
        if (resp3) try w.print("%{d}\r\n", .{count}) else try w.print("*{d}\r\n", .{count * 2});
        var it = fm.fields.iterator();
        while (it.next()) |entry| {
            try writeBulkIo(w, entry.key_ptr.*);
            try writeBulkIo(w, entry.value_ptr.*);
        }
    }

    fn bulkWireLen(n: usize) usize {
        // "$<digits>\r\n<bytes>\r\n"
        return 1 + decimalDigits(n) + 2 + n + 2;
    }

    fn decimalDigits(n0: usize) usize {
        var n = n0;
        var d: usize = 1;
        while (n >= 10) : (n /= 10) d += 1;
        return d;
    }

    fn appendBulkAssumeCapacity(out: *std.array_list.Managed(u8), bytes: []const u8) void {
        var len_buf: [24]u8 = undefined;
        const h = std.fmt.bufPrint(&len_buf, "${d}\r\n", .{bytes.len}) catch unreachable;
        out.appendSliceAssumeCapacity(h);
        out.appendSliceAssumeCapacity(bytes);
        out.appendSliceAssumeCapacity("\r\n");
    }

    fn writeBulkIo(w: *std.Io.Writer, bytes: []const u8) !void {
        try w.print("${d}\r\n", .{bytes.len});
        try w.writeAll(bytes);
        try w.writeAll("\r\n");
    }

    pub fn hlen(self: *HashStore, key: []const u8) usize {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return 0;
        return fm.fields.count();
    }

    pub fn hexists(self: *HashStore, key: []const u8, field: []const u8) bool {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return false;
        return fm.fields.contains(field);
    }

    /// HKEYS serialized to a std.Io.Writer under the stripe read lock —
    /// same race-safety rationale as `hgetallWriteIo`.
    pub fn hkeysWriteIo(self: *HashStore, key: []const u8, w: *std.Io.Writer) !void {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return w.writeAll("*0\r\n");
        try w.print("*{d}\r\n", .{fm.fields.count()});
        var it = fm.fields.iterator();
        while (it.next()) |entry| try writeBulkIo(w, entry.key_ptr.*);
    }

    /// HVALS serialized to a std.Io.Writer under the stripe read lock.
    pub fn hvalsWriteIo(self: *HashStore, key: []const u8, w: *std.Io.Writer) !void {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = s.map.getPtr(key) orelse return w.writeAll("*0\r\n");
        try w.print("*{d}\r\n", .{fm.fields.count()});
        var it = fm.fields.iterator();
        while (it.next()) |entry| try writeBulkIo(w, entry.value_ptr.*);
    }

    pub fn hincrby(self: *HashStore, key: []const u8, field: []const u8, delta: i64) !i64 {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_wrlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        const fm = try getOrCreateInStripe(s, self.allocator, key);
        var current: i64 = 0;
        if (fm.fields.get(field)) |val| {
            current = std.fmt.parseInt(i64, val, 10) catch return error.NotAnInteger;
        }
        const new_val = current + delta;
        var buf: [32]u8 = undefined;
        const ss = std.fmt.bufPrint(&buf, "{d}", .{new_val}) catch return error.InternalError;
        _ = try fm.set(field, ss);
        return new_val;
    }

    pub fn exists(self: *HashStore, key: []const u8) bool {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_rdlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        return s.map.contains(key);
    }

    pub fn delete(self: *HashStore, key: []const u8) bool {
        const s = self.stripeOf(key);
        _ = std.c.pthread_rwlock_wrlock(&s.rwlock);
        defer _ = std.c.pthread_rwlock_unlock(&s.rwlock);
        var entry = s.map.fetchRemove(key) orelse return false;
        entry.value.deinit();
        self.allocator.free(entry.key);
        return true;
    }

    /// Caller must hold the stripe's wrlock.
    fn getOrCreateInStripe(s: *Stripe, allocator: Allocator, key: []const u8) !*FieldMap {
        if (s.map.getPtr(key)) |existing| return existing;
        const gop = try s.map.getOrPut(key);
        gop.key_ptr.* = try allocator.dupe(u8, key);
        var fm = FieldMap.init(allocator);
        fm.fields.ensureTotalCapacity(32) catch {};
        gop.value_ptr.* = fm;
        return gop.value_ptr;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────
