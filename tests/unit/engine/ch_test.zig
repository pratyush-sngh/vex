// Migrated unit tests for src/engine/ch.zig.

const std = @import("std");
const ch = @import("../../../src/engine/ch.zig");
const graph_mod = @import("../../../src/engine/graph.zig");
const query = @import("../../../src/engine/query.zig");

const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const build = ch.build;
const chQuery = ch.chQuery;

test "ch basic correctness" {
    const allocator = std.testing.allocator;

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
    var ch_data = try build(&g, allocator);
    defer ch_data.deinit();

    // CH query
    const from_id = g.resolveKey("a").?;
    const to_id = g.resolveKey("e").?;
    const ch_result = try chQuery(&ch_data, allocator, from_id, to_id);
    defer allocator.free(ch_result.nodes);

    // Weights must match
    try std.testing.expectApproxEqAbs(ref.total_weight, ch_result.weight, 1e-9);
    // Both should find path a→b→c→d→e with weight 5.0
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), ch_result.weight, 1e-9);
}

test "ch larger graph validation" {
    const allocator = std.testing.allocator;

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
    var ch_data = try build(&g, allocator);
    defer ch_data.deinit();

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
            const ch_r = chQuery(&ch_data, allocator, s, t) catch continue;
            allocator.free(ch_r.nodes);
            mismatches += 1; // CH found but Dijkstra didn't
            continue;
        };
        var ref_mut = ref_result;
        defer ref_mut.deinit(allocator);

        const ch_r = chQuery(&ch_data, allocator, s, t) catch {
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
