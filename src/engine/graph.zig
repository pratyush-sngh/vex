const std = @import("std");
const Allocator = std.mem.Allocator;

/// Dense internal identifier for nodes (allows O(1) indexed lookup).
pub const NodeId = u32;
/// Dense internal identifier for edges.
pub const EdgeId = u32;

pub const INVALID_ID: u32 = std.math.maxInt(u32);

pub const Node = struct {
    key: []const u8,
    node_type: []const u8,
    properties: std.StringHashMap([]const u8),
    deleted: bool,

    pub fn deinit(self: *Node, allocator: Allocator) void {
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.properties.deinit();
        allocator.free(self.key);
        allocator.free(self.node_type);
    }
};

pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    edge_type: []const u8,
    weight: f64,
    properties: std.StringHashMap([]const u8),

    pub fn isDeleted(self: *const Edge) bool {
        return self.from == INVALID_ID;
    }

    pub fn deinit(self: *Edge, allocator: Allocator) void {
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.properties.deinit();
        allocator.free(self.edge_type);
    }
};

/// In-memory graph engine with adjacency list representation.
///
/// Design mirrors ReviewGraph's Engine: dense internal IDs, parallel arrays,
/// forward + reverse adjacency lists for efficient traversal.
///
/// Single-threaded by design (Redis model) -- the event loop serializes
/// all mutations, so no locks are needed.
pub const GraphEngine = struct {
    allocator: Allocator,
    nodes: std.array_list.Managed(Node),
    edges: std.array_list.Managed(Edge),
    key_to_id: std.StringHashMap(NodeId),
    outgoing: std.array_list.Managed(std.array_list.Managed(EdgeId)),
    incoming: std.array_list.Managed(std.array_list.Managed(EdgeId)),

    pub fn init(allocator: Allocator) GraphEngine {
        return .{
            .allocator = allocator,
            .nodes = std.array_list.Managed(Node).init(allocator),
            .edges = std.array_list.Managed(Edge).init(allocator),
            .key_to_id = std.StringHashMap(NodeId).init(allocator),
            .outgoing = std.array_list.Managed(std.array_list.Managed(EdgeId)).init(allocator),
            .incoming = std.array_list.Managed(std.array_list.Managed(EdgeId)).init(allocator),
        };
    }

    pub fn deinit(self: *GraphEngine) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit();

        for (self.edges.items) |*edge| edge.deinit(self.allocator);
        self.edges.deinit();

        self.key_to_id.deinit();

        for (self.outgoing.items) |*list| list.deinit();
        self.outgoing.deinit();
        for (self.incoming.items) |*list| list.deinit();
        self.incoming.deinit();
    }

    // ─── Node Operations ──────────────────────────────────────────────

    pub fn addNode(self: *GraphEngine, key: []const u8, node_type: []const u8) !NodeId {
        if (self.key_to_id.get(key) != null) return error.DuplicateNode;

        const id: NodeId = @intCast(self.nodes.items.len);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_type = try self.allocator.dupe(u8, node_type);
        errdefer self.allocator.free(owned_type);

        try self.nodes.append(.{
            .key = owned_key,
            .node_type = owned_type,
            .properties = std.StringHashMap([]const u8).init(self.allocator),
            .deleted = false,
        });
        errdefer {
            if (self.nodes.pop()) |n| {
                var node = n;
                node.deinit(self.allocator);
            }
        }

        try self.key_to_id.put(owned_key, id);
        try self.outgoing.append(std.array_list.Managed(EdgeId).init(self.allocator));
        try self.incoming.append(std.array_list.Managed(EdgeId).init(self.allocator));

        return id;
    }

    pub fn getNode(self: *GraphEngine, key: []const u8) ?*const Node {
        const id = self.key_to_id.get(key) orelse return null;
        const node = &self.nodes.items[id];
        if (node.deleted) return null;
        return node;
    }

    pub fn getNodeById(self: *GraphEngine, id: NodeId) ?*const Node {
        if (id >= self.nodes.items.len) return null;
        const node = &self.nodes.items[id];
        if (node.deleted) return null;
        return node;
    }

    pub fn resolveKey(self: *GraphEngine, key: []const u8) ?NodeId {
        return self.key_to_id.get(key);
    }

    pub fn setNodeProperty(self: *GraphEngine, key: []const u8, prop_key: []const u8, prop_val: []const u8) !void {
        const id = self.key_to_id.get(key) orelse return error.NodeNotFound;
        var node = &self.nodes.items[id];
        if (node.deleted) return error.NodeNotFound;

        const owned_pv = try self.allocator.dupe(u8, prop_val);
        errdefer self.allocator.free(owned_pv);

        const existing = node.properties.getPtr(prop_key);
        if (existing) |old_val| {
            self.allocator.free(old_val.*);
            old_val.* = owned_pv;
        } else {
            const owned_pk = try self.allocator.dupe(u8, prop_key);
            errdefer self.allocator.free(owned_pk);
            try node.properties.put(owned_pk, owned_pv);
        }
    }

    pub fn removeNode(self: *GraphEngine, key: []const u8) !void {
        const id = self.key_to_id.get(key) orelse return error.NodeNotFound;

        // Collect edges to remove (both directions)
        var edges_to_remove = std.array_list.Managed(EdgeId).init(self.allocator);
        defer edges_to_remove.deinit();

        for (self.outgoing.items[id].items) |eid| try edges_to_remove.append(eid);
        for (self.incoming.items[id].items) |eid| try edges_to_remove.append(eid);

        for (edges_to_remove.items) |eid| {
            var edge = &self.edges.items[eid];
            if (!edge.isDeleted()) {
                if (edge.from != id) removeFromList(&self.outgoing.items[edge.from], eid);
                if (edge.to != id) removeFromList(&self.incoming.items[edge.to], eid);
                edge.from = INVALID_ID;
                edge.to = INVALID_ID;
            }
        }

        self.outgoing.items[id].clearAndFree();
        self.incoming.items[id].clearAndFree();

        _ = self.key_to_id.remove(key);
        self.nodes.items[id].deleted = true;
    }

    // ─── Edge Operations ──────────────────────────────────────────────

    pub fn addEdge(self: *GraphEngine, from_key: []const u8, to_key: []const u8, edge_type: []const u8, weight: f64) !EdgeId {
        const from_id = self.key_to_id.get(from_key) orelse return error.NodeNotFound;
        const to_id = self.key_to_id.get(to_key) orelse return error.NodeNotFound;

        const eid: EdgeId = @intCast(self.edges.items.len);
        const owned_type = try self.allocator.dupe(u8, edge_type);
        errdefer self.allocator.free(owned_type);

        try self.edges.append(.{
            .from = from_id,
            .to = to_id,
            .edge_type = owned_type,
            .weight = weight,
            .properties = std.StringHashMap([]const u8).init(self.allocator),
        });

        try self.outgoing.items[from_id].append(eid);
        try self.incoming.items[to_id].append(eid);

        return eid;
    }

    pub fn getEdge(self: *GraphEngine, eid: EdgeId) ?*const Edge {
        if (eid >= self.edges.items.len) return null;
        const edge = &self.edges.items[eid];
        if (edge.isDeleted()) return null;
        return edge;
    }

    pub fn removeEdge(self: *GraphEngine, eid: EdgeId) !void {
        if (eid >= self.edges.items.len) return error.EdgeNotFound;
        var edge = &self.edges.items[eid];
        if (edge.isDeleted()) return error.EdgeNotFound;

        removeFromList(&self.outgoing.items[edge.from], eid);
        removeFromList(&self.incoming.items[edge.to], eid);
        edge.from = INVALID_ID;
        edge.to = INVALID_ID;
    }

    pub fn setEdgeProperty(self: *GraphEngine, eid: EdgeId, prop_key: []const u8, prop_val: []const u8) !void {
        if (eid >= self.edges.items.len) return error.EdgeNotFound;
        var edge = &self.edges.items[eid];
        if (edge.isDeleted()) return error.EdgeNotFound;

        const owned_pv = try self.allocator.dupe(u8, prop_val);
        errdefer self.allocator.free(owned_pv);

        const existing = edge.properties.getPtr(prop_key);
        if (existing) |old_val| {
            self.allocator.free(old_val.*);
            old_val.* = owned_pv;
        } else {
            const owned_pk = try self.allocator.dupe(u8, prop_key);
            errdefer self.allocator.free(owned_pk);
            try edge.properties.put(owned_pk, owned_pv);
        }
    }

    // ─── Query Primitives ─────────────────────────────────────────────

    pub fn outgoingEdges(self: *GraphEngine, key: []const u8) ?[]const EdgeId {
        const id = self.key_to_id.get(key) orelse return null;
        return self.outgoing.items[id].items;
    }

    pub fn incomingEdges(self: *GraphEngine, key: []const u8) ?[]const EdgeId {
        const id = self.key_to_id.get(key) orelse return null;
        return self.incoming.items[id].items;
    }

    pub fn outgoingEdgesById(self: *GraphEngine, id: NodeId) []const EdgeId {
        if (id >= self.outgoing.items.len) return &.{};
        return self.outgoing.items[id].items;
    }

    pub fn incomingEdgesById(self: *GraphEngine, id: NodeId) []const EdgeId {
        if (id >= self.incoming.items.len) return &.{};
        return self.incoming.items[id].items;
    }

    pub fn nodeCount(self: *GraphEngine) usize {
        return self.key_to_id.count();
    }

    pub fn edgeCount(self: *GraphEngine) usize {
        var count: usize = 0;
        for (self.edges.items) |e| {
            if (!e.isDeleted()) count += 1;
        }
        return count;
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    fn removeFromList(list: *std.array_list.Managed(EdgeId), value: EdgeId) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i] == value) {
                _ = list.swapRemove(i);
                return;
            }
            i += 1;
        }
    }
};

// ─── Tests ────────────────────────────────────────────────────────────

test "graph add nodes and edges" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("service:auth", "service");
    _ = try g.addNode("service:user", "service");

    _ = try g.addEdge("service:auth", "service:user", "calls", 1.0);

    try std.testing.expectEqual(@as(usize, 2), g.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), g.edgeCount());

    const out = g.outgoingEdges("service:auth").?;
    try std.testing.expectEqual(@as(usize, 1), out.len);

    const inc = g.incomingEdges("service:user").?;
    try std.testing.expectEqual(@as(usize, 1), inc.len);
}

test "graph duplicate node" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("x", "type");
    const result = g.addNode("x", "type");
    try std.testing.expect(result == error.DuplicateNode);
}

test "graph node properties" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("n1", "service");
    try g.setNodeProperty("n1", "version", "2.1");

    const node = g.getNode("n1").?;
    try std.testing.expectEqualStrings("2.1", node.properties.get("version").?);
}

test "graph remove node" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    _ = try g.addEdge("a", "b", "link", 1.0);

    try g.removeNode("a");
    try std.testing.expectEqual(@as(usize, 1), g.nodeCount());
    try std.testing.expectEqual(@as(usize, 0), g.edgeCount());
    try std.testing.expect(g.getNode("a") == null);
}

test "graph remove edge" {
    var g = GraphEngine.init(std.testing.allocator);
    defer g.deinit();

    _ = try g.addNode("a", "t");
    _ = try g.addNode("b", "t");
    const eid = try g.addEdge("a", "b", "link", 1.0);

    try g.removeEdge(eid);
    try std.testing.expectEqual(@as(usize, 0), g.edgeCount());
    try std.testing.expect(g.getEdge(eid) == null);
}
