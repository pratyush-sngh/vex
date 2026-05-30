// Migrated unit tests for src/engine/rag.zig.

const std = @import("std");
const ragSearch = @import("../../../src/engine/rag.zig").ragSearch;
const GraphEngine = @import("../../../src/engine/graph.zig").GraphEngine;

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
        for (results) |*r| {
            var rm = r.*;
            rm.deinit(allocator);
        }
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
        for (results) |*r| {
            var rm = r.*;
            rm.deinit(allocator);
        }
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqual(@as(usize, 0), results[0].neighbor_keys.len);
}
