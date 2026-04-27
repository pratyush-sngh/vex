const std = @import("std");
const Allocator = std.mem.Allocator;
const VectorStore = @import("vector_store.zig").VectorStore;

/// Hierarchical Navigable Small World graph for approximate nearest neighbor search.
/// One instance per vector field. References VectorStore for distance computation.
pub const HnswIndex = struct {
    allocator: Allocator,
    dim: u32,

    M: u16 = 16,
    M_max0: u16 = 32,
    ef_construction: u16 = 200,
    ef_search: u16 = 50,
    ml: f32,

    max_level: u8 = 0,
    entry_point: ?u32 = null,
    node_count: u32 = 0,

    neighbors_l0: std.AutoHashMap(u32, []u32),
    node_levels: std.AutoHashMap(u32, u8),
    higher_layers: std.array_list.Managed(std.AutoHashMap(u32, []u32)),

    vectors: *const VectorStore,
    field_id: u16,
    rng_state: u64,

    pub const SearchResult = struct {
        node_id: u32,
        distance: f32,
    };

    pub fn init(allocator: Allocator, dim: u32, vectors: *const VectorStore, field_id: u16) HnswIndex {
        return .{
            .allocator = allocator,
            .dim = dim,
            .ml = 1.0 / @log(@as(f32, 16.0)),
            .neighbors_l0 = std.AutoHashMap(u32, []u32).init(allocator),
            .node_levels = std.AutoHashMap(u32, u8).init(allocator),
            .higher_layers = std.array_list.Managed(std.AutoHashMap(u32, []u32)).init(allocator),
            .vectors = vectors,
            .field_id = field_id,
            .rng_state = 42,
        };
    }

    pub fn deinit(self: *HnswIndex) void {
        var it0 = self.neighbors_l0.iterator();
        while (it0.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.neighbors_l0.deinit();

        for (self.higher_layers.items) |*layer| {
            var it = layer.iterator();
            while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
            layer.deinit();
        }
        self.higher_layers.deinit();
        self.node_levels.deinit();
    }

    pub fn insert(self: *HnswIndex, node_id: u32) !void {
        const vec = self.vectors.getById(node_id, self.field_id) orelse return error.VectorNotFound;
        const level = self.randomLevel();

        while (self.higher_layers.items.len < level) {
            try self.higher_layers.append(std.AutoHashMap(u32, []u32).init(self.allocator));
        }

        try self.node_levels.put(node_id, level);
        try self.neighbors_l0.put(node_id, try self.allocator.alloc(u32, 0));
        for (0..level) |li| {
            try self.higher_layers.items[li].put(node_id, try self.allocator.alloc(u32, 0));
        }

        self.node_count += 1;

        if (self.entry_point == null) {
            self.entry_point = node_id;
            self.max_level = level;
            return;
        }

        var ep = self.entry_point.?;

        // Greedy descent from top to level+1
        if (self.max_level > level) {
            var cl: u8 = self.max_level;
            while (cl > level) : (cl -= 1) {
                ep = self.greedyClosest(vec, ep, cl - 1);
                if (cl == 0) break;
            }
        }

        // Search and connect at each layer
        const start_level = @min(level, self.max_level);
        var lev: u8 = start_level;
        while (true) {
            const max_conn: u16 = if (lev == 0) self.M_max0 else self.M;
            var candidates = try self.searchLayer(vec, ep, self.ef_construction, lev);
            defer candidates.deinit();

            const neighbors = try self.selectNeighbors(&candidates, max_conn);
            defer self.allocator.free(neighbors);

            try self.setNeighbors(node_id, lev, neighbors);
            for (neighbors) |neighbor| {
                try self.addConnection(neighbor, node_id, lev, max_conn);
            }

            if (candidates.items.items.len > 0) ep = candidates.items.items[0].node_id;
            if (lev == 0) break;
            lev -= 1;
        }

        if (level > self.max_level) {
            self.entry_point = node_id;
            self.max_level = level;
        }
    }

    pub fn search(self: *const HnswIndex, query: []const f32, k: u32, alive_bits: ?*const std.DynamicBitSet) ![]SearchResult {
        if (self.entry_point == null or self.node_count == 0) {
            return try self.allocator.alloc(SearchResult, 0);
        }

        var ep = self.entry_point.?;

        if (self.max_level > 0) {
            var cl: u8 = self.max_level;
            while (cl > 0) : (cl -= 1) {
                ep = self.greedyClosest(query, ep, cl - 1);
                if (cl == 1) break;
            }
        }

        const ef = @max(self.ef_search, @as(u16, @intCast(@min(k, std.math.maxInt(u16)))));
        var candidates = try self.searchLayer(query, ep, ef, 0);
        defer candidates.deinit();

        var results = std.array_list.Managed(SearchResult).init(self.allocator);
        for (candidates.items.items) |c| {
            if (alive_bits) |bits| {
                if (c.node_id >= bits.capacity()) continue;
                if (!bits.isSet(c.node_id)) continue;
            }
            try results.append(c);
            if (results.items.len >= k) break;
        }

        return try results.toOwnedSlice();
    }

    // ── Internal ────────────────────────────────────────────────────

    fn randomLevel(self: *HnswIndex) u8 {
        var x = self.rng_state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng_state = x;
        const r: f32 = @as(f32, @floatFromInt(x & 0xFFFFFF)) / 16777216.0;
        const ln_r = -@log(@max(r, 1e-10));
        const level_f = ln_r * self.ml;
        return @intCast(@min(@as(u32, @intFromFloat(level_f)), 16));
    }

    fn getVec(self: *const HnswIndex, node_id: u32) ?[]const f32 {
        return self.vectors.getById(node_id, self.field_id);
    }

    fn dist(self: *const HnswIndex, a_id: u32, b: []const f32) f32 {
        const a_vec = self.getVec(a_id) orelse return 2.0;
        return VectorStore.cosineDistance(a_vec, b);
    }

    fn greedyClosest(self: *const HnswIndex, query: []const f32, start: u32, layer_idx: u8) u32 {
        var current = start;
        var best_dist = self.dist(current, query);
        var changed = true;
        while (changed) {
            changed = false;
            const neighbors = self.getNeighbors(current, layer_idx + 1);
            for (neighbors) |n| {
                const d = self.dist(n, query);
                if (d < best_dist) {
                    best_dist = d;
                    current = n;
                    changed = true;
                }
            }
        }
        return current;
    }

    fn searchLayer(self: *const HnswIndex, query: []const f32, entry: u32, ef: u16, layer: u8) !CandidateList {
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        var candidates = CandidateList.init(self.allocator);
        var working = std.array_list.Managed(SearchResult).init(self.allocator);
        defer working.deinit();

        const entry_dist = self.dist(entry, query);
        try visited.put(entry, {});
        try candidates.insert(.{ .node_id = entry, .distance = entry_dist });
        try working.append(.{ .node_id = entry, .distance = entry_dist });

        while (working.items.len > 0) {
            var best_idx: usize = 0;
            for (working.items, 0..) |item, i| {
                if (item.distance < working.items[best_idx].distance) best_idx = i;
            }
            const current = working.orderedRemove(best_idx);

            if (candidates.items.items.len >= ef) {
                if (current.distance > candidates.items.items[candidates.items.items.len - 1].distance) break;
            }

            const neighbors = self.getNeighbors(current.node_id, layer);
            for (neighbors) |n| {
                if (visited.contains(n)) continue;
                try visited.put(n, {});
                const d = self.dist(n, query);
                if (candidates.items.items.len < ef or d < candidates.items.items[candidates.items.items.len - 1].distance) {
                    try candidates.insert(.{ .node_id = n, .distance = d });
                    try working.append(.{ .node_id = n, .distance = d });
                    if (candidates.items.items.len > ef) {
                        candidates.items.shrinkRetainingCapacity(ef);
                    }
                }
            }
        }
        return candidates;
    }

    fn selectNeighbors(self: *HnswIndex, candidates: *CandidateList, M: u16) ![]u32 {
        const count = @min(candidates.items.items.len, @as(usize, M));
        const result = try self.allocator.alloc(u32, count);
        for (0..count) |i| result[i] = candidates.items.items[i].node_id;
        return result;
    }

    fn getNeighbors(self: *const HnswIndex, node_id: u32, layer: u8) []const u32 {
        if (layer == 0) return self.neighbors_l0.get(node_id) orelse &.{};
        if (layer - 1 >= self.higher_layers.items.len) return &.{};
        return self.higher_layers.items[layer - 1].get(node_id) orelse &.{};
    }

    fn setNeighbors(self: *HnswIndex, node_id: u32, layer: u8, neighbors: []const u32) !void {
        const owned = try self.allocator.dupe(u32, neighbors);
        if (layer == 0) {
            if (self.neighbors_l0.getPtr(node_id)) |e| { self.allocator.free(e.*); e.* = owned; } else try self.neighbors_l0.put(node_id, owned);
        } else {
            const li = layer - 1;
            if (li >= self.higher_layers.items.len) return;
            if (self.higher_layers.items[li].getPtr(node_id)) |e| { self.allocator.free(e.*); e.* = owned; } else try self.higher_layers.items[li].put(node_id, owned);
        }
    }

    fn addConnection(self: *HnswIndex, from: u32, to: u32, layer: u8, max_conn: u16) !void {
        const current = if (layer == 0)
            self.neighbors_l0.get(from) orelse &[_]u32{}
        else blk: {
            if (layer - 1 >= self.higher_layers.items.len) break :blk &[_]u32{};
            break :blk self.higher_layers.items[layer - 1].get(from) orelse &[_]u32{};
        };

        for (current) |n| { if (n == to) return; }

        if (current.len < max_conn) {
            const new = try self.allocator.alloc(u32, current.len + 1);
            @memcpy(new[0..current.len], current);
            new[current.len] = to;
            self.replaceNeighborList(from, layer, new);
        } else {
            const from_vec = self.getVec(from) orelse return;
            var worst_idx: usize = 0;
            var worst_dist: f32 = 0;
            for (current, 0..) |n, i| {
                const d = self.dist(n, from_vec);
                if (d > worst_dist) { worst_dist = d; worst_idx = i; }
            }
            if (self.dist(to, from_vec) < worst_dist) {
                const new = try self.allocator.dupe(u32, current);
                new[worst_idx] = to;
                self.replaceNeighborList(from, layer, new);
            }
        }
    }

    fn replaceNeighborList(self: *HnswIndex, node_id: u32, layer: u8, new_list: []u32) void {
        if (layer == 0) {
            if (self.neighbors_l0.getPtr(node_id)) |e| { self.allocator.free(e.*); e.* = new_list; }
        } else {
            const li = layer - 1;
            if (li < self.higher_layers.items.len) {
                if (self.higher_layers.items[li].getPtr(node_id)) |e| { self.allocator.free(e.*); e.* = new_list; }
            }
        }
    }
};

/// Sorted candidate list (by distance ascending).
const CandidateList = struct {
    items: std.array_list.Managed(HnswIndex.SearchResult),

    fn init(allocator: Allocator) CandidateList {
        return .{ .items = std.array_list.Managed(HnswIndex.SearchResult).init(allocator) };
    }
    fn deinit(self: *CandidateList) void { self.items.deinit(); }

    fn insert(self: *CandidateList, result: HnswIndex.SearchResult) !void {
        var pos: usize = self.items.items.len;
        while (pos > 0 and self.items.items[pos - 1].distance > result.distance) : (pos -= 1) {}
        try self.items.insert(pos, result);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "hnsw basic insert and search" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    const vecs = [_][3]f32{
        .{ 1.0, 0.0, 0.0 }, .{ 0.9, 0.1, 0.0 }, .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 }, .{ 0.5, 0.5, 0.0 }, .{ 0.7, 0.7, 0.0 },
        .{ 0.1, 0.9, 0.0 }, .{ 0.0, 0.1, 0.9 }, .{ 0.8, 0.2, 0.0 },
        .{ 0.3, 0.3, 0.3 },
    };
    for (vecs, 0..) |v, i| try vs.set(@intCast(i), "emb", &v);

    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    for (0..10) |i| try idx.insert(@intCast(i));

    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 3, null);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqual(@as(u32, 0), results[0].node_id);
    try std.testing.expect(results[0].distance < 0.1);
}

test "hnsw empty search" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();
    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    const results = try idx.search(&[_]f32{ 1.0, 0.0, 0.0 }, 5, null);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "hnsw single vector" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();
    try vs.set(42, "emb", &[_]f32{ 0.5, 0.5, 0.0 });
    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    try idx.insert(42);
    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 1, null);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u32, 42), results[0].node_id);
}

test "hnsw node alive filtering" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();
    try vs.set(0, "emb", &[_]f32{ 1.0, 0.0, 0.0 });
    try vs.set(1, "emb", &[_]f32{ 0.9, 0.1, 0.0 });
    try vs.set(2, "emb", &[_]f32{ 0.0, 1.0, 0.0 });

    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    for (0..3) |i| try idx.insert(@intCast(i));

    var alive = try std.DynamicBitSet.initFull(allocator, 3);
    defer alive.deinit();
    alive.unset(0);

    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 3, &alive);
    defer allocator.free(results);

    for (results) |r| try std.testing.expect(r.node_id != 0);
    if (results.len > 0) try std.testing.expectEqual(@as(u32, 1), results[0].node_id);
}
