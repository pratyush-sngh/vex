// Migrated unit tests for src/storage/snapshot.zig.

const std = @import("std");
const snapshot = @import("../../../src/storage/snapshot.zig");
const KVStore = @import("../../../src/engine/kv.zig").KVStore;
const GraphEngine = @import("../../../src/engine/graph.zig").GraphEngine;

const save = snapshot.save;
const load = snapshot.load;
const computeCrc32 = snapshot.computeCrc32;

test "snapshot round-trip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_test_v2.zdb";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var kv = KVStore.init(allocator, io);
    defer kv.deinit();
    try kv.set("hello", "world");
    try kv.setEx("temp", "data", 3600);

    var g = GraphEngine.init(allocator);
    defer g.deinit();
    _ = try g.addNode("a", "svc");
    _ = try g.addNode("b", "db");
    _ = try g.addEdge("a", "b", "reads", 1.5);
    try g.setNodeProperty("a", "version", "3");

    const kv_snap = try kv.snapshot(allocator);
    defer KVStore.freeSnapshot(kv_snap, allocator);
    try save(io, allocator, kv_snap, &g, path);

    var kv2 = KVStore.init(allocator, io);
    defer kv2.deinit();
    var g2 = GraphEngine.init(allocator);
    defer g2.deinit();

    try load(io, allocator, &kv2, &g2, path);

    try std.testing.expectEqualStrings("world", kv2.get("hello").?);
    try std.testing.expectEqualStrings("data", kv2.get("temp").?);
    try std.testing.expectEqual(@as(usize, 2), kv2.dbsize());

    try std.testing.expectEqual(@as(usize, 2), g2.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), g2.edgeCount());
    const na = g2.getNode("a").?;
    try std.testing.expectEqualStrings("svc", na.node_type);
    // Check property via PropertyStore
    try std.testing.expectEqualStrings("3", g2.node_props.get(na.id, "version").?);
    const nb = g2.getNode("b").?;
    try std.testing.expectEqualStrings("db", nb.node_type);
}

test "snapshot missing file returns cleanly" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    try load(io, allocator, &kv, &g, "/tmp/nonexistent_vex_test.zdb");
    try std.testing.expectEqual(@as(usize, 0), kv.dbsize());
}

test "snapshot corrupted CRC" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_crc_test_v2.zdb";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var kv = KVStore.init(allocator, io);
    defer kv.deinit();
    try kv.set("k", "v");
    var g = GraphEngine.init(allocator);
    defer g.deinit();

    const kv_snap = try kv.snapshot(allocator);
    defer KVStore.freeSnapshot(kv_snap, allocator);
    try save(io, allocator, kv_snap, &g, path);

    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        var one: [1]u8 = .{0xFF};
        try f.writePositionalAll(io, &one, 10);
    }

    var kv2 = KVStore.init(allocator, io);
    defer kv2.deinit();
    var g2 = GraphEngine.init(allocator);
    defer g2.deinit();

    try std.testing.expectError(error.ChecksumMismatch, load(io, allocator, &kv2, &g2, path));
}

test "crc32 known value" {
    const data = "123456789";
    try std.testing.expectEqual(@as(u32, 0xCBF43926), computeCrc32(data));
}

test "snapshot full persistence round-trip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_full_persist_test.zdb";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // ── Build a non-trivial graph ──
    var g = GraphEngine.init(allocator);
    defer g.deinit();

    // Multiple node types
    const id_a = try g.addNode("api-gw", "service");
    const id_b = try g.addNode("user-db", "database");
    const id_c = try g.addNode("cache-1", "cache");
    _ = try g.addNode("dead-node", "service");

    // Node properties (multiple per node)
    try g.setNodeProperty("api-gw", "version", "3.2.1");
    try g.setNodeProperty("api-gw", "region", "us-east-1");
    try g.setNodeProperty("user-db", "engine", "postgres");

    // Multiple edge types and weights
    const eid0 = try g.addEdge("api-gw", "user-db", "reads", 1.5);
    const eid1 = try g.addEdge("api-gw", "cache-1", "reads", 0.3);
    _ = try g.addEdge("api-gw", "user-db", "writes", 2.0);

    // Edge properties
    try g.setEdgeProperty(eid0, "latency_ms", "12");
    try g.setEdgeProperty(eid0, "protocol", "tcp");
    try g.setEdgeProperty(eid1, "ttl", "300");

    // Delete a node (should persist as dead)
    try g.removeNode("dead-node");

    // Snapshot pre-save state
    const orig_node_mask_a = g.node_prop_mask.items[id_a];
    const orig_node_mask_b = g.node_prop_mask.items[id_b];
    const orig_edge_mask_0 = g.edge_prop_mask.items[eid0];
    const orig_edge_mask_1 = g.edge_prop_mask.items[eid1];

    var kv = KVStore.init(allocator, io);
    defer kv.deinit();
    try kv.set("config:timeout", "30");

    const kv_snap = try kv.snapshot(allocator);
    defer KVStore.freeSnapshot(kv_snap, allocator);
    try save(io, allocator, kv_snap, &g, path);

    // ── Load into fresh instances ──
    var kv2 = KVStore.init(allocator, io);
    defer kv2.deinit();
    var g2 = GraphEngine.init(allocator);
    defer g2.deinit();

    try load(io, allocator, &kv2, &g2, path);

    // ── Verify KV ──
    try std.testing.expectEqualStrings("30", kv2.get("config:timeout").?);

    // ── Verify node counts (3 alive, 1 dead) ──
    try std.testing.expectEqual(@as(usize, 3), g2.nodeCount());

    // ── Verify each live node: key, type, id ──
    const na = g2.getNode("api-gw").?;
    try std.testing.expectEqualStrings("service", na.node_type);
    try std.testing.expectEqual(id_a, na.id);

    const nb = g2.getNode("user-db").?;
    try std.testing.expectEqualStrings("database", nb.node_type);
    try std.testing.expectEqual(id_b, nb.id);

    const nc = g2.getNode("cache-1").?;
    try std.testing.expectEqualStrings("cache", nc.node_type);
    try std.testing.expectEqual(id_c, nc.id);

    // ── Verify dead node is gone ──
    try std.testing.expect(g2.getNode("dead-node") == null);

    // ── Verify node properties ──
    try std.testing.expectEqualStrings("3.2.1", g2.node_props.get(na.id, "version").?);
    try std.testing.expectEqualStrings("us-east-1", g2.node_props.get(na.id, "region").?);
    try std.testing.expectEqualStrings("postgres", g2.node_props.get(nb.id, "engine").?);
    try std.testing.expect(g2.node_props.get(nc.id, "version") == null); // cache has no props

    // ── Verify node prop_mask ──
    try std.testing.expectEqual(orig_node_mask_a, g2.node_prop_mask.items[na.id]);
    try std.testing.expectEqual(orig_node_mask_b, g2.node_prop_mask.items[nb.id]);
    try std.testing.expectEqual(@as(u64, 0), g2.node_prop_mask.items[nc.id]);

    // ── Verify edges ──
    try std.testing.expectEqual(@as(usize, 3), g2.edgeCount());

    const e0 = g2.getEdge(eid0).?;
    try std.testing.expectEqual(na.id, e0.from);
    try std.testing.expectEqual(nb.id, e0.to);
    try std.testing.expectEqualStrings("reads", e0.edge_type);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), e0.weight, 0.001);

    const e1 = g2.getEdge(eid1).?;
    try std.testing.expectEqual(na.id, e1.from);
    try std.testing.expectEqual(nc.id, e1.to);
    try std.testing.expectEqualStrings("reads", e1.edge_type);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), e1.weight, 0.001);

    // ── Verify edge properties ──
    try std.testing.expectEqualStrings("12", g2.edge_props.get(eid0, "latency_ms").?);
    try std.testing.expectEqualStrings("tcp", g2.edge_props.get(eid0, "protocol").?);
    try std.testing.expectEqualStrings("300", g2.edge_props.get(eid1, "ttl").?);

    // ── Verify edge prop_mask ──
    try std.testing.expectEqual(orig_edge_mask_0, g2.edge_prop_mask.items[eid0]);
    try std.testing.expectEqual(orig_edge_mask_1, g2.edge_prop_mask.items[eid1]);

    // ── Verify topology rebuilt (CSR from compact) ──
    const out_a = g2.outgoingNeighbors(na.id);
    // api-gw has 3 outgoing edges (2 to user-db, 1 to cache-1)
    try std.testing.expectEqual(@as(usize, 3), out_a.base.len);

    // ── Verify type interning survived ──
    try std.testing.expect(g2.type_intern.find("service") != null);
    try std.testing.expect(g2.type_intern.find("database") != null);
    try std.testing.expect(g2.type_intern.find("cache") != null);
    try std.testing.expect(g2.type_intern.find("reads") != null);
    try std.testing.expect(g2.type_intern.find("writes") != null);
}
