// Migrated unit tests for src/engine/graph.zig.

const std = @import("std");
const graph_mod = @import("../../../src/engine/graph.zig");
const string_intern = @import("../../../src/engine/string_intern.zig");

const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const EdgeId = graph_mod.EdgeId;
const StringIntern = string_intern.StringIntern;
const TypeMask = string_intern.TypeMask;

test "graph_v2 add nodes and edges" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("service:auth", "service");
    _ = try g.addNode("service:user", "service");
    _ = try g.addEdge("service:auth", "service:user", "calls", 1.0);

    try std.testing.expectEqual(@as(usize, 2), g.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());

    // Delta edges should contain the new edge
    try std.testing.expectEqual(@as(usize, 1), g.delta_edges.items.len);
    try std.testing.expectEqual(@as(NodeId, 0), g.delta_edges.items[0].from);
    try std.testing.expectEqual(@as(NodeId, 1), g.delta_edges.items[0].to);
}

test "graph_v2 duplicate node" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("x", "type");
    const result = g.addNode("x", "type");
    try std.testing.expect(result == error.DuplicateNode);
}

test "graph_v2 node properties" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("n1", "service");
    try g.setNodeProperty("n1", "version", "2.1");

    const val = g.node_props.get(0, "version");
    try std.testing.expectEqualStrings("2.1", val.?);
    try std.testing.expect(g.flags.has_node_props);
}

test "graph_v2 remove node" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);

    try g.removeNode("a");
    try std.testing.expectEqual(@as(usize, 1), g.nodeCount());
    try std.testing.expectEqual(@as(usize, 0), g.edgeCount());
    try std.testing.expect(g.getNode("a") == null);
    try std.testing.expect(!g.all_base_edges_alive);
}

test "graph_v2 remove edge" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    const eid = try g.addEdge("a", "b", "link", 1.0);

    try g.removeEdge(eid);
    try std.testing.expectEqual(@as(usize, 0), g.edgeCount());
    try std.testing.expect(g.getEdge(eid) == null);
}

test "graph_v2 compact moves delta to base" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);
    _ = try g.addEdge("b", "c", "link", 1.0);

    // Before compact: edges in delta
    try std.testing.expectEqual(@as(usize, 2), g.delta_edges.items.len);
    try std.testing.expectEqual(@as(usize, 0), g.base_out.neighbors(0).len);

    try g.compact();

    // After compact: edges in base, delta cleared
    try std.testing.expectEqual(@as(usize, 0), g.delta_edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), g.base_out.neighbors(0).len);
    try std.testing.expectEqual(@as(NodeId, 1), g.base_out.neighbors(0)[0]);
    try std.testing.expect(g.all_base_edges_alive);
    // CH is not auto-built on compact (must call rebuildCH explicitly)
    try std.testing.expect(g.ch == null);
}

test "graph_v2 type interning" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "service");
    _ = try g.addNode("b", "service");
    _ = try g.addNode("c", "database");

    try std.testing.expectEqual(g.node_type_id.items[0], g.node_type_id.items[1]);
    try std.testing.expect(g.node_type_id.items[0] != g.node_type_id.items[2]);
    try std.testing.expectEqual(@as(u16, 2), g.type_intern.count());
}

test "graph_v2 type mask filtering" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addNode("c", "t");
    _ = try g.addEdge("a", "b", "calls", 1.0);
    _ = try g.addEdge("a", "c", "owns", 1.0);

    const calls_id = g.type_intern.find("calls").?;
    const calls_mask = StringIntern.mask(calls_id);
    try std.testing.expect(g.node_out_type_mask.items[0] & calls_mask != 0);

    const owns_id = g.type_intern.find("owns").?;
    const owns_mask = StringIntern.mask(owns_id);
    try std.testing.expect(g.node_out_type_mask.items[0] & owns_mask != 0);

    try std.testing.expectEqual(@as(TypeMask, 0), g.node_out_type_mask.items[1]);
}

test "graph_v2 uniform weights flag" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");

    try std.testing.expect(g.flags.uniform_weights);
    _ = try g.addEdge("a", "b", "link", 1.0);
    try std.testing.expect(g.flags.uniform_weights);
    _ = try g.addEdge("b", "a", "link", 2.5);
    try std.testing.expect(!g.flags.uniform_weights);
}

test "graph_v2 edge properties" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    const eid = try g.addEdge("a", "b", "link", 1.0);

    try g.setEdgeProperty(eid, "latency", "50ms");
    const val = g.edge_props.get(eid, "latency");
    try std.testing.expectEqualStrings("50ms", val.?);
    try std.testing.expect(g.flags.has_edge_props);
}

test "graph_v2 all_base_edges_alive flag" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);

    try g.compact();
    try std.testing.expect(g.all_base_edges_alive);

    try g.removeEdge(0);
    try std.testing.expect(!g.all_base_edges_alive);

    try g.compact();
    try std.testing.expect(g.all_base_edges_alive);
}

test "upsertNode creates and returns existing" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    const id1 = try g.upsertNode("svc:a", "service");
    const id2 = try g.upsertNode("svc:a", "service");
    try std.testing.expectEqual(id1, id2);
    try std.testing.expectEqual(@as(usize, 1), g.nodeCount());

    const id3 = try g.upsertNode("svc:b", "service");
    try std.testing.expect(id3 != id1);
    try std.testing.expectEqual(@as(usize, 2), g.nodeCount());
}

test "findEdge returns existing edge" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    const eid = try g.addEdge("a", "b", "calls", 1.0);

    try std.testing.expectEqual(@as(?EdgeId, eid), g.findEdge("a", "b", "calls"));
    try std.testing.expectEqual(@as(?EdgeId, null), g.findEdge("a", "b", "owns"));
    try std.testing.expectEqual(@as(?EdgeId, null), g.findEdge("b", "a", "calls"));
}

test "listByType filters correctly" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("svc:a", "service");
    _ = try g.addNode("svc:b", "service");
    _ = try g.addNode("db:1", "database");

    const services = try g.listByType("service", 0);
    defer std.testing.allocator.free(services);
    try std.testing.expectEqual(@as(usize, 2), services.len);

    const dbs = try g.listByType("database", 0);
    defer std.testing.allocator.free(dbs);
    try std.testing.expectEqual(@as(usize, 1), dbs.len);

    const limited = try g.listByType("service", 1);
    defer std.testing.allocator.free(limited);
    try std.testing.expectEqual(@as(usize, 1), limited.len);
}
