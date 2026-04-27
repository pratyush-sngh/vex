const std = @import("std");
const Allocator = std.mem.Allocator;
const StringIntern = @import("string_intern.zig").StringIntern;
const TypeMask = @import("string_intern.zig").TypeMask;
const PropertyStore = @import("property_store.zig").PropertyStore;
pub const VectorStore = @import("vector_store.zig").VectorStore;
pub const HnswIndex = @import("hnsw.zig").HnswIndex;

pub const NodeId = u32;
pub const EdgeId = u32;
pub const INVALID_ID: u32 = std.math.maxInt(u32);

/// Compressed Sparse Row adjacency structure.
/// Node i's neighbors: targets[offsets[i]..offsets[i+1]]
pub const CSR = struct {
    offsets: []u32, // [capacity + 1]
    targets: []NodeId, // [edge_count]
    edge_idx: []u32, // [edge_count] — maps CSR pos → edge store index

    pub fn empty() CSR {
        return .{ .offsets = &.{}, .targets = &.{}, .edge_idx = &.{} };
    }

    pub fn neighbors(self: *const CSR, node_id: NodeId) []const NodeId {
        if (self.offsets.len == 0) return &.{};
        if (node_id + 1 >= self.offsets.len) return &.{};
        const start = self.offsets[node_id];
        const end = self.offsets[node_id + 1];
        if (start >= end) return &.{};
        return self.targets[start..end];
    }

    pub fn edgeIndices(self: *const CSR, node_id: NodeId) []const u32 {
        if (self.offsets.len == 0) return &.{};
        if (node_id + 1 >= self.offsets.len) return &.{};
        const start = self.offsets[node_id];
        const end = self.offsets[node_id + 1];
        if (start >= end) return &.{};
        return self.edge_idx[start..end];
    }

    pub fn deinit(self: *CSR, allocator: Allocator) void {
        if (self.offsets.len > 0) allocator.free(self.offsets);
        if (self.targets.len > 0) allocator.free(self.targets);
        if (self.edge_idx.len > 0) allocator.free(self.edge_idx);
        self.* = empty();
    }
};

/// Flat delta edge entry — used instead of a delta CSR.
/// Small delta (<100 edges typically) is scanned linearly per node.
/// This avoids O(delta_size) CSR rebuild on every addEdge.
pub const DeltaEdge = struct {
    from: NodeId,
    to: NodeId,
    eidx: u32,
};

pub const GraphFlags = packed struct {
    uniform_weights: bool = true,
    has_node_props: bool = false,
    has_edge_props: bool = false,
    is_untyped: bool = true,
    _padding: u4 = 0,
};

pub const GraphEngine = struct {
    allocator: Allocator,
    flags: GraphFlags,

    // ─── Node Store (SoA) ───────────────────
    node_keys: std.array_list.Managed([]const u8),
    node_type_id: std.array_list.Managed(u16),
    node_alive: std.DynamicBitSet,
    node_prop_mask: std.array_list.Managed(u64),
    node_out_type_mask: std.array_list.Managed(TypeMask),
    node_in_type_mask: std.array_list.Managed(TypeMask),
    key_to_id: std.StringHashMap(NodeId),

    // ─── Edge Store (SoA) ───────────────────
    edge_from: std.array_list.Managed(NodeId),
    edge_to: std.array_list.Managed(NodeId),
    edge_weight: std.array_list.Managed(f64),
    edge_type_id: std.array_list.Managed(u16),
    edge_alive: std.DynamicBitSet,
    edge_prop_mask: std.array_list.Managed(u64),

    // ─── Topology ───────────────────────────
    base_out: CSR, // compacted outgoing adjacency
    base_in: CSR, // compacted incoming adjacency
    /// Flat delta edges — appended on addEdge, cleared on compact.
    /// Linear scan per node during traverse (fast for small delta).
    delta_edges: std.array_list.Managed(DeltaEdge),

    // ─── Shared Infrastructure ──────────────
    type_intern: StringIntern,
    node_props: PropertyStore,
    edge_props: PropertyStore,

    // ─── Vector Infrastructure (lazy: null until first GRAPH.SETVEC) ──
    vec_store: ?VectorStore,
    vec_indices: ?std.StringHashMap(*HnswIndex),

    // ─── Compaction state ───────────────────
    needs_compact: bool,
    /// Monotonically increasing mutation counter. Incremented on every
    /// write operation. Used as replication cursor for followers.
    mutation_seq: u64,
    /// True when all edges in the base CSR are alive (no deletions since
    /// last compact). Allows skipping edge_alive checks and edge_idx
    /// loads in the traverse hot path — halves CSR data loaded.
    all_base_edges_alive: bool,
    /// Set true during bulk loading to skip per-edge bookkeeping.
    /// Call compact() after bulk loading completes.
    bulk_loading: bool,

    pub fn init(allocator: Allocator) GraphEngine {
        return .{
            .allocator = allocator,
            .flags = .{},
            .node_keys = std.array_list.Managed([]const u8).init(allocator),
            .node_type_id = std.array_list.Managed(u16).init(allocator),
            .node_alive = std.DynamicBitSet.initEmpty(allocator, 0) catch unreachable,
            .node_prop_mask = std.array_list.Managed(u64).init(allocator),
            .node_out_type_mask = std.array_list.Managed(TypeMask).init(allocator),
            .node_in_type_mask = std.array_list.Managed(TypeMask).init(allocator),
            .key_to_id = std.StringHashMap(NodeId).init(allocator),
            .edge_from = std.array_list.Managed(NodeId).init(allocator),
            .edge_to = std.array_list.Managed(NodeId).init(allocator),
            .edge_weight = std.array_list.Managed(f64).init(allocator),
            .edge_type_id = std.array_list.Managed(u16).init(allocator),
            .edge_alive = std.DynamicBitSet.initEmpty(allocator, 0) catch unreachable,
            .edge_prop_mask = std.array_list.Managed(u64).init(allocator),
            .base_out = CSR.empty(),
            .base_in = CSR.empty(),
            .delta_edges = std.array_list.Managed(DeltaEdge).init(allocator),
            .type_intern = StringIntern.init(allocator),
            .node_props = PropertyStore.init(allocator),
            .edge_props = PropertyStore.init(allocator),
            .vec_store = null,
            .vec_indices = null,
            .needs_compact = false,
            .mutation_seq = 0,
            .all_base_edges_alive = true,
            .bulk_loading = false,
        };
    }

    pub fn deinit(self: *GraphEngine) void {
        for (self.node_keys.items) |k| self.allocator.free(k);
        self.node_keys.deinit();
        self.node_type_id.deinit();
        self.node_alive.deinit();
        self.node_prop_mask.deinit();
        self.node_out_type_mask.deinit();
        self.node_in_type_mask.deinit();
        self.key_to_id.deinit();
        self.edge_from.deinit();
        self.edge_to.deinit();
        self.edge_weight.deinit();
        self.edge_type_id.deinit();
        self.edge_alive.deinit();
        self.edge_prop_mask.deinit();
        self.base_out.deinit(self.allocator);
        self.base_in.deinit(self.allocator);
        self.delta_edges.deinit();
        self.type_intern.deinit();
        self.node_props.deinit();
        self.edge_props.deinit();
        if (self.vec_indices) |*vi| {
            var vi_iter = vi.iterator();
            while (vi_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            vi.deinit();
        }
        if (self.vec_store) |*vs| vs.deinit();
    }

    // ─── Node Operations ──────────────────────────────────────────────

    pub fn addNode(self: *GraphEngine, key: []const u8, node_type: []const u8) !NodeId {
        if (self.key_to_id.get(key) != null) return error.DuplicateNode;

        const id: NodeId = @intCast(self.node_keys.items.len);
        const type_id = try self.type_intern.intern(node_type);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        try self.node_keys.append(owned_key);
        errdefer _ = self.node_keys.pop();
        try self.node_type_id.append(type_id);
        try self.node_prop_mask.append(0);
        try self.node_out_type_mask.append(0);
        try self.node_in_type_mask.append(0);

        try self.node_alive.resize(id + 1, true);
        self.node_alive.set(id);

        try self.key_to_id.put(owned_key, id);

        if (self.type_intern.count() > 1) self.flags.is_untyped = false;

        self.mutation_seq += 1;
        return id;
    }

    pub fn getNode(self: *const GraphEngine, key: []const u8) ?NodeView {
        const id = self.key_to_id.get(key) orelse return null;
        if (!self.node_alive.isSet(id)) return null;
        return self.nodeView(id);
    }

    pub fn getNodeById(self: *const GraphEngine, id: NodeId) ?NodeView {
        if (id >= self.node_keys.items.len) return null;
        if (!self.node_alive.isSet(id)) return null;
        return self.nodeView(id);
    }

    fn nodeView(self: *const GraphEngine, id: NodeId) NodeView {
        return .{
            .id = id,
            .key = self.node_keys.items[id],
            .node_type = self.type_intern.resolve(self.node_type_id.items[id]),
            .prop_mask = self.node_prop_mask.items[id],
        };
    }

    pub fn resolveKey(self: *const GraphEngine, key: []const u8) ?NodeId {
        const id = self.key_to_id.get(key) orelse return null;
        if (!self.node_alive.isSet(id)) return null;
        return id;
    }

    pub fn setNodeProperty(self: *GraphEngine, key: []const u8, prop_key: []const u8, prop_val: []const u8) !void {
        const id = self.resolveKey(key) orelse return error.NodeNotFound;
        try self.node_props.set(id, prop_key, prop_val);

        if (self.node_props.key_intern.find(prop_key)) |kid| {
            if (kid < 64) {
                self.node_prop_mask.items[id] |= @as(u64, 1) << @intCast(kid);
            }
        }
        self.flags.has_node_props = true;
        self.mutation_seq += 1;
    }

    /// Lazily initialize vector infrastructure on first use.
    fn ensureVecInit(self: *GraphEngine) void {
        if (self.vec_store == null) {
            self.vec_store = VectorStore.init(self.allocator);
            self.vec_indices = std.StringHashMap(*HnswIndex).init(self.allocator);
        }
    }

    /// Store a vector on a node. Creates HNSW index for the field if needed.
    /// Lazily initializes vector infrastructure on first call.
    pub fn setVector(self: *GraphEngine, key: []const u8, field: []const u8, vec: []const f32) !void {
        const id = self.resolveKey(key) orelse return error.NodeNotFound;
        self.ensureVecInit();
        var vs = &self.vec_store.?;
        try vs.set(id, field, vec);

        var vi = &self.vec_indices.?;
        if (!vi.contains(field)) {
            const dim = vs.fieldDim(field) orelse return error.InternalError;
            const field_id = vs.field_intern.find(field) orelse return error.InternalError;
            const idx = try self.allocator.create(HnswIndex);
            idx.* = HnswIndex.init(self.allocator, dim, vs, field_id);
            const owned_field = try self.allocator.dupe(u8, field);
            try vi.put(owned_field, idx);
        }

        const idx = vi.get(field).?;
        try idx.insert(id);
        self.mutation_seq += 1;
    }

    /// Get a node's vector for a field. Returns null if vectors not initialized.
    pub fn getVector(self: *const GraphEngine, key: []const u8, field: []const u8) ?[]const f32 {
        const vs = self.vec_store orelse return null;
        const id = self.resolveKey(key) orelse return null;
        return vs.get(id, field);
    }

    /// Save all vector fields to .vvf files. No-op if vectors not initialized.
    pub fn saveVectors(self: *GraphEngine, data_dir: []const u8) !void {
        var vs = &(self.vec_store orelse return);
        try vs.saveAllFields(data_dir);
    }

    /// Load vector files from data_dir/vectors/ and rebuild HNSW indices.
    /// Lazily initializes vector infrastructure if .vvf files exist.
    pub fn loadVectors(self: *GraphEngine, data_dir: []const u8) !void {
        self.ensureVecInit();
        var vs = &self.vec_store.?;
        try vs.loadAllFields(data_dir);

        // Check if anything was actually loaded
        var has_vectors = false;
        for (vs.mmap_fields) |mf| {
            if (mf != null) { has_vectors = true; break; }
        }
        if (!has_vectors) {
            // Nothing loaded — revert to null to stay lazy
            vs.deinit();
            self.vec_store = null;
            self.vec_indices.?.deinit();
            self.vec_indices = null;
            return;
        }

        // Rebuild HNSW indices from loaded mmap data
        var vi = &self.vec_indices.?;
        const field_count = vs.field_intern.count();
        for (0..field_count) |fi| {
            const field_id: u16 = @intCast(fi);
            if (vs.mmap_fields[fi] == null) continue;

            const field_name = vs.field_intern.resolve(field_id);
            const dim = vs.field_dims[fi];

            if (!vi.contains(field_name)) {
                const idx = try self.allocator.create(HnswIndex);
                idx.* = HnswIndex.init(self.allocator, dim, vs, field_id);
                const owned_field = try self.allocator.dupe(u8, field_name);
                try vi.put(owned_field, idx);
            }

            const mf = &vs.mmap_fields[fi].?;
            var node_ids = std.array_list.Managed(u32).init(self.allocator);
            defer node_ids.deinit();
            try mf.iterNodeIds(&node_ids);

            const idx = vi.get(field_name).?;
            for (node_ids.items) |nid| {
                idx.insert(nid) catch continue;
            }
        }
    }

    pub fn removeNode(self: *GraphEngine, key: []const u8) !void {
        const id = self.resolveKey(key) orelse return error.NodeNotFound;

        for (0..self.edge_from.items.len) |eidx| {
            if (!self.edge_alive.isSet(eidx)) continue;
            if (self.edge_from.items[eidx] == id or self.edge_to.items[eidx] == id) {
                self.edge_alive.unset(eidx);
                self.all_base_edges_alive = false;
            }
        }

        self.node_alive.unset(id);
        _ = self.key_to_id.remove(key);
        self.node_props.deleteAll(id);
        if (self.vec_store) |*vs| vs.deleteAll(id);
        self.needs_compact = true;
        self.mutation_seq += 1;
    }

    // ─── Edge Operations ──────────────────────────────────────────────

    pub fn addEdge(self: *GraphEngine, from_key: []const u8, to_key: []const u8, edge_type: []const u8, weight: f64) !EdgeId {
        const from_id = self.resolveKey(from_key) orelse return error.NodeNotFound;
        const to_id = self.resolveKey(to_key) orelse return error.NodeNotFound;

        const eid: EdgeId = @intCast(self.edge_from.items.len);
        const type_id = try self.type_intern.intern(edge_type);

        try self.edge_from.append(from_id);
        try self.edge_to.append(to_id);
        try self.edge_weight.append(weight);
        try self.edge_type_id.append(type_id);
        try self.edge_prop_mask.append(0);
        try self.edge_alive.resize(eid + 1, true);
        self.edge_alive.set(eid);

        // Update node type masks
        const type_bit = StringIntern.mask(type_id);
        self.node_out_type_mask.items[from_id] |= type_bit;
        self.node_in_type_mask.items[to_id] |= type_bit;

        if (weight != 1.0) self.flags.uniform_weights = false;
        if (self.type_intern.count() > 1) self.flags.is_untyped = false;

        // Append to flat delta — O(1), no CSR rebuild
        if (!self.bulk_loading) {
            try self.delta_edges.append(.{ .from = from_id, .to = to_id, .eidx = eid });

            // Auto-compact: when delta grows large, rebuild CSR.
            // Without this, traversals scan the entire delta linearly (O(E) per node).
            if (self.delta_edges.items.len > 1000 and
                self.delta_edges.items.len > self.base_out.targets.len / 5)
            {
                try self.compact();
            }
        }

        self.mutation_seq += 1;
        return eid;
    }

    pub fn getEdge(self: *const GraphEngine, eid: EdgeId) ?EdgeView {
        if (eid >= self.edge_from.items.len) return null;
        if (!self.edge_alive.isSet(eid)) return null;
        return .{
            .id = eid,
            .from = self.edge_from.items[eid],
            .to = self.edge_to.items[eid],
            .edge_type = self.type_intern.resolve(self.edge_type_id.items[eid]),
            .weight = self.edge_weight.items[eid],
            .prop_mask = self.edge_prop_mask.items[eid],
        };
    }

    pub fn removeEdge(self: *GraphEngine, eid: EdgeId) !void {
        if (eid >= self.edge_from.items.len) return error.EdgeNotFound;
        if (!self.edge_alive.isSet(eid)) return error.EdgeNotFound;

        self.edge_alive.unset(eid);
        self.edge_props.deleteAll(eid);
        self.all_base_edges_alive = false;
        self.needs_compact = true;
        self.mutation_seq += 1;
    }

    pub fn setEdgeProperty(self: *GraphEngine, eid: EdgeId, prop_key: []const u8, prop_val: []const u8) !void {
        if (eid >= self.edge_from.items.len) return error.EdgeNotFound;
        if (!self.edge_alive.isSet(eid)) return error.EdgeNotFound;

        try self.edge_props.set(eid, prop_key, prop_val);

        if (self.edge_props.key_intern.find(prop_key)) |kid| {
            if (kid < 64) {
                self.edge_prop_mask.items[eid] |= @as(u64, 1) << @intCast(kid);
            }
        }
        self.flags.has_edge_props = true;
        self.mutation_seq += 1;
    }

    // ─── Query Primitives (used by query_v2.zig) ─────────────────────

    pub fn outgoingNeighbors(self: *const GraphEngine, id: NodeId) struct { base: []const NodeId, delta: []const NodeId } {
        return .{
            .base = self.base_out.neighbors(id),
            .delta = &.{}, // delta is now flat list, not CSR
        };
    }

    pub fn incomingNeighbors(self: *const GraphEngine, id: NodeId) struct { base: []const NodeId, delta: []const NodeId } {
        return .{
            .base = self.base_in.neighbors(id),
            .delta = &.{},
        };
    }

    pub fn outgoingEdgeIndices(self: *const GraphEngine, id: NodeId) struct { base: []const u32, delta: []const u32 } {
        return .{
            .base = self.base_out.edgeIndices(id),
            .delta = &.{},
        };
    }

    pub fn incomingEdgeIndices(self: *const GraphEngine, id: NodeId) struct { base: []const u32, delta: []const u32 } {
        return .{
            .base = self.base_in.edgeIndices(id),
            .delta = &.{},
        };
    }

    pub fn nodeCount(self: *const GraphEngine) usize {
        return self.key_to_id.count();
    }

    pub fn edgeCount(self: *const GraphEngine) usize {
        var c: usize = 0;
        for (0..self.edge_from.items.len) |i| {
            if (self.edge_alive.isSet(i)) c += 1;
        }
        return c;
    }

    // ─── CSR Building ─────────────────────────────────────────────────

    fn buildCSR(self: *GraphEngine, start_edge: u32, outgoing: bool) !CSR {
        const edge_count = self.edge_from.items.len;
        if (start_edge >= edge_count) return CSR.empty();

        const node_capacity: u32 = @intCast(self.node_keys.items.len);
        if (node_capacity == 0) return CSR.empty();

        const offsets = try self.allocator.alloc(u32, node_capacity + 1);
        errdefer self.allocator.free(offsets);
        @memset(offsets, 0);

        var live_count: u32 = 0;
        for (start_edge..@as(u32, @intCast(edge_count))) |eidx| {
            if (!self.edge_alive.isSet(eidx)) continue;
            const node_id = if (outgoing) self.edge_from.items[eidx] else self.edge_to.items[eidx];
            offsets[node_id + 1] += 1;
            live_count += 1;
        }

        if (live_count == 0) {
            self.allocator.free(offsets);
            return CSR.empty();
        }

        for (1..offsets.len) |i| {
            offsets[i] += offsets[i - 1];
        }

        const targets = try self.allocator.alloc(NodeId, live_count);
        errdefer self.allocator.free(targets);
        const edge_idx = try self.allocator.alloc(u32, live_count);
        errdefer self.allocator.free(edge_idx);

        const pos = try self.allocator.alloc(u32, node_capacity);
        defer self.allocator.free(pos);
        @memcpy(pos, offsets[0..node_capacity]);

        for (start_edge..@as(u32, @intCast(edge_count))) |eidx| {
            if (!self.edge_alive.isSet(eidx)) continue;
            const src = if (outgoing) self.edge_from.items[eidx] else self.edge_to.items[eidx];
            const dst = if (outgoing) self.edge_to.items[eidx] else self.edge_from.items[eidx];
            const p = pos[src];
            targets[p] = dst;
            edge_idx[p] = @intCast(eidx);
            pos[src] = p + 1;
        }

        return .{ .offsets = offsets, .targets = targets, .edge_idx = edge_idx };
    }

    /// Full compaction: rebuild base CSR from all live edges, clear delta.
    /// Sets all_base_edges_alive = true so traversals skip edge_alive checks.
    pub fn compact(self: *GraphEngine) !void {
        self.base_out.deinit(self.allocator);
        self.base_in.deinit(self.allocator);
        self.base_out = try self.buildCSR(0, true);
        self.base_in = try self.buildCSR(0, false);
        self.delta_edges.clearRetainingCapacity();
        self.all_base_edges_alive = true;
        self.needs_compact = false;
    }

    // ─── View Types ───────────────────────────────────────────────────

    pub const NodeView = struct {
        id: NodeId,
        key: []const u8,
        node_type: []const u8,
        prop_mask: u64,
    };

    pub const EdgeView = struct {
        id: EdgeId,
        from: NodeId,
        to: NodeId,
        edge_type: []const u8,
        weight: f64,
        prop_mask: u64,
    };
};

// ─── Tests ────────────────────────────────────────────────────────────

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
