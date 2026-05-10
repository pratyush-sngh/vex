const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const NodeId = graph_mod.NodeId;
const GraphEngine = graph_mod.GraphEngine;
const CSR = graph_mod.CSR;

const INVALID: NodeId = graph_mod.INVALID_ID;
const INF: f64 = std.math.inf(f64);
const WITNESS_MAX_SETTLED: u32 = 100;

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

// ─── Witness Search ───────────────────────────────────────────────────

/// Returns true if there's a path from `source` to `target` (avoiding `avoid`)
/// with total weight <= max_weight, considering only non-contracted nodes.
fn witnessExists(
    wg: *const WorkGraph,
    source: NodeId,
    target: NodeId,
    avoid: NodeId,
    max_weight: f64,
    allocator: Allocator,
) bool {
    if (source == target) return true;

    const WItem = struct {
        id: NodeId,
        d: f64,
        fn order(ctx: void, a: @This(), b: @This()) std.math.Order {
            _ = ctx;
            return std.math.order(a.d, b.d);
        }
    };

    var dist = std.AutoHashMap(NodeId, f64).init(allocator);
    defer dist.deinit();
    var pq = std.PriorityQueue(WItem, void, WItem.order).initContext({});
    defer pq.deinit(allocator);

    dist.put(source, 0) catch return false;
    pq.push(allocator, .{ .id = source, .d = 0 }) catch return false;

    var settled: u32 = 0;
    while (pq.pop()) |cur| {
        if (cur.id == target and cur.d <= max_weight) return true;
        const cd = dist.get(cur.id) orelse continue;
        if (cur.d > cd) continue;
        if (cur.d > max_weight) return false;
        if (settled >= WITNESS_MAX_SETTLED) return false;
        settled += 1;

        for (wg.out_edges[cur.id].items) |e| {
            if (e.target == avoid) continue;
            if (wg.contracted[e.target]) continue;
            const nd = cur.d + e.weight;
            if (nd > max_weight) continue;
            const existing = dist.get(e.target);
            if (existing == null or nd < existing.?) {
                dist.put(e.target, nd) catch continue;
                pq.push(allocator, .{ .id = e.target, .d = nd }) catch continue;
            }
        }
    }
    return false;
}

// ─── Node Ordering ────────────────────────────────────────────────────

fn computePriority(wg: *const WorkGraph, v: NodeId) i32 {
    if (wg.contracted[v]) return std.math.maxInt(i32);

    const deg = wg.liveDegree(v);
    const in_deg = deg.in_deg;
    const out_deg = deg.out_deg;

    // Upper bound on shortcuts (no witness search — that only happens during contraction)
    // edge_diff = shortcuts_upper_bound - edges_removed
    const edge_diff: i32 = @as(i32, @intCast(in_deg * out_deg)) - @as(i32, @intCast(in_deg)) - @as(i32, @intCast(out_deg));
    return edge_diff;
}

// ─── Build CH ─────────────────────────────────────────────────────────

pub fn build(g: *const GraphEngine, allocator: Allocator) !CHData {
    const nc: u32 = @intCast(g.node_keys.items.len);
    const n: usize = nc;

    var wg = try WorkGraph.init(allocator, g);
    defer wg.deinit();

    var rank = try allocator.alloc(u32, n);
    @memset(rank, 0);

    // Priority queue for node ordering
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

    // Initial priorities (edge-diff upper bound, no witness search)
    for (0..n) |i| {
        if (wg.contracted[i]) continue;
        const priority = computePriority(&wg, @intCast(i));
        try pq.push(allocator, .{ .id = @intCast(i), .priority = priority });
    }

    // Contract nodes with lazy updates
    var order: u32 = 0;
    while (pq.pop()) |item| {
        const v = item.id;
        if (wg.contracted[v]) continue;

        // Lazy update: recompute priority, re-insert if it got worse
        const cur_priority = computePriority(&wg, v);
        if (cur_priority > item.priority) {
            try pq.push(allocator, .{ .id = v, .priority = cur_priority });
            continue;
        }

        // Contract v
        rank[v] = order;
        order += 1;
        wg.contracted[v] = true;

        // Add shortcuts
        for (wg.in_edges[v].items) |in_e| {
            if (wg.contracted[in_e.target]) continue;
            for (wg.out_edges[v].items) |out_e| {
                if (wg.contracted[out_e.target]) continue;
                if (in_e.target == out_e.target) continue;
                const sw = in_e.weight + out_e.weight;
                if (!witnessExists(&wg, in_e.target, out_e.target, v, sw, allocator)) {
                    // Add shortcut — always append (dedup at overlay build time)
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

test "ch basic correctness" {
    const allocator = std.testing.allocator;
    const query = @import("query.zig");

    var g = GraphEngine.init(allocator);
    defer g.deinit();

    // Build a small weighted graph: 5 nodes, non-uniform weights
    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addNode("d", "t");
    _ = try g.addNode("e", "t");

    _ = try g.addEdge("a", "b", "e", 1.0);
    _ = try g.addEdge("b", "c", "e", 2.0);
    _ = try g.addEdge("a", "c", "e", 10.0); // direct but expensive
    _ = try g.addEdge("c", "d", "e", 1.0);
    _ = try g.addEdge("d", "e", "e", 1.0);
    _ = try g.addEdge("a", "e", "e", 20.0); // direct but very expensive

    try g.compact();

    // Dijkstra reference
    var ref = try query.weightedShortestPath(&g, allocator, "a", "e");
    defer ref.deinit(allocator);

    // Build CH
    var ch = try build(&g, allocator);
    defer ch.deinit();

    // CH query
    const from_id = g.resolveKey("a").?;
    const to_id = g.resolveKey("e").?;
    const ch_result = try chQuery(&ch, allocator, from_id, to_id);
    defer allocator.free(ch_result.nodes);

    // Weights must match
    try std.testing.expectApproxEqAbs(ref.total_weight, ch_result.weight, 1e-9);
    // Both should find path a→b→c→d→e with weight 5.0
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), ch_result.weight, 1e-9);
}

test "ch larger graph validation" {
    const allocator = std.testing.allocator;
    const query = @import("query.zig");

    var g = GraphEngine.init(allocator);
    defer g.deinit();

    // Build 100-node graph with varied weights
    const N = 100;
    var keys: [N][]const u8 = undefined;
    for (0..N) |i| {
        keys[i] = try std.fmt.allocPrint(allocator, "n{d}", .{i});
        _ = try g.addNode(keys[i], "t");
    }
    defer for (0..N) |i| allocator.free(keys[i]);

    for (0..N) |i| {
        for (0..3) |j| {
            const target = (i + j * 7 + 1) % N;
            const w: f64 = @as(f64, @floatFromInt((i * 3 + j * 5) % 10 + 1));
            _ = g.addEdge(keys[i], keys[target], "e", w) catch continue;
        }
    }
    try g.compact();

    // Build CH
    var ch = try build(&g, allocator);
    defer ch.deinit();

    // Validate 50 random queries against Dijkstra
    var mismatches: u32 = 0;
    var not_found_errors: u32 = 0;
    var weight_errors: u32 = 0;
    for (0..50) |i| {
        const s: NodeId = @intCast((i * 7) % N);
        const t: NodeId = @intCast((i * 13 + 50) % N);
        if (s == t) continue;

        const ref_result = query.weightedShortestPath(&g, allocator, keys[s], keys[t]) catch {
            // Dijkstra not found — CH should also not find
            const ch_r = chQuery(&ch, allocator, s, t) catch continue;
            allocator.free(ch_r.nodes);
            mismatches += 1; // CH found but Dijkstra didn't
            continue;
        };
        var ref_mut = ref_result;
        defer ref_mut.deinit(allocator);

        const ch_r = chQuery(&ch, allocator, s, t) catch {
            mismatches += 1;
            not_found_errors += 1;
            continue;
        };
        defer allocator.free(ch_r.nodes);

        if (@abs(ref_mut.total_weight - ch_r.weight) > 1e-9) {
            mismatches += 1;
            weight_errors += 1;
            if (weight_errors <= 3) {
                std.debug.print("  MISMATCH s={d} t={d} CH={d:.2} Dijkstra={d:.2}\n", .{ s, t, ch_r.weight, ref_mut.total_weight });
            }
        }
    }

    if (mismatches > 0) {
        std.debug.print("CH validation: {d} mismatches (not_found={d}, weight={d}) out of 50\n", .{ mismatches, not_found_errors, weight_errors });
    }
    try std.testing.expectEqual(@as(u32, 0), mismatches);
}
