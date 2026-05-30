// Migrated unit tests for src/engine/query.zig.

const std = @import("std");
const query_mod = @import("../../../src/engine/query.zig");
const graph_mod = @import("../../../src/engine/graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const traverse = query_mod.traverse;
const shortestPath = query_mod.shortestPath;
const weightedShortestPath = query_mod.weightedShortestPath;
const neighbors = query_mod.neighbors;
const impact = query_mod.impact;
const findPaths = query_mod.findPaths;

test "traverse BFS outgoing" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);
    _ = try g.addEdge("b", "c", "link", 1.0);

    const r1 = try traverse(&g, std.testing.allocator, "a", .{ .max_depth = 5 });
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqual(@as(usize, 3), r1.len);

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
