const std = @import("std");
const Allocator = std.mem.Allocator;
const VectorStore = @import("vector_store.zig").VectorStore;

/// Hierarchical Navigable Small World graph for approximate nearest neighbor search.
/// One instance per vector field. References VectorStore for distance computation.
///
/// Algorithm: Malkov & Yashunin, 2018 (https://arxiv.org/abs/1603.09320)
/// - Multi-layer navigable graph with exponentially decreasing node count per layer
/// - Insert: greedy search from top layer, then connect at each layer ≤ node's random level
/// - Search: greedy descent from top to layer 1, then ef-wide search at layer 0
pub const HnswIndex = struct {
    allocator: Allocator,
    dim: u32,

    // HNSW parameters
    M: u16 = 16,
    M_max0: u16 = 32,
    ef_construction: u16 = 200,
    ef_search: u16 = 50,
    ml: f32, // 1.0 / ln(M), for random level generation

    // Graph state
    max_level: u8 = 0,
    entry_point: ?u32 = null,
    node_count: u32 = 0,

    // Per-node neighbor lists at layer 0 (most nodes only exist here)
    neighbors_l0: std.AutoHashMap(u32, []u32),
    // Node's max layer
    node_levels: std.AutoHashMap(u32, u8),
    // Higher layers (index 0 = layer 1, index 1 = layer 2, etc.)
    higher_layers: std.array_list.Managed(std.AutoHashMap(u32, []u32)),

    // Reference to vector store for distance computation
    vectors: *const VectorStore,
    field_id: u16,

    // PRNG for level generation
    rng_state: u64,

    pub const SearchResult = struct {
        node_id: u32,
        distance: f32,
    };

    pub fn init(allocator: Allocator, dim: u32, vectors: *const VectorStore, field_id: u16) HnswIndex {
        const m: f32 = 16.0;
        return .{
            .allocator = allocator,
            .dim = dim,
            .ml = 1.0 / @log(m),
            .neighbors_l0 = std.AutoHashMap(u32, []u32).init(allocator),
            .node_levels = std.AutoHashMap(u32, u8).init(allocator),
            .higher_layers = std.array_list.Managed(std.AutoHashMap(u32, []u32)).init(allocator),
            .vectors = vectors,
            .field_id = field_id,
            .rng_state = 42,
        };
    }

    pub fn deinit(self: *HnswIndex) void {
        // Free layer 0 neighbor lists
        var it0 = self.neighbors_l0.iterator();
        while (it0.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.neighbors_l0.deinit();

        // Free higher layer neighbor lists
        for (self.higher_layers.items) |*layer| {
            var it = layer.iterator();
            while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
            layer.deinit();
        }
        self.higher_layers.deinit();
        self.node_levels.deinit();
    }

    /// Insert a node into the HNSW graph. Vector must already be in VectorStore.
    pub fn insert(self: *HnswIndex, node_id: u32) !void {
        const vec = self.vectors.getById(node_id, self.field_id) orelse return error.VectorNotFound;

        const level = self.randomLevel();

        // Ensure higher_layers has enough layers
        while (self.higher_layers.items.len < level) {
            try self.higher_layers.append(std.AutoHashMap(u32, []u32).init(self.allocator));
        }

        try self.node_levels.put(node_id, level);
        // Initialize empty neighbor lists
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

        // Phase 1: greedy search from top to level+1
        var current_level: u8 = self.max_level;
        while (current_level > level) : (current_level -= 1) {
            const layer_idx = current_level - 1;
            ep = self.greedyClosest(vec, ep, layer_idx);
            if (current_level == 0) break;
        }

        // Phase 2: search and connect at each layer from min(level, max_level) down to 0
        const start_level = @min(level, self.max_level);
        var lev: u8 = start_level;
        while (true) {
            const max_conn: u16 = if (lev == 0) self.M_max0 else self.M;
            const ef = self.ef_construction;

            // Search for candidates at this layer
            var candidates = try self.searchLayer(vec, ep, ef, lev);
            defer candidates.deinit();

            // Select M best neighbors
            const neighbors = try self.selectNeighborsSimple(&candidates, max_conn);
            defer self.allocator.free(neighbors);

            // Set this node's neighbors at this layer
            try self.setNeighbors(node_id, lev, neighbors);

            // Add bidirectional connections
            for (neighbors) |neighbor| {
                try self.addConnection(neighbor, node_id, lev, max_conn);
            }

            // Update entry point for next layer search
            if (candidates.items.items.len > 0) {
                ep = candidates.items.items[0].node_id;
            }

            if (lev == 0) break;
            lev -= 1;
        }

        // Update entry point if new node has higher level
        if (level > self.max_level) {
            self.entry_point = node_id;
            self.max_level = level;
        }
    }

    /// Search for K nearest neighbors. Returns results sorted by distance (ascending).
    /// alive_bits filters out deleted nodes.
    pub fn search(self: *const HnswIndex, query: []const f32, k: u32, alive_bits: ?*const std.DynamicBitSet) ![]SearchResult {
        if (self.entry_point == null or self.node_count == 0) {
            return try self.allocator.alloc(SearchResult, 0);
        }

        var ep = self.entry_point.?;

        // Greedy descent from top to layer 1
        if (self.max_level > 0) {
            var current_level: u8 = self.max_level;
            while (current_level > 0) : (current_level -= 1) {
                const layer_idx = current_level - 1;
                ep = self.greedyClosest(query, ep, layer_idx);
                if (current_level == 1) break;
            }
        }

        // Search at layer 0 with ef_search
        const ef = @max(self.ef_search, @as(u16, @intCast(k)));
        var candidates = try self.searchLayer(query, ep, ef, 0);
        defer candidates.deinit();

        // Filter by alive_bits and take top-k
        var results = std.array_list.Managed(SearchResult).init(self.allocator);
        for (candidates.items.items) |c| {
            if (alive_bits) |bits| {
                if (!bits.isSet(c.node_id)) continue;
            }
            try results.append(c);
            if (results.items.len >= k) break;
        }

        return try results.toOwnedSlice();
    }

    // ── Internal methods ────────────────────────────────────────────

    fn randomLevel(self: *HnswIndex) u8 {
        // xorshift64
        var x = self.rng_state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng_state = x;

        // Uniform random in (0, 1)
        const r: f32 = @as(f32, @floatFromInt(x & 0xFFFFFF)) / 16777216.0;
        // level = floor(-ln(r) * ml), capped at 16
        const ln_r = -@log(@max(r, 1e-10));
        const level_f = ln_r * self.ml;
        const level: u8 = @intCast(@min(@as(u32, @intFromFloat(level_f)), 16));
        return level;
    }

    fn getVec(self: *const HnswIndex, node_id: u32) ?[]const f32 {
        return self.vectors.getById(node_id, self.field_id);
    }

    fn distance(self: *const HnswIndex, a_id: u32, b: []const f32) f32 {
        const a_vec = self.getVec(a_id) orelse return 2.0; // max distance if missing
        return VectorStore.cosineDistance(a_vec, b);
    }

    /// Greedy search at a higher layer: find single closest node.
    fn greedyClosest(self: *const HnswIndex, query: []const f32, start: u32, layer_idx: u8) u32 {
        var current = start;
        var best_dist = self.distance(current, query);

        var changed = true;
        while (changed) {
            changed = false;
            const neighbors = self.getNeighbors(current, layer_idx + 1); // layer_idx 0 = layer 1
            for (neighbors) |n| {
                const d = self.distance(n, query);
                if (d < best_dist) {
                    best_dist = d;
                    current = n;
                    changed = true;
                }
            }
        }
        return current;
    }

    /// Search a layer with ef-width beam search. Returns candidates sorted by distance.
    fn searchLayer(self: *const HnswIndex, query: []const f32, entry: u32, ef: u16, layer: u8) !CandidateList {
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        var candidates = CandidateList.init(self.allocator);
        var working = std.array_list.Managed(SearchResult).init(self.allocator);
        defer working.deinit();

        const entry_dist = self.distance(entry, query);
        try visited.put(entry, {});
        try candidates.insert(.{ .node_id = entry, .distance = entry_dist });
        try working.append(.{ .node_id = entry, .distance = entry_dist });

        while (working.items.len > 0) {
            // Pop closest from working set
            var best_idx: usize = 0;
            for (working.items, 0..) |item, i| {
                if (item.distance < working.items[best_idx].distance) best_idx = i;
            }
            const current = working.orderedRemove(best_idx);

            // If current is further than the worst candidate, stop
            if (candidates.items.items.len >= ef) {
                if (current.distance > candidates.items.items[candidates.items.items.len - 1].distance) break;
            }

            const neighbors = self.getNeighbors(current.node_id, layer);
            for (neighbors) |n| {
                if (visited.contains(n)) continue;
                try visited.put(n, {});

                const d = self.distance(n, query);

                if (candidates.items.items.len < ef or d < candidates.items.items[candidates.items.items.len - 1].distance) {
                    try candidates.insert(.{ .node_id = n, .distance = d });
                    try working.append(.{ .node_id = n, .distance = d });

                    // Trim candidates to ef
                    if (candidates.items.items.len > ef) {
                        candidates.items.shrinkRetainingCapacity(ef);
                    }
                }
            }
        }

        return candidates;
    }

    /// Simple neighbor selection: keep the M closest.
    fn selectNeighborsSimple(self: *HnswIndex, candidates: *CandidateList, M: u16) ![]u32 {
        const count = @min(candidates.items.items.len, @as(usize, M));
        const result = try self.allocator.alloc(u32, count);
        for (0..count) |i| {
            result[i] = candidates.items.items[i].node_id;
        }
        return result;
    }

    fn getNeighbors(self: *const HnswIndex, node_id: u32, layer: u8) []const u32 {
        if (layer == 0) {
            return self.neighbors_l0.get(node_id) orelse &.{};
        }
        if (layer - 1 >= self.higher_layers.items.len) return &.{};
        return self.higher_layers.items[layer - 1].get(node_id) orelse &.{};
    }

    fn setNeighbors(self: *HnswIndex, node_id: u32, layer: u8, neighbors: []const u32) !void {
        const owned = try self.allocator.dupe(u32, neighbors);
        if (layer == 0) {
            if (self.neighbors_l0.getPtr(node_id)) |existing| {
                self.allocator.free(existing.*);
                existing.* = owned;
            } else {
                try self.neighbors_l0.put(node_id, owned);
            }
        } else {
            const li = layer - 1;
            if (li >= self.higher_layers.items.len) return;
            if (self.higher_layers.items[li].getPtr(node_id)) |existing| {
                self.allocator.free(existing.*);
                existing.* = owned;
            } else {
                try self.higher_layers.items[li].put(node_id, owned);
            }
        }
    }

    /// Add a connection from `from` to `to` at the given layer.
    /// If `from` already has max_conn neighbors, prune the furthest.
    fn addConnection(self: *HnswIndex, from: u32, to: u32, layer: u8, max_conn: u16) !void {
        const current = if (layer == 0)
            self.neighbors_l0.get(from) orelse &[_]u32{}
        else blk: {
            if (layer - 1 >= self.higher_layers.items.len) break :blk &[_]u32{};
            break :blk self.higher_layers.items[layer - 1].get(from) orelse &[_]u32{};
        };

        // Check if already connected
        for (current) |n| {
            if (n == to) return;
        }

        if (current.len < max_conn) {
            // Room to add
            const new = try self.allocator.alloc(u32, current.len + 1);
            @memcpy(new[0..current.len], current);
            new[current.len] = to;
            if (layer == 0) {
                if (self.neighbors_l0.getPtr(from)) |existing| {
                    self.allocator.free(existing.*);
                    existing.* = new;
                }
            } else {
                const li = layer - 1;
                if (li < self.higher_layers.items.len) {
                    if (self.higher_layers.items[li].getPtr(from)) |existing| {
                        self.allocator.free(existing.*);
                        existing.* = new;
                    }
                }
            }
        } else {
            // Need to prune: find the furthest neighbor and replace if `to` is closer
            const from_vec = self.getVec(from) orelse return;
            var worst_idx: usize = 0;
            var worst_dist: f32 = 0;
            for (current, 0..) |n, i| {
                const d = self.distance(n, from_vec);
                if (d > worst_dist) {
                    worst_dist = d;
                    worst_idx = i;
                }
            }
            const to_dist = self.distance(to, from_vec);
            if (to_dist < worst_dist) {
                // Replace worst with `to`
                const new = try self.allocator.dupe(u32, current);
                new[worst_idx] = to;
                if (layer == 0) {
                    if (self.neighbors_l0.getPtr(from)) |existing| {
                        self.allocator.free(existing.*);
                        existing.* = new;
                    }
                } else {
                    const li = layer - 1;
                    if (li < self.higher_layers.items.len) {
                        if (self.higher_layers.items[li].getPtr(from)) |existing| {
                            self.allocator.free(existing.*);
                            existing.* = new;
                        }
                    }
                }
            }
        }
    }
};

/// Sorted list of search candidates (by distance ascending).
const CandidateList = struct {
    items: std.array_list.Managed(SearchResult),

    const SearchResult = HnswIndex.SearchResult;

    fn init(allocator: Allocator) CandidateList {
        return .{ .items = std.array_list.Managed(SearchResult).init(allocator) };
    }

    fn deinit(self: *CandidateList) void {
        self.items.deinit();
    }

    fn insert(self: *CandidateList, result: SearchResult) !void {
        // Find insertion point (sorted by distance ascending)
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

    // Insert 10 vectors in 3D
    const vecs = [_][3]f32{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.9, 0.1, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.5, 0.5, 0.0 },
        .{ 0.7, 0.7, 0.0 },
        .{ 0.1, 0.9, 0.0 },
        .{ 0.0, 0.1, 0.9 },
        .{ 0.8, 0.2, 0.0 },
        .{ 0.3, 0.3, 0.3 },
    };

    for (vecs, 0..) |v, i| {
        try vs.set(@intCast(i), "emb", &v);
    }

    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();

    for (0..10) |i| {
        try idx.insert(@intCast(i));
    }

    // Search for vector closest to [1, 0, 0] — should be node 0
    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 3, null);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 1);
    // Node 0 should be the closest (it IS [1, 0, 0])
    try std.testing.expectEqual(@as(u32, 0), results[0].node_id);
    try std.testing.expect(results[0].distance < 0.1);
}

test "hnsw empty search" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();

    const query = [_]f32{ 1.0, 0.0, 0.0 };
    const results = try idx.search(&query, 5, null);
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

test "hnsw cosine distance correctness" {
    // [1,0,0] vs [0,1,0] should have cosine distance ~1.0
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), VectorStore.cosineDistance(&a, &b), 0.001);

    // [1,0,0] vs [1,0,0] should have cosine distance ~0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), VectorStore.cosineDistance(&a, &a), 0.001);
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

    try idx.insert(0);
    try idx.insert(1);
    try idx.insert(2);

    // Mark node 0 as dead
    var alive = try std.DynamicBitSet.initFull(allocator, 3);
    defer alive.deinit();
    alive.unset(0);

    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 3, &alive);
    defer allocator.free(results);

    // Node 0 should be excluded
    for (results) |r| {
        try std.testing.expect(r.node_id != 0);
    }
    // Node 1 should be closest (after 0 is excluded)
    if (results.len > 0) {
        try std.testing.expectEqual(@as(u32, 1), results[0].node_id);
    }
}
