const std = @import("std");
const Allocator = std.mem.Allocator;
const StringIntern = @import("string_intern.zig").StringIntern;

/// Stores f32 vectors per (NodeId, field_name).
/// Follows the same composite-key pattern as PropertyStore.
/// Vectors are pre-normalized to unit length on insert (cosine similarity = dot product).
pub const VectorStore = struct {
    /// Key: (node_id:u32 << 16) | field_id:u16 → owned []f32
    map: std.AutoHashMap(u64, []f32),
    field_intern: StringIntern,
    /// Dimension per field_id (set on first insert, enforced after).
    field_dims: [64]u32,
    /// Bitmask: which field_ids have their dimension established.
    field_dims_set: u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator) VectorStore {
        return .{
            .map = std.AutoHashMap(u64, []f32).init(allocator),
            .field_intern = StringIntern.init(allocator),
            .field_dims = [_]u32{0} ** 64,
            .field_dims_set = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VectorStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
        self.field_intern.deinit();
    }

    fn compositeKey(node_id: u32, field_id: u16) u64 {
        return (@as(u64, node_id) << 16) | @as(u64, field_id);
    }

    /// Store a vector for a node+field. Normalizes to unit length.
    pub fn set(self: *VectorStore, node_id: u32, field: []const u8, vec: []const f32) !void {
        if (vec.len == 0) return error.InvalidVector;

        const field_id = try self.field_intern.intern(field);
        const dim: u32 = @intCast(vec.len);

        const mask = @as(u64, 1) << @intCast(field_id);
        if (self.field_dims_set & mask != 0) {
            if (self.field_dims[field_id] != dim) return error.DimensionMismatch;
        } else {
            self.field_dims[field_id] = dim;
            self.field_dims_set |= mask;
        }

        const owned = try self.allocator.alloc(f32, dim);
        @memcpy(owned, vec);
        normalize(owned);

        const key = compositeKey(node_id, field_id);
        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned;
    }

    pub fn get(self: *const VectorStore, node_id: u32, field: []const u8) ?[]const f32 {
        const field_id = self.field_intern.find(field) orelse return null;
        const key = compositeKey(node_id, field_id);
        return self.map.get(key);
    }

    pub fn getById(self: *const VectorStore, node_id: u32, field_id: u16) ?[]const f32 {
        const key = compositeKey(node_id, field_id);
        return self.map.get(key);
    }

    pub fn deleteAll(self: *VectorStore, node_id: u32) void {
        const field_count = self.field_intern.count();
        for (0..field_count) |fi| {
            const key = compositeKey(node_id, @intCast(fi));
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value);
            }
        }
    }

    pub fn delete(self: *VectorStore, node_id: u32, field: []const u8) bool {
        const field_id = self.field_intern.find(field) orelse return false;
        const key = compositeKey(node_id, field_id);
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    pub fn fieldDim(self: *const VectorStore, field: []const u8) ?u32 {
        const field_id = self.field_intern.find(field) orelse return null;
        const mask = @as(u64, 1) << @intCast(field_id);
        if (self.field_dims_set & mask == 0) return null;
        return self.field_dims[field_id];
    }

    pub fn fieldDimById(self: *const VectorStore, field_id: u16) ?u32 {
        const mask = @as(u64, 1) << @intCast(field_id);
        if (self.field_dims_set & mask == 0) return null;
        return self.field_dims[field_id];
    }

    pub fn normalize(vec: []f32) void {
        var sum: f32 = 0;
        for (vec) |v| sum += v * v;
        if (sum == 0) return;
        const inv_norm = 1.0 / @sqrt(sum);
        for (vec) |*v| v.* *= inv_norm;
    }

    pub fn dotProduct(a: []const f32, b: []const f32) f32 {
        const len = @min(a.len, b.len);
        var sum: f32 = 0;
        for (0..len) |i| sum += a[i] * b[i];
        return sum;
    }

    pub fn cosineDistance(a: []const f32, b: []const f32) f32 {
        return 1.0 - dotProduct(a, b);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

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
