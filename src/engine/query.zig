const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const EdgeId = graph_mod.EdgeId;
const INVALID_ID = graph_mod.INVALID_ID;

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

/// BFS traversal from a start node, returning all reachable node IDs
/// within max_depth hops, optionally filtered by edge/node type.
pub fn traverse(
    g: *GraphEngine,
    allocator: Allocator,
    start_key: []const u8,
    opts: TraversalOptions,
) ![]NodeId {
    const start_id = g.resolveKey(start_key) orelse return error.NodeNotFound;

    var visited = std.AutoHashMap(NodeId, void).init(allocator);
    defer visited.deinit();

    var result = std.array_list.Managed(NodeId).init(allocator);
    errdefer result.deinit();

    const QueueItem = struct { id: NodeId, depth: u32 };
    var queue = std.array_list.Managed(QueueItem).init(allocator);
    defer queue.deinit();

    try queue.append(.{ .id = start_id, .depth = 0 });
    try visited.put(start_id, {});

    while (queue.items.len > 0) {
        const item = queue.orderedRemove(0);
        try result.append(item.id);

        if (item.depth >= opts.max_depth) continue;

        const edge_lists = getEdgeLists(g, item.id, opts.direction);
        for (edge_lists) |edges| {
            for (edges) |eid| {
                const edge = g.getEdge(eid) orelse continue;

                if (opts.edge_type_filter) |filter| {
                    if (!std.mem.eql(u8, edge.edge_type, filter)) continue;
                }

                const neighbor_id = if (edge.from == item.id) edge.to else edge.from;
                if (neighbor_id == INVALID_ID) continue;
                if (visited.contains(neighbor_id)) continue;

                if (opts.node_type_filter) |filter| {
                    const neighbor = g.getNodeById(neighbor_id) orelse continue;
                    if (!std.mem.eql(u8, neighbor.node_type, filter)) continue;
                }

                try visited.put(neighbor_id, {});
                try queue.append(.{ .id = neighbor_id, .depth = item.depth + 1 });
            }
        }
    }

    return result.toOwnedSlice();
}

/// BFS shortest path (unweighted, in hops) between two nodes.
/// Returns the node IDs along the path, or error.PathNotFound.
pub fn shortestPath(
    g: *GraphEngine,
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

    var parent = std.AutoHashMap(NodeId, NodeId).init(allocator);
    defer parent.deinit();

    const QueueItem = struct { id: NodeId, depth: u32 };
    var queue = std.array_list.Managed(QueueItem).init(allocator);
    defer queue.deinit();

    try parent.put(from_id, INVALID_ID);
    try queue.append(.{ .id = from_id, .depth = 0 });

    while (queue.items.len > 0) {
        const item = queue.orderedRemove(0);
        if (item.depth >= max_depth) continue;

        // Expand both outgoing and incoming (undirected path finding)
        const out_edges = g.outgoingEdgesById(item.id);
        const in_edges = g.incomingEdgesById(item.id);

        const edge_sets = [_][]const EdgeId{ out_edges, in_edges };
        for (&edge_sets) |edges| {
            for (edges) |eid| {
                const edge = g.getEdge(eid) orelse continue;
                const neighbor = if (edge.from == item.id) edge.to else edge.from;
                if (neighbor == INVALID_ID) continue;
                if (parent.contains(neighbor)) continue;

                try parent.put(neighbor, item.id);

                if (neighbor == to_id) {
                    return reconstructPath(allocator, &parent, from_id, to_id);
                }

                try queue.append(.{ .id = neighbor, .depth = item.depth + 1 });
            }
        }
    }

    return error.PathNotFound;
}

/// Weighted shortest path using Dijkstra's algorithm.
pub fn weightedShortestPath(
    g: *GraphEngine,
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
    var parent = std.AutoHashMap(NodeId, NodeId).init(allocator);
    defer parent.deinit();

    var pq = std.PriorityQueue(DijkItem, void, DijkItem.order).initContext({});
    defer pq.deinit(allocator);

    try dist.put(from_id, 0);
    try parent.put(from_id, INVALID_ID);
    try pq.push(allocator, .{ .id = from_id, .dist = 0 });

    while (pq.pop()) |current| {
        if (current.id == to_id) {
            return reconstructWeightedPath(allocator, &parent, &dist, from_id, to_id);
        }

        const current_dist = dist.get(current.id) orelse continue;
        if (current.dist > current_dist) continue; // stale entry

        const out_edges = g.outgoingEdgesById(current.id);
        for (out_edges) |eid| {
            const edge = g.getEdge(eid) orelse continue;
            const new_dist = current_dist + edge.weight;
            const existing = dist.get(edge.to);

            if (existing == null or new_dist < existing.?) {
                try dist.put(edge.to, new_dist);
                try parent.put(edge.to, current.id);
                try pq.push(allocator, .{ .id = edge.to, .dist = new_dist });
            }
        }
    }

    return error.PathNotFound;
}

/// Get direct neighbors of a node.
pub fn neighbors(
    g: *GraphEngine,
    allocator: Allocator,
    key: []const u8,
    direction: Direction,
) ![]NodeId {
    const id = g.resolveKey(key) orelse return error.NodeNotFound;

    var result = std.AutoHashMap(NodeId, void).init(allocator);
    defer result.deinit();

    const edge_lists = getEdgeLists(g, id, direction);
    for (edge_lists) |edges| {
        for (edges) |eid| {
            const edge = g.getEdge(eid) orelse continue;
            const neighbor_id = if (edge.from == id) edge.to else edge.from;
            if (neighbor_id != INVALID_ID) {
                try result.put(neighbor_id, {});
            }
        }
    }

    var ids = std.array_list.Managed(NodeId).init(allocator);
    errdefer ids.deinit();
    var iter = result.keyIterator();
    while (iter.next()) |nid| {
        try ids.append(nid.*);
    }
    return ids.toOwnedSlice();
}

// ─── Internal helpers ─────────────────────────────────────────────────

const EdgeSlicePair = [2][]const EdgeId;

fn getEdgeLists(g: *GraphEngine, id: NodeId, direction: Direction) EdgeSlicePair {
    return switch (direction) {
        .outgoing => .{ g.outgoingEdgesById(id), &.{} },
        .incoming => .{ &.{}, g.incomingEdgesById(id) },
        .both => .{ g.outgoingEdgesById(id), g.incomingEdgesById(id) },
    };
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

    // Reverse to get from -> to order
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

    const result = try traverse(&g, std.testing.allocator, "a", .{ .max_depth = 5 });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
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

    var result = try shortestPath(&g, std.testing.allocator, "a", "c", 10);
    defer result.deinit(std.testing.allocator);

    // Should find a 2-hop path (a->b->c or a->d->c)
    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expectEqual(@as(NodeId, 0), result.nodes[0]); // a
    try std.testing.expectEqual(@as(NodeId, 2), result.nodes[result.nodes.len - 1]); // c
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

    var result = try weightedShortestPath(&g, std.testing.allocator, "a", "c");
    defer result.deinit(std.testing.allocator);

    // a->b->c (weight 2) is cheaper than a->c (weight 10)
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

    const result = try traverse(&g, std.testing.allocator, "a", .{
        .max_depth = 5,
        .edge_type_filter = "calls",
    });
    defer std.testing.allocator.free(result);

    // Only a and b (not c, since the edge type is "owns")
    try std.testing.expectEqual(@as(usize, 2), result.len);
}
