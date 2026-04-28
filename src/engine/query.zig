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

const PARALLEL_BFS_THRESHOLD = 512; // min frontier size to parallelize
const MAX_BFS_THREADS = 4;

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
/// Frontier-based BFS traversal. Processes entire levels at once using
/// bitset frontiers instead of a per-node queue. More cache-friendly
/// CSR access and enables bulk bitset operations.
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

    // Two frontiers: current level and next level (swap each iteration)
    var frontier_a = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer frontier_a.deinit();
    var frontier_b = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer frontier_b.deinit();

    var result = std.array_list.Managed(NodeId).init(allocator);
    errdefer result.deinit();

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

    visited.set(start_id);
    frontier_a.set(start_id);
    try result.append(start_id);

    const all_alive = g.all_base_edges_alive;
    const has_delta = g.delta_edges.items.len > 0;
    const csrs = getCSRSlice(g, opts.direction);

    var current = &frontier_a;
    var next = &frontier_b;
    var depth: u32 = 0;

    while (depth < opts.max_depth) {
        next.setRangeValue(.{ .start = 0, .end = node_cap }, false);

        // Collect frontier node IDs for potential parallel expansion
        var frontier_nodes = std.array_list.Managed(NodeId).init(allocator);
        defer frontier_nodes.deinit();
        {
            var iter = current.iterator(.{});
            while (iter.next()) |nid| {
                frontier_nodes.append(@intCast(nid)) catch break;
            }
        }

        if (frontier_nodes.items.len == 0) break;

        const frontier_count = frontier_nodes.items.len;
        const num_threads = if (frontier_count >= PARALLEL_BFS_THRESHOLD)
            @min(MAX_BFS_THREADS, std.Thread.getCpuCount() catch 1)
        else
            1;

        if (num_threads <= 1) {
            // Sequential path — same as before
            expandFrontierSeq(g, frontier_nodes.items, &visited, next, all_alive, has_delta, csrs, edge_type_mask, node_type_id, opts.direction);
        } else {
            // Parallel path — thread-local next bitsets, merge with OR
            var local_nexts: [MAX_BFS_THREADS]std.DynamicBitSet = undefined;
            var inited: usize = 0;
            for (0..num_threads) |t| {
                local_nexts[t] = std.DynamicBitSet.initEmpty(allocator, node_cap) catch break;
                inited += 1;
            }
            defer for (0..inited) |t| local_nexts[t].deinit();

            if (inited < num_threads) {
                // Allocation failed — fall back to sequential
                expandFrontierSeq(g, frontier_nodes.items, &visited, next, all_alive, has_delta, csrs, edge_type_mask, node_type_id, opts.direction);
            } else {
                const chunk = (frontier_count + num_threads - 1) / num_threads;
                const ExpandCtx = struct {
                    g: *const GraphEngine,
                    nodes: []const NodeId,
                    visited: *const std.DynamicBitSet,
                    local_next: *std.DynamicBitSet,
                    all_alive: bool,
                    has_delta: bool,
                    csrs: []const *const CSR,
                    edge_type_mask: TypeMask,
                    node_type_id: ?u16,
                    direction: Direction,

                    fn run(ctx: *@This()) void {
                        expandFrontierSeq(ctx.g, ctx.nodes, ctx.visited, ctx.local_next, ctx.all_alive, ctx.has_delta, ctx.csrs, ctx.edge_type_mask, ctx.node_type_id, ctx.direction);
                    }
                };

                var ctxs: [MAX_BFS_THREADS]ExpandCtx = undefined;
                var threads: [MAX_BFS_THREADS]?std.Thread = .{null} ** MAX_BFS_THREADS;
                var spawned: usize = 0;

                for (0..num_threads) |t| {
                    const start_idx = t * chunk;
                    const end_idx = @min(start_idx + chunk, frontier_count);
                    if (start_idx >= end_idx) break;

                    ctxs[t] = .{
                        .g = g,
                        .nodes = frontier_nodes.items[start_idx..end_idx],
                        .visited = &visited,
                        .local_next = &local_nexts[t],
                        .all_alive = all_alive,
                        .has_delta = has_delta,
                        .csrs = csrs,
                        .edge_type_mask = edge_type_mask,
                        .node_type_id = node_type_id,
                        .direction = opts.direction,
                    };

                    if (t == 0) {
                        // Run first chunk inline (avoid thread for small remainder)
                        continue;
                    }
                    threads[t] = std.Thread.spawn(.{}, ExpandCtx.run, .{&ctxs[t]}) catch {
                        ExpandCtx.run(&ctxs[t]); // fallback inline
                        continue;
                    };
                    spawned += 1;
                }

                // Run chunk 0 on this thread while others work
                if (frontier_nodes.items.len > 0) {
                    ExpandCtx.run(&ctxs[0]);
                }

                // Join spawned threads
                for (threads[0..num_threads]) |t| {
                    if (t) |thread| thread.join();
                }

                // Merge: OR all local_next bitsets into global next
                const mask_count = (node_cap + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
                for (0..mask_count) |mi| {
                    var merged: usize = 0;
                    for (0..inited) |t| {
                        merged |= local_nexts[t].unmanaged.masks[mi];
                    }
                    next.unmanaged.masks[mi] = merged;
                }
            }
        }

        // Build result from next bitset + update visited
        var any_in_next = false;
        var next_iter = next.iterator(.{});
        while (next_iter.next()) |nid_usize| {
            const nid: NodeId = @intCast(nid_usize);
            if (!visited.isSet(nid)) {
                visited.set(nid);
                any_in_next = true;
                result.append(nid) catch break;
            }
        }

        if (!any_in_next) break;
        depth += 1;

        const tmp = current;
        current = next;
        next = tmp;
    }

    return result.toOwnedSlice();
}

/// Bidirectional BFS shortest path (unweighted).
/// Searches from BOTH ends simultaneously, meeting in the middle.
/// Explores ~2*sqrt(N) nodes instead of ~N — dramatically faster on large graphs.
/// Uses flat parent arrays for O(1) per-node tracking.
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

    const node_cap = g.node_keys.items.len;
    const all_alive = g.all_base_edges_alive;
    const has_delta = g.delta_edges.items.len > 0;
    const csrs = getCSRSlice(g, .both);

    // Forward search (from start)
    var fwd_visited = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer fwd_visited.deinit();
    const fwd_parent = try allocator.alloc(NodeId, node_cap);
    defer allocator.free(fwd_parent);
    @memset(fwd_parent, graph_mod.INVALID_ID);

    // Backward search (from target)
    var bwd_visited = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer bwd_visited.deinit();
    const bwd_parent = try allocator.alloc(NodeId, node_cap);
    defer allocator.free(bwd_parent);
    @memset(bwd_parent, graph_mod.INVALID_ID);

    const QueueItem = struct { id: NodeId, depth: u32 };
    var fwd_queue = std.array_list.Managed(QueueItem).init(allocator);
    defer fwd_queue.deinit();
    var bwd_queue = std.array_list.Managed(QueueItem).init(allocator);
    defer bwd_queue.deinit();

    fwd_visited.set(from_id);
    fwd_parent[from_id] = from_id;
    try fwd_queue.append(.{ .id = from_id, .depth = 0 });

    bwd_visited.set(to_id);
    bwd_parent[to_id] = to_id;
    try bwd_queue.append(.{ .id = to_id, .depth = 0 });

    var fwd_head: usize = 0;
    var bwd_head: usize = 0;
    var fwd_depth: u32 = 0;
    var bwd_depth: u32 = 0;

    while ((fwd_head < fwd_queue.items.len or bwd_head < bwd_queue.items.len) and
        fwd_depth + bwd_depth <= max_depth)
    {
        // Expand the smaller frontier (heuristic: explore less)
        const expand_fwd = if (fwd_head >= fwd_queue.items.len)
            false
        else if (bwd_head >= bwd_queue.items.len)
            true
        else
            (fwd_queue.items.len - fwd_head) <= (bwd_queue.items.len - bwd_head);

        if (expand_fwd) {
            // Expand one level of forward BFS
            const level_end = fwd_queue.items.len;
            while (fwd_head < level_end) {
                const item = fwd_queue.items[fwd_head];
                fwd_head += 1;

                for (csrs) |csr| {
                    const targets = csr.neighbors(item.id);
                    if (all_alive) {
                        for (targets) |nid| {
                            if (!g.node_alive.isSet(nid)) continue;
                            if (fwd_visited.isSet(nid)) continue;
                            fwd_visited.set(nid);
                            fwd_parent[nid] = item.id;

                            // Check if backward search already visited this node
                            if (bwd_visited.isSet(nid)) {
                                return buildBidirectionalPath(allocator, fwd_parent, bwd_parent, from_id, to_id, nid);
                            }
                            try fwd_queue.append(.{ .id = nid, .depth = item.depth + 1 });
                        }
                    } else {
                        const eidxs = csr.edgeIndices(item.id);
                        for (targets, eidxs) |nid, eidx| {
                            if (!g.edge_alive.isSet(eidx)) continue;
                            if (!g.node_alive.isSet(nid)) continue;
                            if (fwd_visited.isSet(nid)) continue;
                            fwd_visited.set(nid);
                            fwd_parent[nid] = item.id;
                            if (bwd_visited.isSet(nid)) {
                                return buildBidirectionalPath(allocator, fwd_parent, bwd_parent, from_id, to_id, nid);
                            }
                            try fwd_queue.append(.{ .id = nid, .depth = item.depth + 1 });
                        }
                    }
                }
                if (has_delta) {
                    for (g.delta_edges.items) |de| {
                        if (de.from != item.id and de.to != item.id) continue;
                        if (!g.edge_alive.isSet(de.eidx)) continue;
                        const nid = if (de.from == item.id) de.to else de.from;
                        if (!g.node_alive.isSet(nid)) continue;
                        if (fwd_visited.isSet(nid)) continue;
                        fwd_visited.set(nid);
                        fwd_parent[nid] = item.id;
                        if (bwd_visited.isSet(nid)) {
                            return buildBidirectionalPath(allocator, fwd_parent, bwd_parent, from_id, to_id, nid);
                        }
                        try fwd_queue.append(.{ .id = nid, .depth = item.depth + 1 });
                    }
                }
            }
            fwd_depth += 1;
        } else {
            // Expand one level of backward BFS
            const level_end = bwd_queue.items.len;
            while (bwd_head < level_end) {
                const item = bwd_queue.items[bwd_head];
                bwd_head += 1;

                for (csrs) |csr| {
                    const targets = csr.neighbors(item.id);
                    if (all_alive) {
                        for (targets) |nid| {
                            if (!g.node_alive.isSet(nid)) continue;
                            if (bwd_visited.isSet(nid)) continue;
                            bwd_visited.set(nid);
                            bwd_parent[nid] = item.id;
                            if (fwd_visited.isSet(nid)) {
                                return buildBidirectionalPath(allocator, fwd_parent, bwd_parent, from_id, to_id, nid);
                            }
                            try bwd_queue.append(.{ .id = nid, .depth = item.depth + 1 });
                        }
                    } else {
                        const eidxs = csr.edgeIndices(item.id);
                        for (targets, eidxs) |nid, eidx| {
                            if (!g.edge_alive.isSet(eidx)) continue;
                            if (!g.node_alive.isSet(nid)) continue;
                            if (bwd_visited.isSet(nid)) continue;
                            bwd_visited.set(nid);
                            bwd_parent[nid] = item.id;
                            if (fwd_visited.isSet(nid)) {
                                return buildBidirectionalPath(allocator, fwd_parent, bwd_parent, from_id, to_id, nid);
                            }
                            try bwd_queue.append(.{ .id = nid, .depth = item.depth + 1 });
                        }
                    }
                }
                if (has_delta) {
                    for (g.delta_edges.items) |de| {
                        if (de.from != item.id and de.to != item.id) continue;
                        if (!g.edge_alive.isSet(de.eidx)) continue;
                        const nid = if (de.from == item.id) de.to else de.from;
                        if (!g.node_alive.isSet(nid)) continue;
                        if (bwd_visited.isSet(nid)) continue;
                        bwd_visited.set(nid);
                        bwd_parent[nid] = item.id;
                        if (fwd_visited.isSet(nid)) {
                            return buildBidirectionalPath(allocator, fwd_parent, bwd_parent, from_id, to_id, nid);
                        }
                        try bwd_queue.append(.{ .id = nid, .depth = item.depth + 1 });
                    }
                }
            }
            bwd_depth += 1;
        }
    }

    return error.PathNotFound;
}

/// Build the path from bidirectional BFS: forward chain to meeting point + backward chain from meeting point.
fn buildBidirectionalPath(
    allocator: Allocator,
    fwd_parent: []const NodeId,
    bwd_parent: []const NodeId,
    from_id: NodeId,
    to_id: NodeId,
    meet_id: NodeId,
) !PathResult {
    var path = std.array_list.Managed(NodeId).init(allocator);
    errdefer path.deinit();

    // Forward chain: from_id → ... → meet_id (reversed)
    var fwd_chain = std.array_list.Managed(NodeId).init(allocator);
    defer fwd_chain.deinit();
    var cur = meet_id;
    var safety: u32 = 0;
    while (cur != from_id) : (safety += 1) {
        if (safety > 1_000_000) return error.PathNotFound;
        try fwd_chain.append(cur);
        cur = fwd_parent[cur];
        if (cur == graph_mod.INVALID_ID) return error.PathNotFound;
    }
    try fwd_chain.append(from_id);
    std.mem.reverse(NodeId, fwd_chain.items);

    // Add forward chain
    try path.appendSlice(fwd_chain.items);

    // Backward chain: meet_id → ... → to_id
    // bwd_parent[meet_id] points toward to_id
    if (meet_id != to_id) {
        cur = bwd_parent[meet_id];
        safety = 0;
        while (cur != to_id and cur != graph_mod.INVALID_ID) : (safety += 1) {
            if (safety > 1_000_000) return error.PathNotFound;
            try path.append(cur);
            cur = bwd_parent[cur];
        }
        if (cur == to_id) try path.append(to_id);
    }

    return PathResult{ .nodes = try path.toOwnedSlice(), .total_weight = 0 };
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

    const csrs = getCSRSlice(g, direction);
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
    const csrs = getCSRSlice(g, direction);

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

/// Returns 1 CSR for single-direction, 2 for both. No wasted iterations.
/// Expand a subset of frontier nodes into the next bitset.
/// Thread-safe: reads graph state (immutable during BFS), writes only to local `next` bitset.
/// Does NOT update `visited` — caller merges and updates after all threads complete.
fn expandFrontierSeq(
    g: *const GraphEngine,
    frontier_nodes: []const NodeId,
    visited: *const std.DynamicBitSet,
    next: *std.DynamicBitSet,
    all_alive: bool,
    has_delta: bool,
    csrs: []const *const CSR,
    edge_type_mask: TypeMask,
    node_type_id: ?u16,
    direction: Direction,
) void {
    for (frontier_nodes) |node_id| {
        // Early exit: check node's edge type mask
        if (edge_type_mask != 0) {
            const node_mask = switch (direction) {
                .outgoing => g.node_out_type_mask.items[node_id],
                .incoming => g.node_in_type_mask.items[node_id],
                .both => g.node_out_type_mask.items[node_id] | g.node_in_type_mask.items[node_id],
            };
            if (node_mask & edge_type_mask == 0) continue;
        }

        // Scan CSR neighbors
        for (csrs) |csr| {
            const targets = csr.neighbors(node_id);
            if (targets.len == 0) continue;

            if (all_alive and edge_type_mask == 0 and node_type_id == null) {
                for (targets) |nid| {
                    if (!g.node_alive.isSet(nid)) continue;
                    if (visited.isSet(nid)) continue;
                    next.set(nid);
                }
            } else {
                const edge_indices = csr.edgeIndices(node_id);
                for (targets, edge_indices) |nid, eidx| {
                    if (!g.edge_alive.isSet(eidx)) continue;
                    if (!g.node_alive.isSet(nid)) continue;
                    if (visited.isSet(nid)) continue;

                    if (edge_type_mask != 0) {
                        const emask = StringIntern.mask(g.edge_type_id.items[eidx]);
                        if (edge_type_mask & emask == 0) continue;
                    }
                    if (node_type_id) |ntid| {
                        if (g.node_type_id.items[nid] != ntid) continue;
                    }

                    next.set(nid);
                }
            }
        }

        // Delta edges
        if (has_delta) {
            for (g.delta_edges.items) |de| {
                const matches = switch (direction) {
                    .outgoing => de.from == node_id,
                    .incoming => de.to == node_id,
                    .both => de.from == node_id or de.to == node_id,
                };
                if (!matches) continue;
                if (!g.edge_alive.isSet(de.eidx)) continue;
                const nid = if (de.from == node_id) de.to else de.from;
                if (!g.node_alive.isSet(nid)) continue;
                if (visited.isSet(nid)) continue;

                if (edge_type_mask != 0) {
                    const emask = StringIntern.mask(g.edge_type_id.items[de.eidx]);
                    if (edge_type_mask & emask == 0) continue;
                }
                if (node_type_id) |ntid| {
                    if (g.node_type_id.items[nid] != ntid) continue;
                }

                next.set(nid);
            }
        }
    }
}

fn getCSRSlice(g: *const GraphEngine, direction: Direction) []const *const CSR {
    const S = struct {
        threadlocal var buf: [2]*const CSR = undefined;
    };
    return switch (direction) {
        .outgoing => {
            S.buf[0] = &g.base_out;
            return S.buf[0..1];
        },
        .incoming => {
            S.buf[0] = &g.base_in;
            return S.buf[0..1];
        },
        .both => {
            S.buf[0] = &g.base_out;
            S.buf[1] = &g.base_in;
            return S.buf[0..2];
        },
    };
}

fn prefetchCSROffsets(csr: *const CSR, node_id: NodeId) void {
    if (csr.offsets.len == 0) return;
    if (node_id + 1 >= csr.offsets.len) return;
    // Prefetch the offsets for this node — hides L2 latency
    const ptr: [*]const u8 = @ptrCast(&csr.offsets[node_id]);
    @prefetch(ptr, .{ .rw = .read, .locality = 1 });
}

/// Reconstruct path from flat parent array.
fn reconstructFlatPath(
    allocator: Allocator,
    parent: []const NodeId,
    from_id: NodeId,
    to_id: NodeId,
) !PathResult {
    var path = std.array_list.Managed(NodeId).init(allocator);
    errdefer path.deinit();

    var current = to_id;
    var safety: u32 = 0;
    while (current != from_id) : (safety += 1) {
        if (safety > 1_000_000) return error.PathNotFound;
        try path.append(current);
        current = parent[current];
        if (current == graph_mod.INVALID_ID) return error.PathNotFound;
    }
    try path.append(from_id);

    std.mem.reverse(NodeId, path.items);
    return PathResult{ .nodes = try path.toOwnedSlice(), .total_weight = 0 };
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

// ─── Impact Analysis ─────────────────────────────────────────────────

pub const ImpactOptions = struct {
    max_depth: u32 = 10,
    edge_type_filters: ?[]const []const u8 = null,
    node_type_filters: ?[]const []const u8 = null,
};

pub const ImpactResult = struct {
    type_name: []const u8,
    count: u32,
};

/// BFS downstream impact analysis: count affected nodes grouped by type.
pub fn impact(
    g: *const GraphEngine,
    allocator: Allocator,
    start_key: []const u8,
    opts: ImpactOptions,
) ![]ImpactResult {
    const start_id = g.resolveKey(start_key) orelse return error.NodeNotFound;
    const node_cap = g.node_keys.items.len;

    var visited = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer visited.deinit();
    var frontier_a = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer frontier_a.deinit();
    var frontier_b = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer frontier_b.deinit();

    // Resolve edge type filters to bitmask
    var edge_type_mask: TypeMask = 0;
    if (opts.edge_type_filters) |filters| {
        for (filters) |f| {
            if (g.type_intern.find(f)) |id| edge_type_mask |= StringIntern.mask(id);
        }
        if (edge_type_mask == 0) {
            const empty = try allocator.alloc(ImpactResult, 0);
            return empty;
        }
    }

    // Resolve node type filters
    var node_type_set: u64 = 0;
    var has_node_filter = false;
    if (opts.node_type_filters) |filters| {
        has_node_filter = true;
        for (filters) |f| {
            if (g.type_intern.find(f)) |id| {
                if (id < 64) node_type_set |= @as(u64, 1) << @intCast(id);
            }
        }
    }

    visited.set(start_id);
    frontier_a.set(start_id);

    const csrs = getCSRSlice(g, .outgoing);
    const all_alive = g.all_base_edges_alive;
    const has_delta = g.delta_edges.items.len > 0;

    // Count by type_id (max 64 interned types)
    var counts: [64]u32 = [_]u32{0} ** 64;
    var total: u32 = 0;

    var current = &frontier_a;
    var next = &frontier_b;
    var depth: u32 = 0;

    while (depth < opts.max_depth) {
        next.setRangeValue(.{ .start = 0, .end = node_cap }, false);
        var any_in_next = false;

        var iter = current.iterator(.{});
        while (iter.next()) |node_id_usize| {
            const node_id: NodeId = @intCast(node_id_usize);

            // Early exit: skip node if it has no outgoing edges of the filtered type
            if (edge_type_mask != 0) {
                if (g.node_out_type_mask.items[node_id] & edge_type_mask == 0) continue;
            }

            for (csrs) |csr| {
                const targets = csr.neighbors(node_id);
                if (targets.len == 0) continue;

                if (all_alive and edge_type_mask == 0) {
                    for (targets) |nid| {
                        if (!g.node_alive.isSet(nid)) continue;
                        if (visited.isSet(nid)) continue;
                        visited.set(nid);
                        next.set(nid);
                        any_in_next = true;
                        const ntid = g.node_type_id.items[nid];
                        if (!has_node_filter or (ntid < 64 and (node_type_set & (@as(u64, 1) << @intCast(ntid))) != 0)) {
                            counts[ntid] += 1;
                            total += 1;
                        }
                    }
                } else {
                    const edge_indices = csr.edgeIndices(node_id);
                    for (targets, edge_indices) |nid, eidx| {
                        if (!g.edge_alive.isSet(eidx)) continue;
                        if (!g.node_alive.isSet(nid)) continue;
                        if (visited.isSet(nid)) continue;
                        if (edge_type_mask != 0) {
                            const emask = StringIntern.mask(g.edge_type_id.items[eidx]);
                            if (edge_type_mask & emask == 0) continue;
                        }
                        visited.set(nid);
                        next.set(nid);
                        any_in_next = true;
                        const ntid = g.node_type_id.items[nid];
                        if (!has_node_filter or (ntid < 64 and (node_type_set & (@as(u64, 1) << @intCast(ntid))) != 0)) {
                            counts[ntid] += 1;
                            total += 1;
                        }
                    }
                }
            }

            if (has_delta) {
                for (g.delta_edges.items) |de| {
                    if (de.from != node_id) continue;
                    if (!g.edge_alive.isSet(de.eidx)) continue;
                    const nid = de.to;
                    if (!g.node_alive.isSet(nid)) continue;
                    if (visited.isSet(nid)) continue;
                    if (edge_type_mask != 0) {
                        const emask = StringIntern.mask(g.edge_type_id.items[de.eidx]);
                        if (edge_type_mask & emask == 0) continue;
                    }
                    visited.set(nid);
                    next.set(nid);
                    any_in_next = true;
                    const ntid = g.node_type_id.items[nid];
                    if (!has_node_filter or (ntid < 64 and (node_type_set & (@as(u64, 1) << @intCast(ntid))) != 0)) {
                        counts[ntid] += 1;
                        total += 1;
                    }
                }
            }
        }

        if (!any_in_next) break;
        depth += 1;
        const tmp = current;
        current = next;
        next = tmp;
    }

    // Build result array
    var result = std.array_list.Managed(ImpactResult).init(allocator);
    errdefer result.deinit();

    // First entry is always "total"
    try result.append(.{ .type_name = "total", .count = total });

    const type_count = g.type_intern.count();
    for (0..type_count) |ti| {
        if (counts[ti] > 0) {
            try result.append(.{ .type_name = g.type_intern.resolve(@intCast(ti)), .count = counts[ti] });
        }
    }

    return result.toOwnedSlice();
}

// ─── Find Paths ──────────────────────────────────────────────────────

pub const FindPathsOptions = struct {
    max_depth: u32 = 10,
    limit: u32 = 100,
    edge_type_filters: ?[]const []const u8 = null,
};

/// DFS to find all paths from start to any node whose type matches target_type.
/// Returns array of paths, each path is a slice of NodeIds.
pub fn findPaths(
    g: *const GraphEngine,
    allocator: Allocator,
    start_key: []const u8,
    target_type: []const u8,
    opts: FindPathsOptions,
) ![][]NodeId {
    const start_id = g.resolveKey(start_key) orelse return error.NodeNotFound;
    const target_type_id = g.type_intern.find(target_type) orelse {
        const empty = try allocator.alloc([]NodeId, 0);
        return empty;
    };

    var edge_type_mask: TypeMask = 0;
    if (opts.edge_type_filters) |filters| {
        for (filters) |f| {
            if (g.type_intern.find(f)) |id| edge_type_mask |= StringIntern.mask(id);
        }
        if (edge_type_mask == 0) {
            const empty = try allocator.alloc([]NodeId, 0);
            return empty;
        }
    }

    var results = std.array_list.Managed([]NodeId).init(allocator);
    errdefer {
        for (results.items) |p| allocator.free(p);
        results.deinit();
    }

    // DFS stack: (node_id, depth)
    const StackEntry = struct { node_id: NodeId, depth: u32 };
    var stack = std.array_list.Managed(StackEntry).init(allocator);
    defer stack.deinit();

    // Path tracking: current path from start
    var path = std.array_list.Managed(NodeId).init(allocator);
    defer path.deinit();

    // On-path set to avoid cycles within a single path
    const node_cap = g.node_keys.items.len;
    var on_path = try std.DynamicBitSet.initEmpty(allocator, node_cap);
    defer on_path.deinit();

    try stack.append(.{ .node_id = start_id, .depth = 0 });

    const csrs = getCSRSlice(g, .outgoing);
    const all_alive = g.all_base_edges_alive;
    const has_delta = g.delta_edges.items.len > 0;

    var child_buf = std.array_list.Managed(NodeId).init(allocator);
    defer child_buf.deinit();

    while (stack.items.len > 0) {
        const entry = stack.pop().?;

        // Trim path back to this depth
        while (path.items.len > entry.depth) {
            const removed = path.pop().?;
            on_path.unset(removed);
        }
        try path.append(entry.node_id);
        on_path.set(entry.node_id);

        // Check if we reached target type (not start node)
        if (entry.node_id != start_id and g.node_type_id.items[entry.node_id] == target_type_id) {
            const found_path = try allocator.dupe(NodeId, path.items);
            try results.append(found_path);
            if (results.items.len >= opts.limit) break;
            _ = path.pop().?;
            on_path.unset(entry.node_id);
            continue;
        }

        if (entry.depth >= opts.max_depth) {
            _ = path.pop().?;
            on_path.unset(entry.node_id);
            continue;
        }

        // Expand neighbors (push in reverse so first neighbor is explored first)
        child_buf.clearRetainingCapacity();

        for (csrs) |csr| {
            const targets = csr.neighbors(entry.node_id);
            if (all_alive and edge_type_mask == 0) {
                for (targets) |nid| {
                    if (!g.node_alive.isSet(nid)) continue;
                    if (on_path.isSet(nid)) continue;
                    try child_buf.append(nid);
                }
            } else {
                const edge_indices = csr.edgeIndices(entry.node_id);
                for (targets, edge_indices) |nid, eidx| {
                    if (!g.edge_alive.isSet(eidx)) continue;
                    if (!g.node_alive.isSet(nid)) continue;
                    if (on_path.isSet(nid)) continue;
                    if (edge_type_mask != 0) {
                        const emask = StringIntern.mask(g.edge_type_id.items[eidx]);
                        if (edge_type_mask & emask == 0) continue;
                    }
                    try child_buf.append(nid);
                }
            }
        }

        if (has_delta) {
            for (g.delta_edges.items) |de| {
                if (de.from != entry.node_id) continue;
                if (!g.edge_alive.isSet(de.eidx)) continue;
                if (!g.node_alive.isSet(de.to)) continue;
                if (on_path.isSet(de.to)) continue;
                if (edge_type_mask != 0) {
                    const emask = StringIntern.mask(g.edge_type_id.items[de.eidx]);
                    if (edge_type_mask & emask == 0) continue;
                }
                try child_buf.append(de.to);
            }
        }

        if (child_buf.items.len == 0) {
            _ = path.pop().?;
            on_path.unset(entry.node_id);
            continue;
        }

        // Push children in reverse so first child is on top
        var ci: usize = child_buf.items.len;
        while (ci > 0) {
            ci -= 1;
            try stack.append(.{ .node_id = child_buf.items[ci], .depth = entry.depth + 1 });
        }
    }

    return results.toOwnedSlice();
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

test "impact analysis counts by type" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("root", "service");
    _ = try g.addNode("a", "service");
    _ = try g.addNode("b", "database");
    _ = try g.addNode("c", "service");
    _ = try g.addEdge("root", "a", "depends_on", 1.0);
    _ = try g.addEdge("root", "b", "depends_on", 1.0);
    _ = try g.addEdge("a", "c", "depends_on", 1.0);
    try g.compact();

    const results = try impact(&g, std.testing.allocator, "root", .{});
    defer std.testing.allocator.free(results);

    // Should have "total" + type entries
    try std.testing.expect(results.len >= 2);
    try std.testing.expectEqualStrings("total", results[0].type_name);
    try std.testing.expectEqual(@as(u32, 3), results[0].count);
}

test "impact with edge type filter" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("root", "service");
    _ = try g.addNode("a", "service");
    _ = try g.addNode("b", "database");
    _ = try g.addEdge("root", "a", "depends_on", 1.0);
    _ = try g.addEdge("root", "b", "owns", 1.0);
    try g.compact();

    const filters = [_][]const u8{"depends_on"};
    const results = try impact(&g, std.testing.allocator, "root", .{ .edge_type_filters = &filters });
    defer std.testing.allocator.free(results);

    try std.testing.expectEqualStrings("total", results[0].type_name);
    try std.testing.expectEqual(@as(u32, 1), results[0].count);
}

test "findPaths finds paths to target type" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("start", "service");
    _ = try g.addNode("mid", "service");
    _ = try g.addNode("end", "deployment");
    _ = try g.addEdge("start", "mid", "depends_on", 1.0);
    _ = try g.addEdge("mid", "end", "deploys_to", 1.0);
    try g.compact();

    const paths = try findPaths(&g, std.testing.allocator, "start", "deployment", .{});
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqual(@as(usize, 3), paths[0].len);
}

test "findPaths no match returns empty" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "service");
    _ = try g.addNode("b", "service");
    _ = try g.addEdge("a", "b", "link", 1.0);
    try g.compact();

    const paths = try findPaths(&g, std.testing.allocator, "a", "nonexistent", .{});
    defer std.testing.allocator.free(paths);

    try std.testing.expectEqual(@as(usize, 0), paths.len);
}
