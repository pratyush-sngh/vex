const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const HnswIndex = graph_mod.HnswIndex;
const VectorStore = graph_mod.VectorStore;
const PropertyStore = @import("property_store.zig").PropertyStore;
const query = @import("query.zig");

pub const RagOptions = struct {
    depth: u32 = 1,
    direction: query.Direction = .outgoing,
    edge_type_filter: ?[]const u8 = null,
    node_type_filter: ?[]const u8 = null,
};

pub const RagResult = struct {
    node_id: NodeId,
    key: []const u8,
    score: f32,
    props: []const PropertyStore.PropPair,
    neighbor_keys: [][]const u8,

    pub fn deinit(self: *RagResult, allocator: Allocator) void {
        allocator.free(self.props);
        for (self.neighbor_keys) |k| allocator.free(k);
        allocator.free(self.neighbor_keys);
    }
};

pub fn ragSearch(
    graph: *const GraphEngine,
    allocator: Allocator,
    field: []const u8,
    query_vec: []const f32,
    k: u32,
    opts: RagOptions,
) ![]RagResult {
    const idx = graph.vec_indices.get(field) orelse return error.FieldNotFound;

    const normalized = try allocator.alloc(f32, query_vec.len);
    defer allocator.free(normalized);
    @memcpy(normalized, query_vec);
    VectorStore.normalize(normalized);

    const search_results = try idx.search(normalized, k, &graph.node_alive);
    defer allocator.free(search_results);

    var results = std.array_list.Managed(RagResult).init(allocator);
    errdefer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit();
    }

    for (search_results) |sr| {
        const node = graph.getNodeById(sr.node_id) orelse continue;
        const score = 1.0 - sr.distance;
        const props = graph.node_props.collectAll(sr.node_id, allocator) catch &.{};

        var neighbor_keys = std.array_list.Managed([]const u8).init(allocator);
        if (opts.depth > 0) {
            const traverse_opts = query.TraversalOptions{
                .max_depth = opts.depth,
                .direction = opts.direction,
                .edge_type_filter = opts.edge_type_filter,
                .node_type_filter = opts.node_type_filter,
            };
            const expanded = query.traverse(graph, allocator, node.key, traverse_opts) catch &.{};
            defer if (expanded.len > 0) allocator.free(expanded);

            for (expanded) |nid| {
                if (nid == sr.node_id) continue;
                const exp_node = graph.getNodeById(nid) orelse continue;
                const key_copy = allocator.dupe(u8, exp_node.key) catch continue;
                neighbor_keys.append(key_copy) catch { allocator.free(key_copy); continue; };
            }
        }

        try results.append(.{
            .node_id = sr.node_id,
            .key = node.key,
            .score = score,
            .props = props,
            .neighbor_keys = try neighbor_keys.toOwnedSlice(),
        });
    }

    return try results.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────

test "rag basic search with expansion" {
    const allocator = std.testing.allocator;
    var g = GraphEngine.init(allocator);
    defer g.deinit();

    _ = try g.addNode("doc:1", "document");
    _ = try g.addNode("doc:2", "document");
    _ = try g.addNode("topic:ai", "topic");
    _ = try g.addEdge("doc:1", "topic:ai", "about", 1.0);

    try g.setVector("doc:1", "emb", &[_]f32{ 1.0, 0.0, 0.0 });
    try g.setVector("doc:2", "emb", &[_]f32{ 0.0, 1.0, 0.0 });

    const results = try ragSearch(&g, allocator, "emb", &[_]f32{ 0.9, 0.1, 0.0 }, 2, .{ .depth = 1 });
    defer {
        for (results) |*r| { var rm = r.*; rm.deinit(allocator); }
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("doc:1", results[0].key);
    try std.testing.expect(results[0].score > 0.5);
    try std.testing.expect(results[0].neighbor_keys.len >= 1);
}

test "rag depth 0 is pure vector search" {
    const allocator = std.testing.allocator;
    var g = GraphEngine.init(allocator);
    defer g.deinit();

    _ = try g.addNode("a", "doc");
    _ = try g.addNode("b", "doc");
    try g.setVector("a", "emb", &[_]f32{ 1.0, 0.0 });
    try g.setVector("b", "emb", &[_]f32{ 0.0, 1.0 });

    const results = try ragSearch(&g, allocator, "emb", &[_]f32{ 1.0, 0.0 }, 2, .{ .depth = 0 });
    defer {
        for (results) |*r| { var rm = r.*; rm.deinit(allocator); }
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqual(@as(usize, 0), results[0].neighbor_keys.len);
}
