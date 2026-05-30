// Migrated unit tests for src/engine/vector_store.zig.

const std = @import("std");
const VectorStore = @import("../../../src/engine/vector_store.zig").VectorStore;

test "vector store set and get" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    const vec = [_]f32{ 1.0, 0.0, 0.0 };
    try vs.set(0, "embedding", &vec);

    const got = vs.get(0, "embedding").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), got[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), got[1], 0.001);
}

test "vector store normalize" {
    var vec = [_]f32{ 3.0, 4.0 };
    VectorStore.normalize(&vec);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), vec[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), vec[1], 0.001);
}

test "vector store dimension mismatch" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    try vs.set(0, "emb", &[_]f32{ 1.0, 0.0, 0.0 });
    try std.testing.expectError(error.DimensionMismatch, vs.set(1, "emb", &[_]f32{ 1.0, 0.0 }));
}

test "vector store deleteAll" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    try vs.set(5, "emb1", &[_]f32{ 1.0, 0.0, 0.0 });
    try vs.set(5, "emb2", &[_]f32{ 0.0, 1.0 });
    vs.deleteAll(5);
    try std.testing.expect(vs.get(5, "emb1") == null);
    try std.testing.expect(vs.get(5, "emb2") == null);
}

test "vector store multiple fields" {
    const allocator = std.testing.allocator;
    var vs = VectorStore.init(allocator);
    defer vs.deinit();

    try vs.set(0, "text", &[_]f32{ 1.0, 0.0, 0.0 });
    try vs.set(0, "image", &[_]f32{ 0.0, 1.0 });
    try std.testing.expectEqual(@as(?u32, 3), vs.fieldDim("text"));
    try std.testing.expectEqual(@as(?u32, 2), vs.fieldDim("image"));
}

test "vector store dot product" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), VectorStore.dotProduct(&a, &b), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), VectorStore.dotProduct(&a, &a), 0.001);
}

test "vector store cosine distance" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), VectorStore.cosineDistance(&a, &b), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), VectorStore.cosineDistance(&a, &a), 0.001);
}

test "f16 conversion precision" {
    const f32_vec = [_]f32{ 0.036, -0.042, 0.051, 0.028 };
    var f16_vec: [4]f16 = undefined;
    for (0..4) |i| f16_vec[i] = @floatCast(f32_vec[i]);

    var back: [4]f32 = undefined;
    for (0..4) |i| back[i] = @floatCast(f16_vec[i]);

    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(f32_vec[i], back[i], 0.001);
    }
}

test "vector store save and load round-trip" {
    const allocator = std.testing.allocator;

    defer {
        _ = std.c.unlink("/tmp/vex_vec_test/vectors/emb.vvf");
        _ = std.c.unlink("/tmp/vex_vec_test/vectors/emb.vvf.tmp");
        _ = std.c.rmdir("/tmp/vex_vec_test/vectors");
        _ = std.c.rmdir("/tmp/vex_vec_test");
    }
    _ = std.c.mkdir("/tmp/vex_vec_test", 0o755);

    {
        var vs = VectorStore.init(allocator);
        defer vs.deinit();

        try vs.set(0, "emb", &[_]f32{ 1.0, 0.0, 0.0 });
        try vs.set(1, "emb", &[_]f32{ 0.0, 1.0, 0.0 });
        try vs.set(2, "emb", &[_]f32{ 0.0, 0.0, 1.0 });

        try vs.saveAllFields("/tmp/vex_vec_test");
    }

    {
        var vs2 = VectorStore.init(allocator);
        defer vs2.deinit();

        _ = try vs2.field_intern.intern("emb");
        vs2.field_dims[0] = 3;
        vs2.field_dims_set |= 1;
        try vs2.loadAllFields("/tmp/vex_vec_test");

        try std.testing.expect(vs2.mmap_fields[0] != null);

        const v0 = vs2.getById(0, 0).?;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v0[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v0[1], 0.01);

        const v1 = vs2.getById(1, 0).?;
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v1[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v1[1], 0.01);

        const v2 = vs2.getById(2, 0).?;
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v2[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v2[2], 0.01);
    }
}

test "vector store dual-tier write buffer overrides mmap" {
    const allocator = std.testing.allocator;

    defer {
        _ = std.c.unlink("/tmp/vex_dual_test/vectors/emb.vvf");
        _ = std.c.unlink("/tmp/vex_dual_test/vectors/emb.vvf.tmp");
        _ = std.c.rmdir("/tmp/vex_dual_test/vectors");
        _ = std.c.rmdir("/tmp/vex_dual_test");
    }
    _ = std.c.mkdir("/tmp/vex_dual_test", 0o755);

    {
        var vs = VectorStore.init(allocator);
        defer vs.deinit();
        try vs.set(0, "emb", &[_]f32{ 1.0, 0.0, 0.0 });
        try vs.saveAllFields("/tmp/vex_dual_test");
    }

    {
        var vs2 = VectorStore.init(allocator);
        defer vs2.deinit();
        _ = try vs2.field_intern.intern("emb");
        vs2.field_dims[0] = 3;
        vs2.field_dims_set |= 1;
        try vs2.loadAllFields("/tmp/vex_dual_test");

        try vs2.set(0, "emb", &[_]f32{ 0.0, 1.0, 0.0 });

        const v = vs2.getById(0, 0).?;
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[1], 0.01);
    }
}
