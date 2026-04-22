const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const CSR = graph_mod.CSR;
const DeltaEdge = graph_mod.DeltaEdge;
const StringIntern = @import("string_intern.zig").StringIntern;
const TypeMask = @import("string_intern.zig").TypeMask;

pub const Direction = enum { outgoing, incoming, both };

pub const TraversalOptions = struct {
    max_depth: u32 = 10,
    direction: Direction = .outgoing,
    edge_type_filter: ?[]const u8 = null,
    node_type_filter: ?[]const u8 = null,
};

pub const PathResult = struct {
    nodes: []NodeId,
    total_weight: f64,

    pub fn deinit(self: *PathResult, allocator: Allocator) void {
        allocator.free(self.nodes);
    }
};

/// BFS traversal with three CSR optimizations:
///   1. all_base_edges_alive fast path — skips edge_alive check + edge_idx load
///   2. Flat delta scan — linear scan of small delta edge list
///   3. Prefetching — prefetch next node's CSR offsets during current node processing
pub fn traverse(
    g: *const GraphEngine,
    allocator: Allocator,
    start_key: []const u8,
    opts: TraversalOptions,
) ![]NodeId {
    const start_id = g.resolveKey(start_key) orelse return error.NodeNotFound;
    const node_cap = g.node_keys.items.len;

    var visited = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer visited.deinit();

    var result = std.array_list.Managed(NodeId).init(allocator);
    errdefer result.deinit();

    const QueueItem = struct { id: NodeId, depth: u32 };
    var queue = std.array_list.Managed(QueueItem).init(allocator);
    defer queue.deinit();

    // Resolve type filter to bitmask once
    const edge_type_mask: TypeMask = if (opts.edge_type_filter) |filter|
        if (g.type_intern.find(filter)) |id| StringIntern.mask(id) else 0
    else
        0;
    const node_type_id: ?u16 = if (opts.node_type_filter) |filter|
        g.type_intern.find(filter)
    else
        null;

    if (opts.edge_type_filter != null and edge_type_mask == 0) {
        try result.append(start_id);
        return result.toOwnedSlice();
    }

    try queue.append(.{ .id = start_id, .depth = 0 });
    visited.set(start_id);

    const all_alive = g.all_base_edges_alive;
    const has_delta = g.delta_edges.items.len > 0;

    var head: usize = 0;
    while (head < queue.items.len) {
        const item = queue.items[head];
        head += 1;

        try result.append(item.id);
        if (item.depth >= opts.max_depth) continue;

        // ── FIX 3: Prefetch next node's CSR offsets ──
        if (head < queue.items.len) {
            const next_id = queue.items[head].id;
            prefetchCSROffsets(&g.base_out, next_id);
        }

        // Early exit: check node's edge type mask
        if (edge_type_mask != 0) {
            const node_mask = switch (opts.direction) {
                .outgoing => g.node_out_type_mask.items[item.id],
                .incoming => g.node_in_type_mask.items[item.id],
                .both => g.node_out_type_mask.items[item.id] | g.node_in_type_mask.items[item.id],
            };
            if (node_mask & edge_type_mask == 0) continue;
        }

        // ── Scan base CSR ──
        const csrs = getCSRs(g, item.id, opts.direction);
        for (csrs) |csr| {
            const targets = csr.neighbors(item.id);
            if (targets.len == 0) continue;

            if (all_alive and edge_type_mask == 0 and node_type_id == null) {
                // ── FIX 1: Fast path — no edge_idx load, no alive check ──
                for (targets) |neighbor_id| {
                    if (!g.node_alive.isSet(neighbor_id)) continue;
                    if (visited.isSet(neighbor_id)) continue;
                    visited.set(neighbor_id);
                    try queue.append(.{ .id = neighbor_id, .depth = item.depth + 1 });
                }
            } else {
                // Slow path — need edge_idx for alive/type checks
                const edge_indices = csr.edgeIndices(item.id);
                for (targets, edge_indices) |neighbor_id, eidx| {
                    if (!g.edge_alive.isSet(eidx)) continue;
                    if (!g.node_alive.isSet(neighbor_id)) continue;
                    if (visited.isSet(neighbor_id)) continue;

                    if (edge_type_mask != 0) {
                        const emask = StringIntern.mask(g.edge_type_id.items[eidx]);
                        if (edge_type_mask & emask == 0) continue;
                    }
                    if (node_type_id) |ntid| {
                        if (g.node_type_id.items[neighbor_id] != ntid) continue;
                    }

                    visited.set(neighbor_id);
                    try queue.append(.{ .id = neighbor_id, .depth = item.depth + 1 });
                }
            }
        }

        // ── FIX 2: Scan flat delta edges (linear, typically <100 entries) ──
        if (has_delta) {
            for (g.delta_edges.items) |de| {
                const matches = switch (opts.direction) {
                    .outgoing => de.from == item.id,
                    .incoming => de.to == item.id,
                    .both => de.from == item.id or de.to == item.id,
                };
                if (!matches) continue;
                if (!g.edge_alive.isSet(de.eidx)) continue;

                const neighbor_id = if (de.from == item.id) de.to else de.from;
                if (!g.node_alive.isSet(neighbor_id)) continue;
                if (visited.isSet(neighbor_id)) continue;

                if (edge_type_mask != 0) {
                    const emask = StringIntern.mask(g.edge_type_id.items[de.eidx]);
                    if (edge_type_mask & emask == 0) continue;
                }
                if (node_type_id) |ntid| {
                    if (g.node_type_id.items[neighbor_id] != ntid) continue;
                }

                visited.set(neighbor_id);
                try queue.append(.{ .id = neighbor_id, .depth = item.depth + 1 });
            }
        }
    }

    return result.toOwnedSlice();
}

/// BFS shortest path (unweighted).
pub fn shortestPath(
    g: *const GraphEngine,
    allocator: Allocator,
    from_key: []const u8,
    to_key: []const u8,
    max_depth: u32,
) !PathResult {
    const from_id = g.resolveKey(from_key) orelse return error.NodeNotFound;
    const to_id = g.resolveKey(to_key) orelse return error.NodeNotFound;

    if (from_id == to_id) {
        const path = try allocator.alloc(NodeId, 1);
        path[0] = from_id;
        return PathResult{ .nodes = path, .total_weight = 0 };
    }

    var visited = try std.DynamicBitSet.initEmpty(allocator, g.node_keys.items.len);
    defer visited.deinit();

    var parent = std.AutoHashMap(NodeId, NodeId).init(allocator);
    defer parent.deinit();

    const QueueItem = struct { id: NodeId, depth: u32 };
    var queue = std.array_list.Managed(QueueItem).init(allocator);
    defer queue.deinit();

    visited.set(from_id);
    try parent.put(from_id, graph_mod.INVALID_ID);
    try queue.append(.{ .id = from_id, .depth = 0 });

    const all_alive = g.all_base_edges_alive;
    const has_delta = g.delta_edges.items.len > 0;

    var head: usize = 0;
    while (head < queue.items.len) {
        const item = queue.items[head];
        head += 1;

        if (item.depth >= max_depth) continue;

        // Prefetch
        if (head < queue.items.len) {
            prefetchCSROffsets(&g.base_out, queue.items[head].id);
            prefetchCSROffsets(&g.base_in, queue.items[head].id);
        }

        // Both directions for undirected path
        const csrs = getCSRs(g, item.id, .both);
        for (csrs) |csr| {
            const targets = csr.neighbors(item.id);
            if (targets.len == 0) continue;

            if (all_alive) {
                for (targets) |neighbor_id| {
                    if (!g.node_alive.isSet(neighbor_id)) continue;
                    if (visited.isSet(neighbor_id)) continue;
                    visited.set(neighbor_id);
                    try parent.put(neighbor_id, item.id);
                    if (neighbor_id == to_id) return reconstructPath(allocator, &parent, from_id, to_id);
                    try queue.append(.{ .id = neighbor_id, .depth = item.depth + 1 });
                }
            } else {
                const edge_indices = csr.edgeIndices(item.id);
                for (targets, edge_indices) |neighbor_id, eidx| {
                    if (!g.edge_alive.isSet(eidx)) continue;
                    if (!g.node_alive.isSet(neighbor_id)) continue;
                    if (visited.isSet(neighbor_id)) continue;
                    visited.set(neighbor_id);
                    try parent.put(neighbor_id, item.id);
                    if (neighbor_id == to_id) return reconstructPath(allocator, &parent, from_id, to_id);
                    try queue.append(.{ .id = neighbor_id, .depth = item.depth + 1 });
                }
            }
        }

        // Delta edges (both directions for path finding)
        if (has_delta) {
            for (g.delta_edges.items) |de| {
                if (de.from != item.id and de.to != item.id) continue;
                if (!g.edge_alive.isSet(de.eidx)) continue;
                const neighbor_id = if (de.from == item.id) de.to else de.from;
                if (!g.node_alive.isSet(neighbor_id)) continue;
                if (visited.isSet(neighbor_id)) continue;
                visited.set(neighbor_id);
                try parent.put(neighbor_id, item.id);
                if (neighbor_id == to_id) return reconstructPath(allocator, &parent, from_id, to_id);
                try queue.append(.{ .id = neighbor_id, .depth = item.depth + 1 });
            }
        }
    }

    return error.PathNotFound;
}

/// Dijkstra's algorithm for weighted shortest path.
pub fn weightedShortestPath(
    g: *const GraphEngine,
    allocator: Allocator,
    from_key: []const u8,
    to_key: []const u8,
) !PathResult {
    const from_id = g.resolveKey(from_key) orelse return error.NodeNotFound;
    const to_id = g.resolveKey(to_key) orelse return error.NodeNotFound;

    if (from_id == to_id) {
        const path = try allocator.alloc(NodeId, 1);
        path[0] = from_id;
        return PathResult{ .nodes = path, .total_weight = 0 };
    }

    const DijkItem = struct {
        id: NodeId,
        dist: f64,

        fn order(ctx: void, a: @This(), b: @This()) std.math.Order {
            _ = ctx;
            return std.math.order(a.dist, b.dist);
        }
    };

    var dist = std.AutoHashMap(NodeId, f64).init(allocator);
    defer dist.deinit();
    var parent_map = std.AutoHashMap(NodeId, NodeId).init(allocator);
    defer parent_map.deinit();

    var pq = std.PriorityQueue(DijkItem, void, DijkItem.order).initContext({});
    defer pq.deinit(allocator);

    try dist.put(from_id, 0);
    try parent_map.put(from_id, graph_mod.INVALID_ID);
    try pq.push(allocator, .{ .id = from_id, .dist = 0 });

    const all_alive = g.all_base_edges_alive;

    while (pq.pop()) |current| {
        if (current.id == to_id) {
            return reconstructWeightedPath(allocator, &parent_map, &dist, from_id, to_id);
        }

        const current_dist = dist.get(current.id) orelse continue;
        if (current.dist > current_dist) continue;

        // Base CSR outgoing
        const out_targets = g.base_out.neighbors(current.id);
        const out_eidxs = g.base_out.edgeIndices(current.id);

        if (all_alive) {
            for (out_targets, out_eidxs) |neighbor_id, eidx| {
                const new_dist = current_dist + g.edge_weight.items[eidx];
                const existing = dist.get(neighbor_id);
                if (existing == null or new_dist < existing.?) {
                    try dist.put(neighbor_id, new_dist);
                    try parent_map.put(neighbor_id, current.id);
                    try pq.push(allocator, .{ .id = neighbor_id, .dist = new_dist });
                }
            }
        } else {
            for (out_targets, out_eidxs) |neighbor_id, eidx| {
                if (!g.edge_alive.isSet(eidx)) continue;
                const new_dist = current_dist + g.edge_weight.items[eidx];
                const existing = dist.get(neighbor_id);
                if (existing == null or new_dist < existing.?) {
                    try dist.put(neighbor_id, new_dist);
                    try parent_map.put(neighbor_id, current.id);
                    try pq.push(allocator, .{ .id = neighbor_id, .dist = new_dist });
                }
            }
        }

        // Delta edges (outgoing only for Dijkstra)
        for (g.delta_edges.items) |de| {
            if (de.from != current.id) continue;
            if (!g.edge_alive.isSet(de.eidx)) continue;
            const new_dist = current_dist + g.edge_weight.items[de.eidx];
            const existing = dist.get(de.to);
            if (existing == null or new_dist < existing.?) {
                try dist.put(de.to, new_dist);
                try parent_map.put(de.to, current.id);
                try pq.push(allocator, .{ .id = de.to, .dist = new_dist });
            }
        }
    }

    return error.PathNotFound;
}

/// Get direct neighbors of a node.
///
/// Three-tier optimization:
///   1. Zero-copy fast path: post-compact, single direction, no delta → dupe CSR slice directly
///   2. Inline dedup: ≤ 64 neighbors → stack-based u32 set, no heap allocation for dedup
///   3. Full bitset dedup: > 64 neighbors or complex case → DynamicBitSet (original path)
pub fn neighbors(
    g: *const GraphEngine,
    allocator: Allocator,
    key: []const u8,
    direction: Direction,
) ![]NodeId {
    const id = g.resolveKey(key) orelse return error.NodeNotFound;

    const no_delta = g.delta_edges.items.len == 0;
    const all_alive = g.all_base_edges_alive;
    const single_dir = direction != .both;

    // ── Tier 1: Zero-copy fast path ──
    // Post-compact, single direction, no delta, all alive:
    // CSR targets are already the exact answer. Just dupe the slice.
    if (all_alive and no_delta and single_dir) {
        const csr = if (direction == .outgoing) &g.base_out else &g.base_in;
        const targets = csr.neighbors(id);
        // Filter out dead nodes (rare post-compact, but possible if a node was
        // deleted without re-compact). For most cases this copies everything.
        var count: usize = 0;
        for (targets) |nid| {
            if (g.node_alive.isSet(nid)) count += 1;
        }
        if (count == targets.len) {
            // All alive — direct dupe, zero dedup overhead
            return allocator.dupe(NodeId, targets);
        }
        // Some dead — filter copy
        const result = try allocator.alloc(NodeId, count);
        var i: usize = 0;
        for (targets) |nid| {
            if (g.node_alive.isSet(nid)) {
                result[i] = nid;
                i += 1;
            }
        }
        return result;
    }

    // ── Tier 2: Inline dedup for small neighbor counts ──
    // Use a stack-allocated array to track seen IDs (no heap alloc for dedup).
    const INLINE_CAP = 64;
    var inline_seen: [INLINE_CAP]NodeId = undefined;
    var inline_count: usize = 0;
    var ids = std.array_list.Managed(NodeId).init(allocator);
    errdefer ids.deinit();

    const csrs = getCSRs(g, id, direction);
    for (csrs) |csr| {
        const targets = csr.neighbors(id);
        if (targets.len == 0) continue;

        if (all_alive) {
            for (targets) |neighbor_id| {
                if (!g.node_alive.isSet(neighbor_id)) continue;
                if (inline_count < INLINE_CAP) {
                    if (inlineContains(&inline_seen, inline_count, neighbor_id)) continue;
                    inline_seen[inline_count] = neighbor_id;
                    inline_count += 1;
                    try ids.append(neighbor_id);
                } else {
                    // Overflow — fall through to full bitset path below
                    return neighborsFull(g, allocator, id, direction, &ids, &inline_seen, inline_count);
                }
            }
        } else {
            const edge_indices = csr.edgeIndices(id);
            for (targets, edge_indices) |neighbor_id, eidx| {
                if (!g.edge_alive.isSet(eidx)) continue;
                if (!g.node_alive.isSet(neighbor_id)) continue;
                if (inline_count < INLINE_CAP) {
                    if (inlineContains(&inline_seen, inline_count, neighbor_id)) continue;
                    inline_seen[inline_count] = neighbor_id;
                    inline_count += 1;
                    try ids.append(neighbor_id);
                } else {
                    return neighborsFull(g, allocator, id, direction, &ids, &inline_seen, inline_count);
                }
            }
        }
    }

    // Delta
    for (g.delta_edges.items) |de| {
        const matches = switch (direction) {
            .outgoing => de.from == id,
            .incoming => de.to == id,
            .both => de.from == id or de.to == id,
        };
        if (!matches) continue;
        if (!g.edge_alive.isSet(de.eidx)) continue;
        const neighbor_id = if (de.from == id) de.to else de.from;
        if (!g.node_alive.isSet(neighbor_id)) continue;
        if (inline_count < INLINE_CAP) {
            if (inlineContains(&inline_seen, inline_count, neighbor_id)) continue;
            inline_seen[inline_count] = neighbor_id;
            inline_count += 1;
            try ids.append(neighbor_id);
        } else {
            return neighborsFull(g, allocator, id, direction, &ids, &inline_seen, inline_count);
        }
    }

    return ids.toOwnedSlice();
}

/// Tier 3 fallback: full bitset dedup for nodes with > 64 neighbors.
fn neighborsFull(
    g: *const GraphEngine,
    allocator: Allocator,
    id: NodeId,
    direction: Direction,
    ids: *std.array_list.Managed(NodeId),
    already_seen: []const NodeId,
    already_count: usize,
) ![]NodeId {
    var seen = try std.DynamicBitSet.initEmpty(allocator, g.node_keys.items.len);
    defer seen.deinit();

    // Mark what we already found
    for (already_seen[0..already_count]) |nid| seen.set(nid);

    const all_alive = g.all_base_edges_alive;
    const csrs = getCSRs(g, id, direction);

    // Continue scanning CSR from where inline left off (we re-scan but skip already-seen via bitset)
    for (csrs) |csr| {
        const targets = csr.neighbors(id);
        if (all_alive) {
            for (targets) |neighbor_id| {
                if (!g.node_alive.isSet(neighbor_id)) continue;
                if (seen.isSet(neighbor_id)) continue;
                seen.set(neighbor_id);
                try ids.append(neighbor_id);
            }
        } else {
            const edge_indices = csr.edgeIndices(id);
            for (targets, edge_indices) |neighbor_id, eidx| {
                if (!g.edge_alive.isSet(eidx)) continue;
                if (!g.node_alive.isSet(neighbor_id)) continue;
                if (seen.isSet(neighbor_id)) continue;
                seen.set(neighbor_id);
                try ids.append(neighbor_id);
            }
        }
    }

    for (g.delta_edges.items) |de| {
        const matches = switch (direction) {
            .outgoing => de.from == id,
            .incoming => de.to == id,
            .both => de.from == id or de.to == id,
        };
        if (!matches) continue;
        if (!g.edge_alive.isSet(de.eidx)) continue;
        const neighbor_id = if (de.from == id) de.to else de.from;
        if (!g.node_alive.isSet(neighbor_id)) continue;
        if (seen.isSet(neighbor_id)) continue;
        seen.set(neighbor_id);
        try ids.append(neighbor_id);
    }

    return ids.toOwnedSlice();
}

fn inlineContains(buf: []const NodeId, count: usize, val: NodeId) bool {
    for (buf[0..count]) |v| {
        if (v == val) return true;
    }
    return false;
}

// ─── Internal helpers ─────────────────────────────────────────────────

fn getCSRs(g: *const GraphEngine, id: NodeId, direction: Direction) [2]*const CSR {
    _ = id;
    return switch (direction) {
        .outgoing => .{ &g.base_out, &g.base_out }, // second unused, checked via neighbors len
        .incoming => .{ &g.base_in, &g.base_in },
        .both => .{ &g.base_out, &g.base_in },
    };
}

fn prefetchCSROffsets(csr: *const CSR, node_id: NodeId) void {
    if (csr.offsets.len == 0) return;
    if (node_id + 1 >= csr.offsets.len) return;
    // Prefetch the offsets for this node — hides L2 latency
    const ptr: [*]const u8 = @ptrCast(&csr.offsets[node_id]);
    @prefetch(ptr, .{ .rw = .read, .locality = 1 });
}

fn reconstructPath(
    allocator: Allocator,
    parent_map: *std.AutoHashMap(NodeId, NodeId),
    from_id: NodeId,
    to_id: NodeId,
) !PathResult {
    var path = std.array_list.Managed(NodeId).init(allocator);
    errdefer path.deinit();

    var current = to_id;
    while (current != from_id) {
        try path.append(current);
        current = parent_map.get(current) orelse return error.PathNotFound;
    }
    try path.append(from_id);

    std.mem.reverse(NodeId, path.items);
    return PathResult{ .nodes = try path.toOwnedSlice(), .total_weight = 0 };
}

fn reconstructWeightedPath(
    allocator: Allocator,
    parent_map: *std.AutoHashMap(NodeId, NodeId),
    dist_map: *std.AutoHashMap(NodeId, f64),
    from_id: NodeId,
    to_id: NodeId,
) !PathResult {
    var path = std.array_list.Managed(NodeId).init(allocator);
    errdefer path.deinit();

    var current = to_id;
    while (current != from_id) {
        try path.append(current);
        current = parent_map.get(current) orelse return error.PathNotFound;
    }
    try path.append(from_id);

    std.mem.reverse(NodeId, path.items);
    const total = dist_map.get(to_id) orelse 0;
    return PathResult{ .nodes = try path.toOwnedSlice(), .total_weight = total };
}

// ─── Tests ────────────────────────────────────────────────────────────

test "traverse BFS outgoing" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);
    _ = try g.addEdge("b", "c", "link", 1.0);

    // Test with delta (no compact)
    const r1 = try traverse(&g, std.testing.allocator, "a", .{ .max_depth = 5 });
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqual(@as(usize, 3), r1.len);

    // Test after compact (base CSR, all_alive fast path)
    try g.compact();
    const r2 = try traverse(&g, std.testing.allocator, "a", .{ .max_depth = 5 });
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqual(@as(usize, 3), r2.len);
}

test "shortest path" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addNode("d", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);
    _ = try g.addEdge("b", "c", "link", 1.0);
    _ = try g.addEdge("a", "d", "link", 1.0);
    _ = try g.addEdge("d", "c", "link", 1.0);

    try g.compact();
    var result = try shortestPath(&g, std.testing.allocator, "a", "c", 10);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expectEqual(@as(NodeId, 0), result.nodes[0]);
    try std.testing.expectEqual(@as(NodeId, 2), result.nodes[result.nodes.len - 1]);
}

test "weighted shortest path" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);
    _ = try g.addEdge("b", "c", "link", 1.0);
    _ = try g.addEdge("a", "c", "link", 10.0);

    try g.compact();
    var result = try weightedShortestPath(&g, std.testing.allocator, "a", "c");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expect(result.total_weight < 3.0);
}

test "neighbors" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);
    _ = try g.addEdge("a", "c", "link", 1.0);

    try g.compact();
    const out = try neighbors(&g, std.testing.allocator, "a", .outgoing);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);

    const inc = try neighbors(&g, std.testing.allocator, "a", .incoming);
    defer std.testing.allocator.free(inc);
    try std.testing.expectEqual(@as(usize, 0), inc.len);
}

test "traverse with edge type filter" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "calls", 1.0);
    _ = try g.addEdge("a", "c", "owns", 1.0);

    try g.compact();
    const result = try traverse(&g, std.testing.allocator, "a", .{
        .max_depth = 5,
        .edge_type_filter = "calls",
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "traverse after compact" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);
    _ = try g.addEdge("b", "c", "link", 1.0);

    try g.compact();

    const result = try traverse(&g, std.testing.allocator, "a", .{ .max_depth = 5 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "traverse with delta only (no compact)" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);

    // No compact — edges only in delta
    const result = try traverse(&g, std.testing.allocator, "a", .{ .max_depth = 5 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "shortest path via delta" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);

    // No compact
    var result = try shortestPath(&g, std.testing.allocator, "a", "b", 10);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.nodes.len);
}
