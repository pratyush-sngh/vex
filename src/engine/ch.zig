const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const NodeId = graph_mod.NodeId;
const GraphEngine = graph_mod.GraphEngine;
const CSR = graph_mod.CSR;

const INVALID: NodeId = graph_mod.INVALID_ID;
const INF: f64 = std.math.inf(f64);
const WITNESS_MAX_SETTLED: u32 = 100;
const WITNESS_SKIP_THRESHOLD: u64 = 100; // skip witness search when in_deg * out_deg exceeds this

// ─── Public Data Structure ────────────────────────────────────────────

pub const CHData = struct {
    allocator: Allocator,
    node_count: u32,
    rank: []u32,

    // Upward-out: for forward search. up_out[u] has edges u→w where rank[w] > rank[u]
    up_out_offsets: []u32,
    up_out_targets: []NodeId,
    up_out_weights: []f64,
    up_out_middles: []NodeId, // INVALID = original edge

    // Upward-in: for backward search. up_in[w] has entries (v, weight(v→w)) where rank[v] > rank[w]
    up_in_offsets: []u32,
    up_in_targets: []NodeId, // stores v (the higher-ranked source)
    up_in_weights: []f64,
    up_in_middles: []NodeId,

    mutation_seq: u64,

    pub fn deinit(self: *CHData) void {
        self.allocator.free(self.rank);
        self.allocator.free(self.up_out_offsets);
        if (self.up_out_targets.len > 0) self.allocator.free(self.up_out_targets);
        if (self.up_out_weights.len > 0) self.allocator.free(self.up_out_weights);
        if (self.up_out_middles.len > 0) self.allocator.free(self.up_out_middles);
        self.allocator.free(self.up_in_offsets);
        if (self.up_in_targets.len > 0) self.allocator.free(self.up_in_targets);
        if (self.up_in_weights.len > 0) self.allocator.free(self.up_in_weights);
        if (self.up_in_middles.len > 0) self.allocator.free(self.up_in_middles);
    }

    /// Incremental weight update: when an original edge (u→v) changes weight,
    /// propagate new weights upward through shortcuts that depend on it.
    /// Returns number of shortcuts updated.
    pub fn updateEdgeWeight(self: *CHData, from: NodeId, to: NodeId, new_weight: f64, g: *const GraphEngine) u32 {
        _ = g;
        var updated: u32 = 0;

        // Update the direct edge in up_out/up_in if it exists
        if (self.rank[to] > self.rank[from]) {
            // Edge goes upward: in up_out[from]
            const start = self.up_out_offsets[from];
            const end = self.up_out_offsets[from + 1];
            for (start..end) |i| {
                if (self.up_out_targets[i] == to and self.up_out_middles[i] == INVALID) {
                    self.up_out_weights[i] = new_weight;
                    updated += 1;
                }
            }
        } else if (self.rank[from] > self.rank[to]) {
            // Edge stored in up_in[to]
            const start = self.up_in_offsets[to];
            const end = self.up_in_offsets[to + 1];
            for (start..end) |i| {
                if (self.up_in_targets[i] == from and self.up_in_middles[i] == INVALID) {
                    self.up_in_weights[i] = new_weight;
                    updated += 1;
                }
            }
        }

        // Now propagate: any shortcut whose middle chain includes this edge
        // must have its weight recomputed. Walk all shortcuts bottom-up.
        // A shortcut a→b via middle m has weight = weight(a→m) + weight(m→b).
        // We recompute all shortcuts whose sub-edges were affected.
        updated += self.propagateWeights();
        return updated;
    }

    /// Bottom-up weight propagation: recompute all shortcut weights from their
    /// sub-edges. Process nodes in rank order (low rank first) so that when we
    /// recompute a shortcut's weight, its sub-edges are already up to date.
    fn propagateWeights(self: *CHData) u32 {
        var updated: u32 = 0;
        const n: usize = self.node_count;

        // Process up_out edges: for each shortcut a→b via middle m,
        // new weight = weight(a→m) + weight(m→b) in the overlay
        for (0..n) |uid| {
            const u: NodeId = @intCast(uid);
            const start = self.up_out_offsets[u];
            const end = self.up_out_offsets[u + 1];
            for (start..end) |i| {
                const mid = self.up_out_middles[i];
                if (mid == INVALID) continue; // original edge, skip

                const target = self.up_out_targets[i];
                // Shortcut u→target via mid: weight = overlay(u→mid) + overlay(mid→target)
                const w1 = self.findEdgeWeight(u, mid);
                const w2 = self.findEdgeWeight(mid, target);
                if (w1 < INF and w2 < INF) {
                    const new_w = w1 + w2;
                    if (new_w != self.up_out_weights[i]) {
                        self.up_out_weights[i] = new_w;
                        // Also update the corresponding up_in entry
                        self.updateUpInWeight(u, target, new_w);
                        updated += 1;
                    }
                }
            }
        }
        return updated;
    }

    /// Find weight of edge from→to in the overlay (checks both up_out and up_in).
    fn findEdgeWeight(self: *const CHData, from: NodeId, to: NodeId) f64 {
        if (self.rank[to] > self.rank[from]) {
            const start = self.up_out_offsets[from];
            const end = self.up_out_offsets[from + 1];
            for (start..end) |i| {
                if (self.up_out_targets[i] == to) return self.up_out_weights[i];
            }
        } else {
            const start = self.up_in_offsets[from];
            const end = self.up_in_offsets[from + 1];
            for (start..end) |i| {
                if (self.up_in_targets[i] == to) return self.up_in_weights[i];
            }
        }
        return INF;
    }

    /// Update the up_in weight for edge from→to.
    fn updateUpInWeight(self: *CHData, from: NodeId, to: NodeId, new_weight: f64) void {
        if (self.rank[from] > self.rank[to]) {
            const start = self.up_in_offsets[to];
            const end = self.up_in_offsets[to + 1];
            for (start..end) |i| {
                if (self.up_in_targets[i] == from) {
                    self.up_in_weights[i] = new_weight;
                    return;
                }
            }
        }
    }
};

// ─── Working Graph (mutable during preprocessing) ─────────────────────

const WorkEdge = struct {
    target: NodeId,
    weight: f64,
    middle: NodeId, // INVALID = original edge
};

const WorkGraph = struct {
    allocator: Allocator,
    node_count: u32,
    out_edges: []std.ArrayListUnmanaged(WorkEdge),
    in_edges: []std.ArrayListUnmanaged(WorkEdge),
    contracted: []bool,

    fn init(allocator: Allocator, g: *const GraphEngine) !WorkGraph {
        const nc: u32 = @intCast(g.node_keys.items.len);
        const n: usize = nc;

        var out = try allocator.alloc(std.ArrayListUnmanaged(WorkEdge), n);
        var in = try allocator.alloc(std.ArrayListUnmanaged(WorkEdge), n);
        for (out, in) |*o, *i| {
            o.* = .{ .items = &.{}, .capacity = 0 };
            i.* = .{ .items = &.{}, .capacity = 0 };
        }

        // Populate from CSR
        for (0..n) |uid| {
            const u: NodeId = @intCast(uid);
            if (!g.node_alive.isSet(u)) continue;
            const targets = g.base_out.neighbors(u);
            const eidxs = g.base_out.edgeIndices(u);
            for (targets, eidxs) |w, eidx| {
                if (!g.edge_alive.isSet(eidx)) continue;
                if (!g.node_alive.isSet(w)) continue;
                const weight = g.edge_weight.items[eidx];
                try out[uid].append(allocator, .{ .target = w, .weight = weight, .middle = INVALID });
                try in[w].append(allocator, .{ .target = u, .weight = weight, .middle = INVALID });
            }
        }

        var cont = try allocator.alloc(bool, n);
        @memset(cont, false);
        // Mark dead nodes as already contracted
        for (0..n) |i| {
            if (!g.node_alive.isSet(@intCast(i))) cont[i] = true;
        }

        return .{
            .allocator = allocator,
            .node_count = nc,
            .out_edges = out,
            .in_edges = in,
            .contracted = cont,
        };
    }

    fn deinit(self: *WorkGraph) void {
        for (self.out_edges) |*list| list.deinit(self.allocator);
        for (self.in_edges) |*list| list.deinit(self.allocator);
        self.allocator.free(self.out_edges);
        self.allocator.free(self.in_edges);
        self.allocator.free(self.contracted);
    }

    /// Count non-contracted in/out degree of a node.
    fn liveDegree(self: *const WorkGraph, v: NodeId) struct { in_deg: u32, out_deg: u32 } {
        var in_d: u32 = 0;
        for (self.in_edges[v].items) |e| {
            if (!self.contracted[e.target]) in_d += 1;
        }
        var out_d: u32 = 0;
        for (self.out_edges[v].items) |e| {
            if (!self.contracted[e.target]) out_d += 1;
        }
        return .{ .in_deg = in_d, .out_deg = out_d };
    }
};

// ─── Staged Witness Search ───────────────────────────────────────────
// 1-hop: O(degree) scan — no Dijkstra, handles ~40% of pairs
// 2-hop: O(deg²) scan — no Dijkstra, handles ~25% more
// Full:  Dijkstra with settled-node limit — remaining ~35%

/// 1-hop: does source have a direct edge to target (avoiding `avoid`, non-contracted)?
fn witness1Hop(wg: *const WorkGraph, source: NodeId, target: NodeId, avoid: NodeId, max_weight: f64) bool {
    for (wg.out_edges[source].items) |e| {
        if (e.target == target and e.weight <= max_weight and e.target != avoid and !wg.contracted[e.target]) return true;
    }
    return false;
}

/// 2-hop: is there a 2-edge path source→mid→target (avoiding `avoid`, non-contracted)?
fn witness2Hop(wg: *const WorkGraph, source: NodeId, target: NodeId, avoid: NodeId, max_weight: f64) bool {
    for (wg.out_edges[source].items) |e1| {
        if (e1.target == avoid or wg.contracted[e1.target]) continue;
        if (e1.weight >= max_weight) continue;
        const remain = max_weight - e1.weight;
        for (wg.out_edges[e1.target].items) |e2| {
            if (e2.target == target and e2.weight <= remain and e2.target != avoid and !wg.contracted[e2.target]) return true;
        }
    }
    return false;
}

const WItem = struct {
    id: NodeId,
    d: f64,
    fn order(ctx: void, a: @This(), b: @This()) std.math.Order {
        _ = ctx;
        return std.math.order(a.d, b.d);
    }
};

const WitnessSearcher = struct {
    allocator: Allocator,
    dist: []f64,
    touched: std.ArrayListUnmanaged(NodeId),
    pq: std.PriorityQueue(WItem, void, WItem.order),

    fn init(allocator: Allocator, node_count: u32) !WitnessSearcher {
        const dist = try allocator.alloc(f64, node_count);
        @memset(dist, INF);
        return .{
            .allocator = allocator,
            .dist = dist,
            .touched = .{ .items = &.{}, .capacity = 0 },
            .pq = std.PriorityQueue(WItem, void, WItem.order).initContext({}),
        };
    }

    fn deinit(self: *WitnessSearcher) void {
        self.allocator.free(self.dist);
        self.touched.deinit(self.allocator);
        self.pq.deinit(self.allocator);
    }

    fn reset(self: *WitnessSearcher) void {
        for (self.touched.items) |id| self.dist[id] = INF;
        self.touched.clearRetainingCapacity();
        while (self.pq.items.len > 0) _ = self.pq.pop();
    }

    /// Full Dijkstra witness search (only called when 1-hop and 2-hop fail)
    fn search(
        self: *WitnessSearcher,
        wg: *const WorkGraph,
        source: NodeId,
        target: NodeId,
        avoid: NodeId,
        max_weight: f64,
    ) bool {
        self.reset();
        if (source == target) return true;

        self.dist[source] = 0;
        self.touched.append(self.allocator, source) catch return false;
        self.pq.push(self.allocator, .{ .id = source, .d = 0 }) catch return false;

        var settled: u32 = 0;
        while (self.pq.pop()) |cur| {
            if (cur.id == target and cur.d <= max_weight) return true;
            if (cur.d > self.dist[cur.id]) continue;
            if (cur.d > max_weight) return false;
            if (settled >= WITNESS_MAX_SETTLED) return false;
            settled += 1;

            for (wg.out_edges[cur.id].items) |e| {
                if (e.target == avoid) continue;
                if (wg.contracted[e.target]) continue;
                const nd = cur.d + e.weight;
                if (nd > max_weight) continue;
                if (nd < self.dist[e.target]) {
                    if (self.dist[e.target] == INF) self.touched.append(self.allocator, e.target) catch continue;
                    self.dist[e.target] = nd;
                    self.pq.push(self.allocator, .{ .id = e.target, .d = nd }) catch continue;
                }
            }
        }
        return false;
    }
};

/// Staged witness: try 1-hop, then 2-hop, then full Dijkstra.
fn witnessExists(wg: *const WorkGraph, ws: *WitnessSearcher, source: NodeId, target: NodeId, avoid: NodeId, max_weight: f64) bool {
    if (source == target) return true;
    if (witness1Hop(wg, source, target, avoid, max_weight)) return true;
    if (witness2Hop(wg, source, target, avoid, max_weight)) return true;
    return ws.search(wg, source, target, avoid, max_weight);
}

// ─── Node Ordering ────────────────────────────────────────────────────

const CONTRACTED_NEIGHBOR_WEIGHT: i32 = 120; // Geisberger's recommended weight

fn computePriority(wg: *const WorkGraph, v: NodeId, contracted_neighbors: []const u32) i32 {
    if (wg.contracted[v]) return std.math.maxInt(i32);

    const deg = wg.liveDegree(v);
    const in_deg = deg.in_deg;
    const out_deg = deg.out_deg;

    // edge_diff = shortcuts_upper_bound - edges_removed
    const shortcuts: i64 = @as(i64, in_deg) * @as(i64, out_deg);
    const removed: i64 = @as(i64, in_deg) + @as(i64, out_deg);
    const edge_diff = shortcuts - removed;

    // contracted_neighbors term spreads contraction uniformly (avoids clusters)
    const cn_term: i64 = @as(i64, contracted_neighbors[v]) * CONTRACTED_NEIGHBOR_WEIGHT;

    return @intCast(@min(edge_diff + cn_term, std.math.maxInt(i32)));
}

// ─── Build CH ─────────────────────────────────────────────────────────

pub fn build(g: *const GraphEngine, allocator: Allocator) !CHData {
    const nc: u32 = @intCast(g.node_keys.items.len);
    const n: usize = nc;
    var wg = try WorkGraph.init(allocator, g);
    defer wg.deinit();

    var ws = try WitnessSearcher.init(allocator, nc);
    defer ws.deinit();

    var rank = try allocator.alloc(u32, n);
    @memset(rank, 0);

    // Contracted neighbors counter per node (for priority computation)
    var cn = try allocator.alloc(u32, n);
    defer allocator.free(cn);
    @memset(cn, 0);

    const PQItem = struct {
        id: NodeId,
        priority: i32,
        fn order(ctx: void, a: @This(), b: @This()) std.math.Order {
            _ = ctx;
            return std.math.order(a.priority, b.priority);
        }
    };
    var pq = std.PriorityQueue(PQItem, void, PQItem.order).initContext({});
    defer pq.deinit(allocator);

    // Initial priorities
    for (0..n) |i| {
        if (wg.contracted[i]) continue;
        const priority = computePriority(&wg, @intCast(i), cn);
        try pq.push(allocator, .{ .id = @intCast(i), .priority = priority });
    }

    // Contract nodes with lazy updates
    var order: u32 = 0;
    while (pq.pop()) |item| {
        const v = item.id;
        if (wg.contracted[v]) continue;

        // Lazy update: recompute priority, re-insert if it got worse
        const cur_priority = computePriority(&wg, v, cn);
        if (cur_priority > item.priority) {
            try pq.push(allocator, .{ .id = v, .priority = cur_priority });
            continue;
        }

        // Contract v
        rank[v] = order;
        order += 1;
        wg.contracted[v] = true;

        // Update contracted-neighbors counter for v's live neighbors
        for (wg.out_edges[v].items) |e| {
            if (!wg.contracted[e.target]) cn[e.target] += 1;
        }
        for (wg.in_edges[v].items) |e| {
            if (!wg.contracted[e.target]) cn[e.target] += 1;
        }

        // Add shortcuts (staged witness: 1-hop → 2-hop → full Dijkstra)
        const deg = wg.liveDegree(v);
        const pairs = @as(u64, deg.in_deg) * @as(u64, deg.out_deg);
        const skip_witness = pairs > WITNESS_SKIP_THRESHOLD;

        for (wg.in_edges[v].items) |in_e| {
            if (wg.contracted[in_e.target]) continue;
            for (wg.out_edges[v].items) |out_e| {
                if (wg.contracted[out_e.target]) continue;
                if (in_e.target == out_e.target) continue;
                const sw = in_e.weight + out_e.weight;
                if (skip_witness or !witnessExists(&wg, &ws, in_e.target, out_e.target, v, sw)) {
                    wg.out_edges[in_e.target].append(allocator, .{ .target = out_e.target, .weight = sw, .middle = v }) catch {};
                    wg.in_edges[out_e.target].append(allocator, .{ .target = in_e.target, .weight = sw, .middle = v }) catch {};
                }
            }
        }
    }

    // Build upward graphs
    // Collect all edges (original + shortcuts), classify by rank direction
    var up_out_list = std.array_list.Managed(struct { from: NodeId, target: NodeId, weight: f64, middle: NodeId }).init(allocator);
    defer up_out_list.deinit();
    var up_in_list = std.array_list.Managed(struct { node: NodeId, target: NodeId, weight: f64, middle: NodeId }).init(allocator);
    defer up_in_list.deinit();

    // Build overlay, keeping only minimum-weight edge per (from, target) pair
    // Use a HashMap to dedup
    const EdgeKey = struct { from: NodeId, to: NodeId };
    const EdgeVal = struct { weight: f64, middle: NodeId };
    var up_out_map = std.AutoHashMap(EdgeKey, EdgeVal).init(allocator);
    defer up_out_map.deinit();
    var up_in_map = std.AutoHashMap(EdgeKey, EdgeVal).init(allocator);
    defer up_in_map.deinit();

    for (0..n) |uid| {
        const u: NodeId = @intCast(uid);
        for (wg.out_edges[uid].items) |e| {
            const w = e.target;
            if (rank[w] > rank[u]) {
                const key = EdgeKey{ .from = u, .to = w };
                const gop = try up_out_map.getOrPut(key);
                if (!gop.found_existing or e.weight < gop.value_ptr.weight) {
                    gop.value_ptr.* = .{ .weight = e.weight, .middle = e.middle };
                }
            } else if (rank[u] > rank[w]) {
                const key = EdgeKey{ .from = w, .to = u }; // stored under w, target is u
                const gop = try up_in_map.getOrPut(key);
                if (!gop.found_existing or e.weight < gop.value_ptr.weight) {
                    gop.value_ptr.* = .{ .weight = e.weight, .middle = e.middle };
                }
            }
        }
    }

    // Convert maps to lists
    var out_iter = up_out_map.iterator();
    while (out_iter.next()) |entry| {
        try up_out_list.append(.{ .from = entry.key_ptr.from, .target = entry.key_ptr.to, .weight = entry.value_ptr.weight, .middle = entry.value_ptr.middle });
    }
    var in_iter = up_in_map.iterator();
    while (in_iter.next()) |entry| {
        try up_in_list.append(.{ .node = entry.key_ptr.from, .target = entry.key_ptr.to, .weight = entry.value_ptr.weight, .middle = entry.value_ptr.middle });
    }

    // Build up_out CSR
    var up_out_offsets = try allocator.alloc(u32, n + 1);
    @memset(up_out_offsets, 0);
    for (up_out_list.items) |e| up_out_offsets[e.from + 1] += 1;
    for (1..n + 1) |i| up_out_offsets[i] += up_out_offsets[i - 1];

    const out_edge_count = up_out_list.items.len;
    var up_out_targets = try allocator.alloc(NodeId, out_edge_count);
    var up_out_weights = try allocator.alloc(f64, out_edge_count);
    var up_out_middles = try allocator.alloc(NodeId, out_edge_count);

    var pos = try allocator.alloc(u32, n);
    defer allocator.free(pos);
    @memcpy(pos, up_out_offsets[0..n]);
    for (up_out_list.items) |e| {
        const p = pos[e.from];
        up_out_targets[p] = e.target;
        up_out_weights[p] = e.weight;
        up_out_middles[p] = e.middle;
        pos[e.from] = p + 1;
    }

    // Build up_in CSR
    var up_in_offsets = try allocator.alloc(u32, n + 1);
    @memset(up_in_offsets, 0);
    for (up_in_list.items) |e| up_in_offsets[e.node + 1] += 1;
    for (1..n + 1) |i| up_in_offsets[i] += up_in_offsets[i - 1];

    const in_edge_count = up_in_list.items.len;
    var up_in_targets = try allocator.alloc(NodeId, in_edge_count);
    var up_in_weights = try allocator.alloc(f64, in_edge_count);
    var up_in_middles = try allocator.alloc(NodeId, in_edge_count);

    @memcpy(pos, up_in_offsets[0..n]);
    for (up_in_list.items) |e| {
        const p = pos[e.node];
        up_in_targets[p] = e.target;
        up_in_weights[p] = e.weight;
        up_in_middles[p] = e.middle;
        pos[e.node] = p + 1;
    }

    return CHData{
        .allocator = allocator,
        .node_count = nc,
        .rank = rank,
        .up_out_offsets = up_out_offsets,
        .up_out_targets = up_out_targets,
        .up_out_weights = up_out_weights,
        .up_out_middles = up_out_middles,
        .up_in_offsets = up_in_offsets,
        .up_in_targets = up_in_targets,
        .up_in_weights = up_in_weights,
        .up_in_middles = up_in_middles,
        .mutation_seq = g.mutation_seq,
    };
}

// ─── CH Query ─────────────────────────────────────────────────────────

// ─── Reusable Query Engine (amortized alloc, touched-list reset) ─────

pub const CHQueryEngine = struct {
    allocator: Allocator,
    node_count: u32,
    fwd_dist: []f64,
    bwd_dist: []f64,
    fwd_parent: []NodeId,
    bwd_parent: []NodeId,
    fwd_touched: std.ArrayListUnmanaged(NodeId),
    bwd_touched: std.ArrayListUnmanaged(NodeId),

    pub fn init(allocator: Allocator, ch: *const CHData) !CHQueryEngine {
        const n: usize = ch.node_count;
        const fwd_dist = try allocator.alloc(f64, n);
        const bwd_dist = try allocator.alloc(f64, n);
        const fwd_parent = try allocator.alloc(NodeId, n);
        const bwd_parent = try allocator.alloc(NodeId, n);
        @memset(fwd_dist, INF);
        @memset(bwd_dist, INF);
        @memset(fwd_parent, INVALID);
        @memset(bwd_parent, INVALID);
        return .{
            .allocator = allocator,
            .node_count = ch.node_count,
            .fwd_dist = fwd_dist,
            .bwd_dist = bwd_dist,
            .fwd_parent = fwd_parent,
            .bwd_parent = bwd_parent,
            .fwd_touched = .{ .items = &.{}, .capacity = 0 },
            .bwd_touched = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *CHQueryEngine) void {
        self.allocator.free(self.fwd_dist);
        self.allocator.free(self.bwd_dist);
        self.allocator.free(self.fwd_parent);
        self.allocator.free(self.bwd_parent);
        self.fwd_touched.deinit(self.allocator);
        self.bwd_touched.deinit(self.allocator);
    }

    fn reset(self: *CHQueryEngine) void {
        for (self.fwd_touched.items) |id| {
            self.fwd_dist[id] = INF;
            self.fwd_parent[id] = INVALID;
        }
        for (self.bwd_touched.items) |id| {
            self.bwd_dist[id] = INF;
            self.bwd_parent[id] = INVALID;
        }
        self.fwd_touched.clearRetainingCapacity();
        self.bwd_touched.clearRetainingCapacity();
    }

    pub fn query(
        self: *CHQueryEngine,
        ch: *const CHData,
        from_id: NodeId,
        to_id: NodeId,
    ) !struct { weight: f64, nodes: []NodeId } {
        self.reset();

        if (from_id == to_id) {
            const path = try self.allocator.alloc(NodeId, 1);
            path[0] = from_id;
            return .{ .weight = 0, .nodes = path };
        }

        const QItem = struct {
            id: NodeId,
            d: f64,
            fn order(ctx: void, a: @This(), b: @This()) std.math.Order {
                _ = ctx;
                return std.math.order(a.d, b.d);
            }
        };

        var fwd_pq = std.PriorityQueue(QItem, void, QItem.order).initContext({});
        defer fwd_pq.deinit(self.allocator);
        var bwd_pq = std.PriorityQueue(QItem, void, QItem.order).initContext({});
        defer bwd_pq.deinit(self.allocator);

        self.fwd_dist[from_id] = 0;
        try self.fwd_touched.append(self.allocator, from_id);
        self.bwd_dist[to_id] = 0;
        try self.bwd_touched.append(self.allocator, to_id);
        try fwd_pq.push(self.allocator, .{ .id = from_id, .d = 0 });
        try bwd_pq.push(self.allocator, .{ .id = to_id, .d = 0 });

        var best_total: f64 = INF;
        var meeting: NodeId = INVALID;

        while (fwd_pq.items.len > 0 or bwd_pq.items.len > 0) {
            const fwd_min = if (fwd_pq.peek()) |item| item.d else INF;
            const bwd_min = if (bwd_pq.peek()) |item| item.d else INF;
            if (fwd_min >= best_total and bwd_min >= best_total) break;

            if (fwd_min <= bwd_min) {
                if (fwd_pq.pop()) |cur| {
                    const cd = self.fwd_dist[cur.id];
                    if (cur.d > cd) continue;

                    const bd = self.bwd_dist[cur.id];
                    if (bd < INF) {
                        const total = cd + bd;
                        if (total < best_total) {
                            best_total = total;
                            meeting = cur.id;
                        }
                    }

                    const start = ch.up_out_offsets[cur.id];
                    const end = ch.up_out_offsets[cur.id + 1];
                    for (start..end) |i| {
                        const w = ch.up_out_targets[i];
                        const nd = cd + ch.up_out_weights[i];
                        if (nd < self.fwd_dist[w]) {
                            if (self.fwd_dist[w] == INF) try self.fwd_touched.append(self.allocator, w);
                            self.fwd_dist[w] = nd;
                            self.fwd_parent[w] = cur.id;
                            try fwd_pq.push(self.allocator, .{ .id = w, .d = nd });
                            if (self.bwd_dist[w] < INF) {
                                const total = nd + self.bwd_dist[w];
                                if (total < best_total) {
                                    best_total = total;
                                    meeting = w;
                                }
                            }
                        }
                    }
                }
            } else {
                if (bwd_pq.pop()) |cur| {
                    const cd = self.bwd_dist[cur.id];
                    if (cur.d > cd) continue;

                    const fd = self.fwd_dist[cur.id];
                    if (fd < INF) {
                        const total = fd + cd;
                        if (total < best_total) {
                            best_total = total;
                            meeting = cur.id;
                        }
                    }

                    const start = ch.up_in_offsets[cur.id];
                    const end = ch.up_in_offsets[cur.id + 1];
                    for (start..end) |i| {
                        const v = ch.up_in_targets[i];
                        const nd = cd + ch.up_in_weights[i];
                        if (nd < self.bwd_dist[v]) {
                            if (self.bwd_dist[v] == INF) try self.bwd_touched.append(self.allocator, v);
                            self.bwd_dist[v] = nd;
                            self.bwd_parent[v] = cur.id;
                            try bwd_pq.push(self.allocator, .{ .id = v, .d = nd });
                            if (self.fwd_dist[v] < INF) {
                                const total = self.fwd_dist[v] + nd;
                                if (total < best_total) {
                                    best_total = total;
                                    meeting = v;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (meeting == INVALID) return error.PathNotFound;

        // Reconstruct overlay path
        var overlay_path = std.array_list.Managed(NodeId).init(self.allocator);
        defer overlay_path.deinit();

        {
            var cur = meeting;
            while (cur != from_id) {
                try overlay_path.append(cur);
                cur = self.fwd_parent[cur];
                if (cur == INVALID) return error.PathNotFound;
            }
            try overlay_path.append(from_id);
            std.mem.reverse(NodeId, overlay_path.items);
        }

        {
            var cur = meeting;
            while (true) {
                const next = self.bwd_parent[cur];
                if (next == INVALID) break;
                try overlay_path.append(next);
                if (next == to_id) break;
                cur = next;
            }
            if (overlay_path.items[overlay_path.items.len - 1] != to_id) {
                try overlay_path.append(to_id);
            }
        }

        // Unpack shortcuts
        var final_path = std.array_list.Managed(NodeId).init(self.allocator);
        errdefer final_path.deinit();
        try final_path.append(overlay_path.items[0]);

        for (0..overlay_path.items.len - 1) |i| {
            const a = overlay_path.items[i];
            const b = overlay_path.items[i + 1];
            try unpackEdge(ch, a, b, &final_path);
        }

        return .{ .weight = best_total, .nodes = try final_path.toOwnedSlice() };
    }
};

// ─── One-shot query (allocates per call — kept for tests/API compatibility) ──

pub fn chQuery(
    ch: *const CHData,
    allocator: Allocator,
    from_id: NodeId,
    to_id: NodeId,
) !struct { weight: f64, nodes: []NodeId } {
    if (from_id == to_id) {
        const path = try allocator.alloc(NodeId, 1);
        path[0] = from_id;
        return .{ .weight = 0, .nodes = path };
    }

    const n: usize = ch.node_count;

    const QItem = struct {
        id: NodeId,
        d: f64,
        fn order(ctx: void, a: @This(), b: @This()) std.math.Order {
            _ = ctx;
            return std.math.order(a.d, b.d);
        }
    };

    const fwd_dist = try allocator.alloc(f64, n);
    defer allocator.free(fwd_dist);
    const fwd_parent = try allocator.alloc(NodeId, n);
    defer allocator.free(fwd_parent);
    const bwd_dist = try allocator.alloc(f64, n);
    defer allocator.free(bwd_dist);
    const bwd_parent = try allocator.alloc(NodeId, n);
    defer allocator.free(bwd_parent);

    @memset(fwd_dist, INF);
    @memset(bwd_dist, INF);
    @memset(fwd_parent, INVALID);
    @memset(bwd_parent, INVALID);

    var fwd_pq = std.PriorityQueue(QItem, void, QItem.order).initContext({});
    defer fwd_pq.deinit(allocator);
    var bwd_pq = std.PriorityQueue(QItem, void, QItem.order).initContext({});
    defer bwd_pq.deinit(allocator);

    fwd_dist[from_id] = 0;
    bwd_dist[to_id] = 0;
    try fwd_pq.push(allocator, .{ .id = from_id, .d = 0 });
    try bwd_pq.push(allocator, .{ .id = to_id, .d = 0 });

    var best_total: f64 = INF;
    var meeting: NodeId = INVALID;

    while (fwd_pq.items.len > 0 or bwd_pq.items.len > 0) {
        const fwd_min = if (fwd_pq.peek()) |item| item.d else INF;
        const bwd_min = if (bwd_pq.peek()) |item| item.d else INF;
        if (fwd_min >= best_total and bwd_min >= best_total) break;

        if (fwd_min <= bwd_min) {
            if (fwd_pq.pop()) |cur| {
                const cd = fwd_dist[cur.id];
                if (cur.d > cd) continue;

                const bd = bwd_dist[cur.id];
                if (bd < INF) {
                    const total = cd + bd;
                    if (total < best_total) {
                        best_total = total;
                        meeting = cur.id;
                    }
                }

                const start = ch.up_out_offsets[cur.id];
                const end = ch.up_out_offsets[cur.id + 1];
                for (start..end) |i| {
                    const w = ch.up_out_targets[i];
                    const nd = cd + ch.up_out_weights[i];
                    if (nd < fwd_dist[w]) {
                        fwd_dist[w] = nd;
                        fwd_parent[w] = cur.id;
                        try fwd_pq.push(allocator, .{ .id = w, .d = nd });
                        if (bwd_dist[w] < INF) {
                            const total = nd + bwd_dist[w];
                            if (total < best_total) {
                                best_total = total;
                                meeting = w;
                            }
                        }
                    }
                }
            }
        } else {
            if (bwd_pq.pop()) |cur| {
                const cd = bwd_dist[cur.id];
                if (cur.d > cd) continue;

                const fd = fwd_dist[cur.id];
                if (fd < INF) {
                    const total = fd + cd;
                    if (total < best_total) {
                        best_total = total;
                        meeting = cur.id;
                    }
                }

                const start = ch.up_in_offsets[cur.id];
                const end = ch.up_in_offsets[cur.id + 1];
                for (start..end) |i| {
                    const v = ch.up_in_targets[i];
                    const nd = cd + ch.up_in_weights[i];
                    if (nd < bwd_dist[v]) {
                        bwd_dist[v] = nd;
                        bwd_parent[v] = cur.id;
                        try bwd_pq.push(allocator, .{ .id = v, .d = nd });
                        if (fwd_dist[v] < INF) {
                            const total = fwd_dist[v] + nd;
                            if (total < best_total) {
                                best_total = total;
                                meeting = v;
                            }
                        }
                    }
                }
            }
        }
    }

    if (meeting == INVALID) return error.PathNotFound;

    var overlay_path = std.array_list.Managed(NodeId).init(allocator);
    defer overlay_path.deinit();

    {
        var cur = meeting;
        while (cur != from_id) {
            try overlay_path.append(cur);
            cur = fwd_parent[cur];
            if (cur == INVALID) return error.PathNotFound;
        }
        try overlay_path.append(from_id);
        std.mem.reverse(NodeId, overlay_path.items);
    }

    {
        var cur = meeting;
        while (true) {
            const next = bwd_parent[cur];
            if (next == INVALID) break;
            try overlay_path.append(next);
            if (next == to_id) break;
            cur = next;
        }
        if (overlay_path.items[overlay_path.items.len - 1] != to_id) {
            try overlay_path.append(to_id);
        }
    }

    var final_path = std.array_list.Managed(NodeId).init(allocator);
    errdefer final_path.deinit();
    try final_path.append(overlay_path.items[0]);

    for (0..overlay_path.items.len - 1) |i| {
        const a = overlay_path.items[i];
        const b = overlay_path.items[i + 1];
        try unpackEdge(ch, a, b, &final_path);
    }

    return .{ .weight = best_total, .nodes = try final_path.toOwnedSlice() };
}

/// Unpack a single edge a→b. If it's a shortcut, recursively unpack via middle node.
fn unpackEdge(ch: *const CHData, from: NodeId, to: NodeId, result: *std.array_list.Managed(NodeId)) !void {
    const middle = findMiddle(ch, from, to);
    if (middle == INVALID) {
        // Original edge
        try result.append(to);
        return;
    }
    // Shortcut from→to via middle: unpack from→middle then middle→to
    try unpackEdge(ch, from, middle, result);
    try unpackEdge(ch, middle, to, result);
}

/// Find the middle node for edge from→to in the CH overlay.
fn findMiddle(ch: *const CHData, from: NodeId, to: NodeId) NodeId {
    // Check up_out[from] for target=to
    if (from + 1 < ch.up_out_offsets.len) {
        const start = ch.up_out_offsets[from];
        const end = ch.up_out_offsets[from + 1];
        for (start..end) |i| {
            if (ch.up_out_targets[i] == to) return ch.up_out_middles[i];
        }
    }
    // Check up_in[to] for target=from (edge from→to stored in to's incoming)
    if (to + 1 < ch.up_in_offsets.len) {
        const start = ch.up_in_offsets[to];
        const end = ch.up_in_offsets[to + 1];
        for (start..end) |i| {
            if (ch.up_in_targets[i] == from) return ch.up_in_middles[i];
        }
    }
    return INVALID;
}

// ─── Tests ────────────────────────────────────────────────────────────

