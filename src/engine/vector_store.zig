const std = @import("std");
const Allocator = std.mem.Allocator;
const StringIntern = @import("string_intern.zig").StringIntern;
// libc mmap/munmap (avoid Zig 0.16 platform-specific wrappers)
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern "c" fn munmap(addr: ?*anyopaque, len: usize) c_int;
const MAP_FAILED: *anyopaque = @ptrFromInt(std.math.maxInt(usize));

const VVF_MAGIC = [4]u8{ 'V', 'X', 'V', 'F' };
const VVF_VERSION: u8 = 1;
const VVF_HEADER_SIZE: usize = 20;
const DTYPE_F32: u8 = 0;
const DTYPE_F16: u8 = 1;

/// mmap'd vector field backed by a .vvf file on disk.
/// Entries are sorted by node_id for O(log n) binary search.
/// Vectors stored as f16, converted to f32 via double scratch buffers on read.
pub const MmapField = struct {
    mmap_ptr: [*]u8,
    mmap_len: usize,
    dim: u32,
    count: u32,
    dtype: u8,
    data_ptr: [*]const u8,
    entry_stride: u32,
    scratch_buffers: [2][]f32,
    scratch_idx: u1,
    fd: std.c.fd_t,

    /// Binary search for a node_id in sorted mmap'd entries.
    /// Returns f32 slice from double scratch buffer (valid until next call).
    pub fn getByNodeId(self: *MmapField, node_id: u32) ?[]const f32 {
        if (self.count == 0) return null;

        var lo: u32 = 0;
        var hi: u32 = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry_off = @as(usize, mid) * self.entry_stride;
            const eid = std.mem.readInt(u32, self.data_ptr[entry_off..][0..4], .little);
            if (eid == node_id) {
                const buf = self.scratch_buffers[self.scratch_idx];
                self.scratch_idx ^= 1;
                const vec_off = entry_off + 4;
                if (self.dtype == DTYPE_F16) {
                    for (0..self.dim) |i| {
                        const byte_off = vec_off + i * 2;
                        const bits = std.mem.readInt(u16, self.data_ptr[byte_off..][0..2], .little);
                        const f16_val: f16 = @bitCast(bits);
                        buf[i] = @floatCast(f16_val);
                    }
                } else {
                    for (0..self.dim) |i| {
                        const byte_off = vec_off + i * 4;
                        const bits = std.mem.readInt(u32, self.data_ptr[byte_off..][0..4], .little);
                        buf[i] = @bitCast(bits);
                    }
                }
                return buf[0..self.dim];
            } else if (eid < node_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    pub fn deinit(self: *MmapField, allocator: Allocator) void {
        _ = munmap(@ptrCast(self.mmap_ptr), self.mmap_len);
        _ = std.c.close(self.fd);
        allocator.free(self.scratch_buffers[0]);
        allocator.free(self.scratch_buffers[1]);
    }

    /// Iterate all node_ids in the mmap'd file.
    pub fn iterNodeIds(self: *const MmapField, out: *std.array_list.Managed(u32)) !void {
        for (0..self.count) |i| {
            const off = @as(usize, i) * self.entry_stride;
            const nid = std.mem.readInt(u32, self.data_ptr[off..][0..4], .little);
            try out.append(nid);
        }
    }
};

/// Dual-tier vector store: write buffer (heap f32) + mmap tier (disk f16).
///
/// Write flow: set() → heap-allocated f32 in write buffer
/// Read flow: getById() → check deleted → write buffer → mmap binary search
/// Save flow: merge write buffer + mmap → sorted f16 .vvf file → atomic rename
/// Load flow: mmap .vvf file → binary search on read
pub const VectorStore = struct {
    /// Write buffer: new/modified vectors since last save
    map: std.AutoHashMap(u64, []f32),
    field_intern: StringIntern,
    field_dims: [64]u32,
    field_dims_set: u64,
    allocator: Allocator,

    /// mmap backing per field_id (null = no mmap for this field)
    mmap_fields: [64]?MmapField,
    /// Tombstones for mmap'd entries that were deleted
    deleted_from_mmap: std.AutoHashMap(u64, void),
    /// Data directory for .vvf files
    data_dir: ?[]const u8,

    pub fn init(allocator: Allocator) VectorStore {
        return .{
            .map = std.AutoHashMap(u64, []f32).init(allocator),
            .field_intern = StringIntern.init(allocator),
            .field_dims = [_]u32{0} ** 64,
            .field_dims_set = 0,
            .allocator = allocator,
            .mmap_fields = [_]?MmapField{null} ** 64,
            .deleted_from_mmap = std.AutoHashMap(u64, void).init(allocator),
            .data_dir = null,
        };
    }

    pub fn deinit(self: *VectorStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
        self.field_intern.deinit();
        self.deleted_from_mmap.deinit();
        for (&self.mmap_fields) |*mf| {
            if (mf.*) |*m| m.deinit(self.allocator);
            mf.* = null;
        }
    }

    fn compositeKey(node_id: u32, field_id: u16) u64 {
        return (@as(u64, node_id) << 16) | @as(u64, field_id);
    }

    /// Store a vector. Goes to write buffer (heap f32), normalized on insert.
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
        // Remove from deleted set if re-inserting
        _ = self.deleted_from_mmap.remove(key);

        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned;
    }

    pub fn get(self: *const VectorStore, node_id: u32, field: []const u8) ?[]const f32 {
        const field_id = self.field_intern.find(field) orelse return null;
        return self.getById(node_id, field_id);
    }

    /// Dual-tier lookup: deleted → write buffer → mmap
    pub fn getById(self: *const VectorStore, node_id: u32, field_id: u16) ?[]const f32 {
        const key = compositeKey(node_id, field_id);
        if (self.deleted_from_mmap.contains(key)) return null;
        if (self.map.get(key)) |v| return v;
        if (self.mmap_fields[field_id]) |_| {
            // Interior mutability for scratch buffer (logically const)
            const self_mut: *VectorStore = @constCast(self);
            return self_mut.mmap_fields[field_id].?.getByNodeId(node_id);
        }
        return null;
    }

    pub fn deleteAll(self: *VectorStore, node_id: u32) void {
        const field_count = self.field_intern.count();
        for (0..field_count) |fi| {
            const key = compositeKey(node_id, @intCast(fi));
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value);
            }
            // Tombstone mmap'd entries
            if (self.mmap_fields[fi] != null) {
                self.deleted_from_mmap.put(key, {}) catch {};
            }
        }
    }

    pub fn delete(self: *VectorStore, node_id: u32, field: []const u8) bool {
        const field_id = self.field_intern.find(field) orelse return false;
        const key = compositeKey(node_id, field_id);
        var found = false;
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value);
            found = true;
        }
        if (self.mmap_fields[field_id] != null) {
            self.deleted_from_mmap.put(key, {}) catch {};
            found = true;
        }
        return found;
    }

    pub fn fieldDim(self: *const VectorStore, field: []const u8) ?u32 {
        const field_id = self.field_intern.find(field) orelse return null;
        return self.fieldDimById(field_id);
    }

    pub fn fieldDimById(self: *const VectorStore, field_id: u16) ?u32 {
        const mask = @as(u64, 1) << @intCast(field_id);
        if (self.field_dims_set & mask == 0) return null;
        return self.field_dims[field_id];
    }

    // ── Save/Load (.vvf files) ──────────────────────────────────────

    /// Save all vector fields to .vvf files in {data_dir}/vectors/.
    /// Merges write buffer + mmap → sorted f16 → atomic write.
    pub fn saveAllFields(self: *VectorStore, data_dir: []const u8) !void {
        // Create vectors directory
        var dir_buf: [512]u8 = undefined;
        const vec_dir = std.fmt.bufPrint(&dir_buf, "{s}/vectors", .{data_dir}) catch return;

        // Create directory via libc
        const dir_z = self.allocator.dupeZ(u8, vec_dir) catch return;
        defer self.allocator.free(dir_z);
        _ = std.c.mkdir(dir_z, 0o755);

        const field_count = self.field_intern.count();

        // Save fields in parallel — each .vvf file is independent
        const SaveCtx = struct {
            vs: *VectorStore,
            field_id: u16,
            field_name: []const u8,
            vec_dir: []const u8,
            err: bool = false,

            fn run(ctx: *@This()) void {
                ctx.vs.saveField(ctx.field_id, ctx.field_name, ctx.vec_dir) catch {
                    ctx.err = true;
                };
            }
        };

        var ctxs: [64]SaveCtx = undefined;
        var threads: [64]?std.Thread = .{null} ** 64;
        var thread_count: usize = 0;

        for (0..field_count) |fi| {
            const field_id: u16 = @intCast(fi);
            const mask = @as(u64, 1) << @intCast(field_id);
            if (self.field_dims_set & mask == 0) continue;

            const field_name = self.field_intern.resolve(field_id);

            if (thread_count < ctxs.len) {
                ctxs[thread_count] = .{ .vs = self, .field_id = field_id, .field_name = field_name, .vec_dir = vec_dir };
                threads[thread_count] = std.Thread.spawn(.{}, SaveCtx.run, .{&ctxs[thread_count]}) catch {
                    // Fallback: save inline
                    self.saveField(field_id, field_name, vec_dir) catch continue;
                    continue;
                };
                thread_count += 1;
            } else {
                self.saveField(field_id, field_name, vec_dir) catch continue;
            }
        }

        for (threads[0..thread_count]) |t| {
            if (t) |thread| thread.join();
        }
    }

    fn saveField(self: *VectorStore, field_id: u16, field_name: []const u8, vec_dir: []const u8) !void {
        const dim = self.field_dims[field_id];

        // Collect all (node_id, vector_f32) pairs from write buffer + mmap
        const Entry = struct { node_id: u32, vec: []const f32 };
        var entries = std.array_list.Managed(Entry).init(self.allocator);
        defer entries.deinit();

        // From mmap (if exists), excluding deleted
        if (self.mmap_fields[field_id]) |*mf| {
            for (0..mf.count) |i| {
                const off = @as(usize, i) * mf.entry_stride;
                const nid = std.mem.readInt(u32, mf.data_ptr[off..][0..4], .little);
                const key = compositeKey(nid, field_id);
                if (self.deleted_from_mmap.contains(key)) continue;
                if (self.map.contains(key)) continue; // write buffer overrides
                // Read via scratch buffer
                if (mf.getByNodeId(nid)) |vec| {
                    // Copy since scratch is volatile
                    const copy = try self.allocator.dupe(f32, vec);
                    try entries.append(.{ .node_id = nid, .vec = copy });
                }
            }
        }

        // From write buffer
        var map_it = self.map.iterator();
        while (map_it.next()) |kv| {
            const fid: u16 = @intCast(kv.key_ptr.* & 0xFFFF);
            if (fid != field_id) continue;
            const nid: u32 = @intCast(kv.key_ptr.* >> 16);
            try entries.append(.{ .node_id = nid, .vec = kv.value_ptr.* });
        }

        if (entries.items.len == 0) return;

        // Sort by node_id
        std.mem.sort(Entry, entries.items, {}, struct {
            fn cmp(_: void, a: Entry, b: Entry) bool {
                return a.node_id < b.node_id;
            }
        }.cmp);

        // Write .vvf file atomically
        var path_buf: [512]u8 = undefined;
        const tmp_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}.vvf.tmp", .{ vec_dir, field_name }) catch return;

        const fd = std.c.open(tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.FileOpenFailed;
        defer _ = std.c.close(fd);

        // Write header
        var header: [VVF_HEADER_SIZE]u8 = [_]u8{0} ** VVF_HEADER_SIZE;
        @memcpy(header[0..4], &VVF_MAGIC);
        header[4] = VVF_VERSION;
        header[5] = DTYPE_F16;
        std.mem.writeInt(u32, header[6..10], dim, .little);
        std.mem.writeInt(u32, header[10..14], @intCast(entries.items.len), .little);
        _ = std.c.write(fd, &header, VVF_HEADER_SIZE);

        // Write entries as f16
        for (entries.items) |entry| {
            var nid_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &nid_buf, entry.node_id, .little);
            _ = std.c.write(fd, &nid_buf, 4);

            // Convert f32 → f16 and write
            for (0..dim) |i| {
                const f16_val: f16 = @floatCast(entry.vec[i]);
                var f16_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &f16_buf, @bitCast(f16_val), .little);
                _ = std.c.write(fd, &f16_buf, 2);
            }
        }

        // Free mmap-sourced copies
        if (self.mmap_fields[field_id] != null) {
            for (entries.items) |entry| {
                // Only free copies we made from mmap (not write buffer pointers)
                const key = compositeKey(entry.node_id, field_id);
                if (!self.map.contains(key)) {
                    self.allocator.free(@constCast(entry.vec));
                }
            }
        }

        // Atomic rename
        var final_buf: [512]u8 = undefined;
        const final_path = std.fmt.bufPrintZ(&final_buf, "{s}/{s}.vvf", .{ vec_dir, field_name }) catch return;
        _ = std.c.rename(tmp_path, final_path);
    }

    /// Load all .vvf files from {data_dir}/vectors/ via mmap.
    pub fn loadAllFields(self: *VectorStore, data_dir: []const u8) !void {
        self.data_dir = data_dir;
        var path_buf: [512]u8 = undefined;
        const vec_dir = std.fmt.bufPrint(&path_buf, "{s}/vectors", .{data_dir}) catch return;

        // Scan for .vvf files by trying known field names
        // Since we don't have directory listing easily, we check if the field_intern
        // has fields. On fresh load, fields come from the file names.
        // Approach: try to open files for common field names or scan existing fields.
        // For now, scan field_intern if populated, otherwise try a hardcoded scan.

        // If field_intern has entries (from AOF replay), load those fields
        const fc = self.field_intern.count();
        if (fc > 0) {
            for (0..fc) |fi| {
                const fname = self.field_intern.resolve(@intCast(fi));
                self.loadFieldByName(fname, vec_dir, @intCast(fi)) catch continue;
            }
            return;
        }

        // Otherwise try common embedding field names
        const common_names = [_][]const u8{ "embedding", "emb", "text_embedding", "image_embedding", "desc_emb" };
        for (common_names) |name| {
            const field_id = self.field_intern.intern(name) catch continue;
            self.loadFieldByName(name, vec_dir, field_id) catch {
                // Field file doesn't exist, that's fine
                continue;
            };
        }
    }

    fn loadFieldByName(self: *VectorStore, field_name: []const u8, vec_dir: []const u8, field_id: u16) !void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}.vvf", .{ vec_dir, field_name }) catch return error.PathTooLong;

        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.FileNotFound;

        // Get file size via lseek (cross-platform, avoids fstat Linux gap)
        const size = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (size < 0) {
            _ = std.c.close(fd);
            return error.StatFailed;
        }
        _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
        const file_len: usize = @intCast(size);
        if (file_len < VVF_HEADER_SIZE) {
            _ = std.c.close(fd);
            return error.FileTooSmall;
        }

        // mmap the file
        const raw_ptr = mmap(null, file_len, 1, 1, fd, 0); // PROT_READ=1, MAP_SHARED=1
        if (raw_ptr == null or raw_ptr == MAP_FAILED) {
            _ = std.c.close(fd);
            return error.MmapFailed;
        }
        const ptr: [*]u8 = @ptrCast(raw_ptr.?);

        // Validate header
        if (!std.mem.eql(u8, ptr[0..4], &VVF_MAGIC)) {
            _ = munmap(@ptrCast(ptr), file_len);
            _ = std.c.close(fd);
            return error.InvalidMagic;
        }

        const dtype = ptr[5];
        const dim = std.mem.readInt(u32, ptr[6..10], .little);
        const count = std.mem.readInt(u32, ptr[10..14], .little);
        const elem_size: u32 = if (dtype == DTYPE_F16) 2 else 4;
        const entry_stride = 4 + dim * elem_size;

        // Allocate scratch buffers
        const scratch0 = try self.allocator.alloc(f32, dim);
        const scratch1 = try self.allocator.alloc(f32, dim);

        self.mmap_fields[field_id] = .{
            .mmap_ptr = ptr,
            .mmap_len = file_len,
            .dim = dim,
            .count = count,
            .dtype = dtype,
            .data_ptr = ptr + VVF_HEADER_SIZE,
            .entry_stride = entry_stride,
            .scratch_buffers = .{ scratch0, scratch1 },
            .scratch_idx = 0,
            .fd = fd,
        };

        // Set field dimension
        const mask = @as(u64, 1) << @intCast(field_id);
        self.field_dims[field_id] = dim;
        self.field_dims_set |= mask;
    }

    /// Count of vectors for a field (write buffer + mmap - deleted).
    pub fn countField(self: *const VectorStore, field_id: u16) u32 {
        var count: u32 = 0;
        // Count mmap entries (minus deleted)
        if (self.mmap_fields[field_id]) |mf| {
            count += mf.count;
            // Subtract deleted
            var dit = self.deleted_from_mmap.iterator();
            while (dit.next()) |d| {
                if (@as(u16, @intCast(d.key_ptr.* & 0xFFFF)) == field_id) count -|= 1;
            }
        }
        // Count write buffer entries (not already in mmap)
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (@as(u16, @intCast(kv.key_ptr.* & 0xFFFF)) == field_id) {
                const nid: u32 = @intCast(kv.key_ptr.* >> 16);
                // Don't double-count if also in mmap
                if (self.mmap_fields[field_id]) |_| {
                    // Check if this node exists in mmap (would be double-counted)
                    const self_mut: *VectorStore = @constCast(self);
                    if (self_mut.mmap_fields[field_id].?.getByNodeId(nid) != null) continue;
                }
                count += 1;
            }
        }
        return count;
    }

    // ── Vector math ─────────────────────────────────────────────────

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

test "f16 conversion precision" {
    // Verify f16 round-trip precision is acceptable for cosine similarity
    const f32_vec = [_]f32{ 0.036, -0.042, 0.051, 0.028 };
    var f16_vec: [4]f16 = undefined;
    for (0..4) |i| f16_vec[i] = @floatCast(f32_vec[i]);

    var back: [4]f32 = undefined;
    for (0..4) |i| back[i] = @floatCast(f16_vec[i]);

    // f16 has ~3 decimal digits of precision — error should be < 0.001
    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(f32_vec[i], back[i], 0.001);
    }
}

test "vector store save and load round-trip" {
    const allocator = std.testing.allocator;

    // Clean up test files
    defer {
        _ = std.c.unlink("/tmp/vex_vec_test/vectors/emb.vvf");
        _ = std.c.unlink("/tmp/vex_vec_test/vectors/emb.vvf.tmp");
        _ = std.c.rmdir("/tmp/vex_vec_test/vectors");
        _ = std.c.rmdir("/tmp/vex_vec_test");
    }
    _ = std.c.mkdir("/tmp/vex_vec_test", 0o755);

    // Save
    {
        var vs = VectorStore.init(allocator);
        defer vs.deinit();

        try vs.set(0, "emb", &[_]f32{ 1.0, 0.0, 0.0 });
        try vs.set(1, "emb", &[_]f32{ 0.0, 1.0, 0.0 });
        try vs.set(2, "emb", &[_]f32{ 0.0, 0.0, 1.0 });

        try vs.saveAllFields("/tmp/vex_vec_test");
    }

    // Load into a fresh store
    {
        var vs2 = VectorStore.init(allocator);
        defer vs2.deinit();

        _ = try vs2.field_intern.intern("emb");
        vs2.field_dims[0] = 3;
        vs2.field_dims_set |= 1;
        try vs2.loadAllFields("/tmp/vex_vec_test");

        // Verify mmap field loaded
        try std.testing.expect(vs2.mmap_fields[0] != null);

        // Verify vectors round-trip (f16 precision)
        const v0 = vs2.getById(0, 0).?;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v0[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v0[1], 0.01);

        const v1 = vs2.getById(1, 0).?;
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v1[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v1[1], 0.01);

        // Verify node 2
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

    // Save initial vectors
    {
        var vs = VectorStore.init(allocator);
        defer vs.deinit();
        try vs.set(0, "emb", &[_]f32{ 1.0, 0.0, 0.0 });
        try vs.saveAllFields("/tmp/vex_dual_test");
    }

    // Load, then override with write buffer
    {
        var vs2 = VectorStore.init(allocator);
        defer vs2.deinit();
        _ = try vs2.field_intern.intern("emb");
        vs2.field_dims[0] = 3;
        vs2.field_dims_set |= 1;
        try vs2.loadAllFields("/tmp/vex_dual_test");

        // mmap has [1,0,0], write buffer will have [0,1,0]
        try vs2.set(0, "emb", &[_]f32{ 0.0, 1.0, 0.0 });

        // getById should return write buffer version
        const v = vs2.getById(0, 0).?;
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[1], 0.01);
    }
}
