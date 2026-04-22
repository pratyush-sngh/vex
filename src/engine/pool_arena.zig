const std = @import("std");
const Allocator = std.mem.Allocator;

/// High-performance memory pool with size-class free lists and arena bump
/// allocation. Designed for KV and graph value storage where alloc/free
/// frequency is very high.
///
/// Allocation order: free list (recycled, ~3ns) → arena bump (~2ns) →
///   standby arena swap (~5ns) → fallback to backing allocator (~60ns).
///
/// Released blocks go back to free lists for instant reuse.
/// Background refiller pre-allocates the next arena when current runs low.
pub const PoolArena = struct {
    const Self = @This();

    pub const DEFAULT_CLASSES = [_]u32{ 32, 64, 128, 256, 512, 1024, 4096 };
    pub const DEFAULT_ARENA_SIZE: usize = 10 * 1024 * 1024; // 10MB
    pub const DEFAULT_LOW_WATERMARK: usize = 1 * 1024 * 1024; // 1MB
    pub const DEFAULT_FREE_LIST_CAP: u32 = 4096;

    pub const Config = struct {
        classes: []const u32 = &DEFAULT_CLASSES,
        arena_size: usize = DEFAULT_ARENA_SIZE,
        low_watermark: usize = DEFAULT_LOW_WATERMARK,
        free_list_cap: u32 = DEFAULT_FREE_LIST_CAP,
        enable_background_refill: bool = true,
    };

    /// Returned from alloc(). `buf` is the usable slice (requested len).
    /// `block_size` is the actual allocated size (class size) — pass to release().
    pub const Allocation = struct {
        buf: []u8,
        block_size: u32,
    };

    const FreeBlock = struct {
        next: ?*FreeBlock,
    };

    const FreeList = struct {
        head: ?*FreeBlock = null,
        count: u32 = 0,
    };

    const ArenaBlock = struct {
        buf: []u8,
    };

    // ── Configuration ──
    config: Config,
    num_classes: usize,
    class_sizes: [16]u32, // max 16 size classes

    // ── Free lists (one per size class) ──
    free_lists: [16]FreeList,

    // ── Arena bump allocator ──
    current_arena: []u8,
    arena_pos: usize,
    standby_arena: ?[]u8,

    // ── Retired arenas (values still point into them) ──
    retired: std.array_list.Managed(ArenaBlock),

    // ── Background refiller ──
    refill_thread: ?std.Thread,
    refill_requested: std.atomic.Value(bool),
    shutdown: std.atomic.Value(bool),

    // ── Stats ──
    total_allocs: u64,
    free_list_hits: u64,
    arena_bumps: u64,
    arena_switches: u32,
    fallback_allocs: u64,

    // ── Backing ──
    backing: Allocator,

    pub fn init(backing: Allocator, config: Config) !Self {
        const arena = try backing.alloc(u8, config.arena_size);
        prefaultPages(arena);

        var self = Self{
            .config = config,
            .num_classes = @min(config.classes.len, 16),
            .class_sizes = undefined,
            .free_lists = [_]FreeList{.{}} ** 16,
            .current_arena = arena,
            .arena_pos = 0,
            .standby_arena = null,
            .retired = std.array_list.Managed(ArenaBlock).init(backing),
            .refill_thread = null,
            .refill_requested = std.atomic.Value(bool).init(false),
            .shutdown = std.atomic.Value(bool).init(false),
            .total_allocs = 0,
            .free_list_hits = 0,
            .arena_bumps = 0,
            .arena_switches = 0,
            .fallback_allocs = 0,
            .backing = backing,
        };

        for (0..self.num_classes) |i| {
            self.class_sizes[i] = config.classes[i];
        }

        return self;
    }

    /// Start the background refiller thread. Optional — works without it
    /// but the hot path may occasionally hit fallback malloc.
    pub fn startRefiller(self: *Self) !void {
        if (self.refill_thread != null) return;
        self.refill_thread = try std.Thread.spawn(.{}, refillerLoop, .{self});
    }

    /// Stop the background refiller thread.
    pub fn stopRefiller(self: *Self) void {
        if (self.refill_thread) |t| {
            self.shutdown.store(true, .release);
            self.refill_requested.store(true, .release);
            t.join();
            self.refill_thread = null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.stopRefiller();

        // Free all free list blocks (only non-arena ones need individual free)
        for (0..self.num_classes) |i| {
            var node = self.free_lists[i].head;
            while (node) |n| {
                const next = n.next;
                const block_ptr: [*]u8 = @ptrCast(n);
                if (!self.isInArena(block_ptr)) {
                    self.backing.free(block_ptr[0..self.class_sizes[i]]);
                }
                node = next;
            }
        }

        self.backing.free(self.current_arena);
        if (self.standby_arena) |s| self.backing.free(s);

        for (self.retired.items) |ab| {
            self.backing.free(ab.buf);
        }
        self.retired.deinit();
    }

    /// Allocate at least `len` bytes. Returns an Allocation with the usable
    /// slice and the actual block_size (needed for release).
    /// Hot path: free list pop (~3ns) or arena bump (~2ns).
    pub fn alloc(self: *Self, len: usize) !Allocation {
        if (len == 0) return .{ .buf = &.{}, .block_size = 0 };

        self.total_allocs += 1;

        const class = self.classFor(len);
        const block_size: u32 = if (class < self.num_classes) self.class_sizes[class] else @intCast(len);

        // 1. Try free list for matching size class
        if (class < self.num_classes) {
            const fl = &self.free_lists[class];
            if (fl.head) |block| {
                fl.head = block.next;
                fl.count -= 1;
                self.free_list_hits += 1;
                return .{
                    .buf = @as([*]u8, @ptrCast(block))[0..len],
                    .block_size = block_size,
                };
            }
        }

        // 2. Try bump-allocate from current arena
        const aligned = std.mem.alignForward(usize, block_size, 8);

        if (self.arena_pos + aligned <= self.current_arena.len) {
            const result = self.current_arena[self.arena_pos..][0..len];
            self.arena_pos += aligned;
            self.arena_bumps += 1;

            const remaining = self.current_arena.len - self.arena_pos;
            if (remaining < self.config.low_watermark and self.standby_arena == null) {
                self.refill_requested.store(true, .release);
            }
            return .{ .buf = result, .block_size = block_size };
        }

        // 3. Arena full — swap to standby
        if (self.standby_arena) |standby| {
            try self.retired.append(.{ .buf = self.current_arena });
            self.current_arena = standby;
            self.standby_arena = null;
            self.arena_pos = 0;
            self.arena_switches += 1;
            self.refill_requested.store(true, .release);
            return self.alloc(len);
        }

        // 4. Fallback to backing allocator
        self.fallback_allocs += 1;
        const buf = try self.backing.alloc(u8, block_size);
        return .{ .buf = buf[0..len], .block_size = block_size };
    }

    /// Release a block back to the free list for reuse.
    /// `block_size` must be the value from the Allocation returned by alloc().
    /// `ptr` is the .buf.ptr from the allocation.
    pub fn release(self: *Self, ptr: [*]u8, block_size: u32) void {
        if (block_size == 0) return;

        const class = self.classFor(block_size);
        if (class < self.num_classes) {
            const fl = &self.free_lists[class];
            if (fl.count < self.config.free_list_cap) {
                const block: *FreeBlock = @ptrCast(@alignCast(ptr));
                block.next = fl.head;
                fl.head = block;
                fl.count += 1;
                return;
            }
        }

        // Free list full or oversized — only free if not in an arena
        if (!self.isInArena(ptr)) {
            self.backing.free(ptr[0..block_size]);
        }
    }

    /// Find the size class index for a given length.
    fn classFor(self: *const Self, len: usize) usize {
        for (0..self.num_classes) |i| {
            if (len <= self.class_sizes[i]) return i;
        }
        return self.num_classes;
    }

    /// Check if a pointer falls within any arena.
    fn isInArena(self: *const Self, ptr: [*]u8) bool {
        const addr = @intFromPtr(ptr);
        const cur_start = @intFromPtr(self.current_arena.ptr);
        if (addr >= cur_start and addr < cur_start + self.current_arena.len) return true;

        if (self.standby_arena) |s| {
            const s_start = @intFromPtr(s.ptr);
            if (addr >= s_start and addr < s_start + s.len) return true;
        }

        for (self.retired.items) |ab| {
            const r_start = @intFromPtr(ab.buf.ptr);
            if (addr >= r_start and addr < r_start + ab.buf.len) return true;
        }
        return false;
    }

    fn prefaultPages(buf: []u8) void {
        var i: usize = 0;
        while (i < buf.len) : (i += 4096) {
            buf[i] = 0;
        }
    }

    fn refillerLoop(self: *Self) void {
        while (!self.shutdown.load(.acquire)) {
            while (!self.refill_requested.load(.acquire)) {
                if (self.shutdown.load(.acquire)) return;
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
            self.refill_requested.store(false, .release);

            if (self.standby_arena == null) {
                const arena = self.backing.alloc(u8, self.config.arena_size) catch continue;
                prefaultPages(arena);
                self.standby_arena = arena;
            }
        }
    }

    pub fn stats(self: *const Self) Stats {
        var free_list_total: u32 = 0;
        for (0..self.num_classes) |i| {
            free_list_total += self.free_lists[i].count;
        }
        return .{
            .total_allocs = self.total_allocs,
            .free_list_hits = self.free_list_hits,
            .arena_bumps = self.arena_bumps,
            .arena_switches = self.arena_switches,
            .fallback_allocs = self.fallback_allocs,
            .arena_remaining = self.current_arena.len - self.arena_pos,
            .retired_arenas = @intCast(self.retired.items.len),
            .free_list_blocks = free_list_total,
        };
    }

    pub const Stats = struct {
        total_allocs: u64,
        free_list_hits: u64,
        arena_bumps: u64,
        arena_switches: u32,
        fallback_allocs: u64,
        arena_remaining: usize,
        retired_arenas: u32,
        free_list_blocks: u32,
    };
};

// ─── Tests ────────────────────────────────────────────────────────────

test "basic alloc and release" {
    var pool = try PoolArena.init(std.testing.allocator, .{
        .arena_size = 4096,
        .enable_background_refill = false,
    });
    defer pool.deinit();

    const a = try pool.alloc(10);
    try std.testing.expectEqual(@as(usize, 10), a.buf.len);
    @memcpy(a.buf, "helloworld");
    try std.testing.expectEqualStrings("helloworld", a.buf);

    pool.release(a.buf.ptr, a.block_size);
    try std.testing.expect(pool.stats().free_list_blocks > 0);
}

test "free list recycling" {
    var pool = try PoolArena.init(std.testing.allocator, .{
        .arena_size = 4096,
        .enable_background_refill = false,
    });
    defer pool.deinit();

    const a1 = try pool.alloc(20);
    @memset(a1.buf, 'A');
    pool.release(a1.buf.ptr, a1.block_size);

    _ = try pool.alloc(20);
    try std.testing.expect(pool.free_list_hits == 1);
}

test "arena exhaustion triggers standby swap" {
    var pool = try PoolArena.init(std.testing.allocator, .{
        .arena_size = 256,
        .low_watermark = 64,
        .enable_background_refill = false,
    });
    defer pool.deinit();

    pool.standby_arena = try std.testing.allocator.alloc(u8, 256);

    // Track allocations so we can release fallbacks
    var allocs: [20]PoolArena.Allocation = undefined;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        allocs[i] = try pool.alloc(10);
    }

    try std.testing.expect(pool.arena_switches >= 1);

    // Release all — especially fallback allocs which need explicit free
    i = 0;
    while (i < 20) : (i += 1) {
        pool.release(allocs[i].buf.ptr, allocs[i].block_size);
    }
}

test "oversized alloc falls through to backing" {
    var pool = try PoolArena.init(std.testing.allocator, .{
        .arena_size = 4096,
        .enable_background_refill = false,
    });
    defer pool.deinit();

    const a = try pool.alloc(8192);
    try std.testing.expectEqual(@as(usize, 8192), a.buf.len);
    @memset(a.buf, 0);
    try std.testing.expect(pool.fallback_allocs >= 1);

    pool.release(a.buf.ptr, a.block_size);
}

test "zero-length alloc" {
    var pool = try PoolArena.init(std.testing.allocator, .{
        .arena_size = 4096,
        .enable_background_refill = false,
    });
    defer pool.deinit();

    const a = try pool.alloc(0);
    try std.testing.expectEqual(@as(usize, 0), a.buf.len);
    pool.release(a.buf.ptr, a.block_size);
}

test "multiple size classes" {
    var pool = try PoolArena.init(std.testing.allocator, .{
        .arena_size = 65536,
        .enable_background_refill = false,
    });
    defer pool.deinit();

    const small = try pool.alloc(16);
    const medium = try pool.alloc(100);
    const large = try pool.alloc(500);

    @memset(small.buf, 'S');
    @memset(medium.buf, 'M');
    @memset(large.buf, 'L');

    try std.testing.expectEqual(@as(u8, 'S'), small.buf[0]);
    try std.testing.expectEqual(@as(u8, 'M'), medium.buf[0]);
    try std.testing.expectEqual(@as(u8, 'L'), large.buf[0]);

    try std.testing.expectEqual(@as(u32, 32), small.block_size);
    try std.testing.expectEqual(@as(u32, 128), medium.block_size);
    try std.testing.expectEqual(@as(u32, 512), large.block_size);

    pool.release(small.buf.ptr, small.block_size);
    pool.release(medium.buf.ptr, medium.block_size);
    pool.release(large.buf.ptr, large.block_size);

    try std.testing.expect(pool.stats().free_list_blocks == 3);
}

test "stats tracking" {
    var pool = try PoolArena.init(std.testing.allocator, .{
        .arena_size = 4096,
        .enable_background_refill = false,
    });
    defer pool.deinit();

    _ = try pool.alloc(10);
    _ = try pool.alloc(10);
    _ = try pool.alloc(10);

    const s = pool.stats();
    try std.testing.expectEqual(@as(u64, 3), s.total_allocs);
    try std.testing.expectEqual(@as(u64, 3), s.arena_bumps);
    try std.testing.expectEqual(@as(u64, 0), s.free_list_hits);
}
