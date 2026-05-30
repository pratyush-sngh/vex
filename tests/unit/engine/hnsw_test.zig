// Migrated unit tests for src/engine/hnsw.zig.

const std = @import("std");
const hnsw = @import("../../../src/engine/hnsw.zig");
const VectorStore = @import("../../../src/engine/vector_store.zig").VectorStore;

const HnswIndex = hnsw.HnswIndex;
const MinHeap = hnsw.MinHeap;
const SortedCandidates = hnsw.SortedCandidates;

test "hnsw basic insert and search" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    const vecs = [_][3]f32{
        .{ 1.0, 0.0, 0.0 }, .{ 0.9, 0.1, 0.0 }, .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 }, .{ 0.5, 0.5, 0.0 }, .{ 0.7, 0.7, 0.0 },
        .{ 0.1, 0.9, 0.0 }, .{ 0.0, 0.1, 0.9 }, .{ 0.8, 0.2, 0.0 },
        .{ 0.3, 0.3, 0.3 },
    };
    for (vecs, 0..) |v, i| try vs.set(@intCast(i), "emb", &v);

    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    for (0..10) |i| try idx.insert(@intCast(i));

    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 3, null);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqual(@as(u32, 0), results[0].node_id);
    try std.testing.expect(results[0].distance < 0.1);
}

test "hnsw empty search" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();
    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    const results = try idx.search(&[_]f32{ 1.0, 0.0, 0.0 }, 5, null);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "hnsw single vector" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();
    try vs.set(42, "emb", &[_]f32{ 0.5, 0.5, 0.0 });
    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    try idx.insert(42);
    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 1, null);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u32, 42), results[0].node_id);
}

test "hnsw node alive filtering" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();
    try vs.set(0, "emb", &[_]f32{ 1.0, 0.0, 0.0 });
    try vs.set(1, "emb", &[_]f32{ 0.9, 0.1, 0.0 });
    try vs.set(2, "emb", &[_]f32{ 0.0, 1.0, 0.0 });

    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    for (0..3) |i| try idx.insert(@intCast(i));

    var alive = try std.DynamicBitSet.initFull(allocator, 3);
    defer alive.deinit();
    alive.unset(0);

    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const results = try idx.search(&query, 3, &alive);
    defer allocator.free(results);

    for (results) |r| try std.testing.expect(r.node_id != 0);
    if (results.len > 0) try std.testing.expectEqual(@as(u32, 1), results[0].node_id);
}

test "min heap push pop order" {
    const allocator = std.testing.allocator;
    var heap = MinHeap.init(allocator);
    defer heap.deinit();

    try heap.push(.{ .node_id = 3, .distance = 0.5 });
    try heap.push(.{ .node_id = 1, .distance = 0.1 });
    try heap.push(.{ .node_id = 2, .distance = 0.3 });

    // Should pop in ascending distance order
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), heap.pop().distance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), heap.pop().distance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), heap.pop().distance, 0.001);
}

test "sorted candidates binary search insert" {
    const allocator = std.testing.allocator;
    var sc = SortedCandidates.init();
    defer sc.deinit(allocator);

    try sc.add(allocator, .{ .node_id = 3, .distance = 0.5 });
    try sc.add(allocator, .{ .node_id = 1, .distance = 0.1 });
    try sc.add(allocator, .{ .node_id = 2, .distance = 0.3 });

    // Should be sorted ascending
    try std.testing.expectEqual(@as(u32, 1), sc.items[0].node_id);
    try std.testing.expectEqual(@as(u32, 2), sc.items[1].node_id);
    try std.testing.expectEqual(@as(u32, 3), sc.items[2].node_id);
}

test "hnsw serialize deserialize round-trip" {
    const allocator = std.testing.allocator;

    // Clean up test files
    defer {
        _ = std.c.unlink("/tmp/vex_hnsw_test/emb.vhi");
        _ = std.c.unlink("/tmp/vex_hnsw_test/emb.vhi.tmp");
        _ = std.c.rmdir("/tmp/vex_hnsw_test");
    }
    _ = std.c.mkdir("/tmp/vex_hnsw_test", 0o755);

    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    const vecs = [_][3]f32{
        .{ 1.0, 0.0, 0.0 }, .{ 0.9, 0.1, 0.0 }, .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 }, .{ 0.5, 0.5, 0.0 }, .{ 0.7, 0.7, 0.0 },
        .{ 0.1, 0.9, 0.0 }, .{ 0.0, 0.1, 0.9 }, .{ 0.8, 0.2, 0.0 },
        .{ 0.3, 0.3, 0.3 },
    };
    for (vecs, 0..) |v, i| try vs.set(@intCast(i), "emb", &v);

    // Build original index
    var idx = HnswIndex.init(allocator, 3, &vs, 0);
    defer idx.deinit();
    for (0..10) |i| try idx.insert(@intCast(i));

    // Search on original
    var query = [_]f32{ 1.0, 0.0, 0.0 };
    VectorStore.normalize(&query);
    const orig_results = try idx.search(&query, 3, null);
    defer allocator.free(orig_results);

    // Serialize
    try idx.serialize("/tmp/vex_hnsw_test", "emb");

    // Deserialize into a new index
    var idx2 = try HnswIndex.deserialize(allocator, "/tmp/vex_hnsw_test", "emb", &vs, 0);
    defer idx2.deinit();

    // Verify metadata
    try std.testing.expectEqual(idx.dim, idx2.dim);
    try std.testing.expectEqual(idx.node_count, idx2.node_count);
    try std.testing.expectEqual(idx.capacity, idx2.capacity);
    try std.testing.expectEqual(idx.max_level, idx2.max_level);
    try std.testing.expectEqual(idx.entry_point, idx2.entry_point);
    try std.testing.expectEqual(idx.M, idx2.M);
    try std.testing.expectEqual(idx.M_max0, idx2.M_max0);
    try std.testing.expectEqual(idx.rng_state, idx2.rng_state);

    // Search on deserialized — should return same results
    const deser_results = try idx2.search(&query, 3, null);
    defer allocator.free(deser_results);

    try std.testing.expectEqual(orig_results.len, deser_results.len);
    for (0..orig_results.len) |i| {
        try std.testing.expectEqual(orig_results[i].node_id, deser_results[i].node_id);
        try std.testing.expectApproxEqAbs(orig_results[i].distance, deser_results[i].distance, 0.001);
    }
}
