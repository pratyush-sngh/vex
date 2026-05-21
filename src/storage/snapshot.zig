const std = @import("std");
const Allocator = std.mem.Allocator;
const KVStore = @import("../engine/kv.zig").KVStore;
const graph_mod = @import("../engine/graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const EdgeId = graph_mod.EdgeId;

const MAGIC = [_]u8{ 'Z', 'G', 'D', 'B' };
const FORMAT_VERSION: u8 = 2; // v2: SoA graph layout

// ── Binary write helpers ─────────────────────────────────────────────

fn appendU32(buf: *std.array_list.Managed(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try buf.appendSlice(&bytes);
}

fn appendI64(buf: *std.array_list.Managed(u8), value: i64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    try buf.appendSlice(&bytes);
}

fn appendF64(buf: *std.array_list.Managed(u8), value: f64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @as(u64, @bitCast(value)), .little);
    try buf.appendSlice(&bytes);
}

fn appendU16(buf: *std.array_list.Managed(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try buf.appendSlice(&bytes);
}

fn appendBytes(buf: *std.array_list.Managed(u8), data: []const u8) !void {
    try appendU32(buf, @intCast(data.len));
    try buf.appendSlice(data);
}

// ── Binary read helpers ──────────────────────────────────────────────

const BinReader = struct {
    data: []const u8,
    pos: usize,

    fn readByte(self: *BinReader) !u8 {
        if (self.pos >= self.data.len) return error.CorruptedData;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU16(self: *BinReader) !u16 {
        if (self.pos + 2 > self.data.len) return error.CorruptedData;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    fn readU32(self: *BinReader) !u32 {
        if (self.pos + 4 > self.data.len) return error.CorruptedData;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn readI64(self: *BinReader) !i64 {
        if (self.pos + 8 > self.data.len) return error.CorruptedData;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    fn readF64(self: *BinReader) !f64 {
        if (self.pos + 8 > self.data.len) return error.CorruptedData;
        const bits = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return @as(f64, @bitCast(bits));
    }

    fn readSlice(self: *BinReader, len: u32) ![]const u8 {
        const l: usize = len;
        if (self.pos + l > self.data.len) return error.CorruptedData;
        const s = self.data[self.pos .. self.pos + l];
        self.pos += l;
        return s;
    }

    fn readLenPrefixed(self: *BinReader) ![]const u8 {
        const len = try self.readU32();
        return self.readSlice(len);
    }
};

// ── CRC-32 (IEEE 802.3) ─────────────────────────────────────────────

fn computeCrc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= @as(u32, byte);
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xEDB88320 else crc >> 1;
        }
    }
    return crc ^ 0xFFFFFFFF;
}

fn readFileAll(file: std.Io.File, io: std.Io, allocator: Allocator, max_len: usize) ![]u8 {
    const len64 = try file.length(io);
    const len: usize = @intCast(len64);
    if (len > max_len) return error.StreamTooLong;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != len) return error.UnexpectedEof;
    return buf;
}

// ── Save (v2 format) ────────────────────────────────────────────────
//
// Format v2:
//   Header: MAGIC(4) + VERSION(1) + Timestamp(i64)
//   KV: count(u32) + [key(lenpfx) + value(lenpfx) + has_ttl(u8) + expires(i64)?]*
//   Interned types: count(u16) + [type_string(lenpfx)]*
//   Nodes: count(u32) + [alive(u8) + key(lenpfx) + type_id(u16) + prop_count(u32) + [key(lenpfx)+val(lenpfx)]*]*
//   Edges: count(u32) + [alive(u8) + from(u32) + to(u32) + type_id(u16) + weight(f64) + prop_count(u32) + [k+v]*]*
//   CRC-32(u32)

pub fn save(
    io: std.Io,
    allocator: Allocator,
    kv: *KVStore,
    graph: *GraphEngine,
    path: []const u8,
) !void {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    // Header
    try buf.appendSlice(&MAGIC);
    try buf.append(FORMAT_VERSION);
    try appendI64(&buf, std.Io.Timestamp.now(io, .real).toMilliseconds());

    // KV section
    try appendU32(&buf, kv.live_count);
    {
        var it = kv.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
            try appendBytes(&buf, entry.key_ptr.*);
            try appendBytes(&buf, entry.value_ptr.value);
            if (entry.value_ptr.flags.has_ttl) {
                try buf.append(1);
                try appendI64(&buf, entry.value_ptr.expires_at);
            } else {
                try buf.append(0);
            }
        }
    }

    // Interned types
    const type_count = graph.type_intern.count();
    try appendU16(&buf, type_count);
    for (0..type_count) |i| {
        try appendBytes(&buf, graph.type_intern.resolve(@intCast(i)));
    }

    // Nodes (SoA serialized per-node)
    const node_count: u32 = @intCast(graph.node_keys.items.len);
    try appendU32(&buf, node_count);
    for (0..node_count) |i| {
        const alive = graph.node_alive.isSet(i);
        try buf.append(if (alive) @as(u8, 1) else @as(u8, 0));
        try appendBytes(&buf, graph.node_keys.items[i]);
        try appendU16(&buf, graph.node_type_id.items[i]);

        // Properties from shared PropertyStore
        const prop_count = graph.node_props.countProps(@intCast(i));
        try appendU32(&buf, prop_count);
        if (prop_count > 0) {
            const pairs = try graph.node_props.collectAll(@intCast(i), allocator);
            defer allocator.free(pairs);
            for (pairs) |pair| {
                try appendBytes(&buf, pair.key);
                try appendBytes(&buf, pair.value);
            }
        }
    }

    // Edges (SoA serialized per-edge)
    const edge_count: u32 = @intCast(graph.edge_from.items.len);
    try appendU32(&buf, edge_count);
    for (0..edge_count) |i| {
        const alive = graph.edge_alive.isSet(i);
        try buf.append(if (alive) @as(u8, 1) else @as(u8, 0));
        try appendU32(&buf, graph.edge_from.items[i]);
        try appendU32(&buf, graph.edge_to.items[i]);
        try appendU16(&buf, graph.edge_type_id.items[i]);
        try appendF64(&buf, graph.edge_weight.items[i]);

        const prop_count = graph.edge_props.countProps(@intCast(i));
        try appendU32(&buf, prop_count);
        if (prop_count > 0) {
            const pairs = try graph.edge_props.collectAll(@intCast(i), allocator);
            defer allocator.free(pairs);
            for (pairs) |pair| {
                try appendBytes(&buf, pair.key);
                try appendBytes(&buf, pair.value);
            }
        }
    }

    // CRC-32 footer
    try appendU32(&buf, computeCrc32(buf.items));

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
}

// ── Load (v2 format) ────────────────────────────────────────────────

pub fn load(
    io: std.Io,
    allocator: Allocator,
    kv: *KVStore,
    graph: *GraphEngine,
    path: []const u8,
) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close(io);

    const raw = try readFileAll(file, io, allocator, 1 << 30);
    defer allocator.free(raw);

    if (raw.len < 4 + 1 + 8 + 4) return error.CorruptedData;

    const payload = raw[0 .. raw.len - 4];
    const stored_crc = std.mem.readInt(u32, raw[raw.len - 4 ..][0..4], .little);
    if (stored_crc != computeCrc32(payload)) return error.ChecksumMismatch;

    var r = BinReader{ .data = payload, .pos = 0 };

    // Header
    const magic = try r.readSlice(4);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.InvalidMagic;
    const version = try r.readByte();
    if (version != FORMAT_VERSION) return error.UnsupportedVersion;
    _ = try r.readI64(); // timestamp

    // KV section
    const kv_count = try r.readU32();
    for (0..kv_count) |_| {
        const key = try r.readLenPrefixed();
        const value = try r.readLenPrefixed();
        const has_exp = try r.readByte();
        const expires: ?i64 = if (has_exp == 1) try r.readI64() else null;
        try kv.restoreEntry(key, value, expires);
    }

    // Interned types — restore in order so IDs match
    const type_count = try r.readU16();
    for (0..type_count) |_| {
        const type_str = try r.readLenPrefixed();
        _ = try graph.type_intern.intern(type_str);
    }

    // Nodes
    const node_count = try r.readU32();
    graph.bulk_loading = true;
    for (0..node_count) |_| {
        const alive = (try r.readByte()) == 1;
        const key_raw = try r.readLenPrefixed();
        const type_id = try r.readU16();

        const owned_key = try allocator.dupe(u8, key_raw);
        errdefer allocator.free(owned_key);

        // Append to SoA arrays directly
        const id: NodeId = @intCast(graph.node_keys.items.len);
        try graph.node_keys.append(owned_key);
        try graph.node_type_id.append(type_id);
        try graph.node_prop_mask.append(0);
        try graph.node_out_type_mask.append(0);
        try graph.node_in_type_mask.append(0);
        try graph.node_alive.resize(id + 1, true);
        if (alive) {
            graph.node_alive.set(id);
            try graph.key_to_id.put(owned_key, id);
        } else {
            graph.node_alive.unset(id);
        }

        // Properties
        const pc = try r.readU32();
        for (0..pc) |_| {
            const pk = try r.readLenPrefixed();
            const pv = try r.readLenPrefixed();
            try graph.node_props.set(id, pk, pv);
            // Rebuild prop_mask (setNodeProperty bypassed during bulk load)
            if (graph.node_props.key_intern.find(pk)) |kid| {
                if (kid < 64) {
                    graph.node_prop_mask.items[id] |= @as(u64, 1) << @intCast(kid);
                }
            }
        }
        if (pc > 0) graph.flags.has_node_props = true;
    }

    // Edges
    const edge_count = try r.readU32();
    for (0..edge_count) |_| {
        const alive = (try r.readByte()) == 1;
        const from = try r.readU32();
        const to = try r.readU32();
        const type_id = try r.readU16();
        const weight = try r.readF64();

        const eid: EdgeId = @intCast(graph.edge_from.items.len);
        try graph.edge_from.append(from);
        try graph.edge_to.append(to);
        try graph.edge_type_id.append(type_id);
        try graph.edge_weight.append(weight);
        try graph.edge_prop_mask.append(0);
        try graph.edge_alive.resize(eid + 1, true);
        if (alive) {
            graph.edge_alive.set(eid);
            // Update type masks
            if (type_id < 64 and from < graph.node_out_type_mask.items.len) {
                const bit = @import("../engine/string_intern.zig").StringIntern.mask(type_id);
                graph.node_out_type_mask.items[from] |= bit;
                if (to < graph.node_in_type_mask.items.len) {
                    graph.node_in_type_mask.items[to] |= bit;
                }
            }
        } else {
            graph.edge_alive.unset(eid);
        }

        if (weight != 1.0) graph.flags.uniform_weights = false;

        const pc = try r.readU32();
        for (0..pc) |_| {
            const pk = try r.readLenPrefixed();
            const pv = try r.readLenPrefixed();
            try graph.edge_props.set(eid, pk, pv);
            // Rebuild prop_mask (setEdgeProperty bypassed during bulk load)
            if (graph.edge_props.key_intern.find(pk)) |kid| {
                if (kid < 64) {
                    graph.edge_prop_mask.items[eid] |= @as(u64, 1) << @intCast(kid);
                }
            }
        }
        if (pc > 0) graph.flags.has_edge_props = true;
    }

    graph.bulk_loading = false;
    if (graph.type_intern.count() > 1) graph.flags.is_untyped = false;

    // Build CSR from loaded data
    try graph.compact();
}

// ── Tests ────────────────────────────────────────────────────────────

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

    try save(io, allocator, &kv, &g, path);

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

    try save(io, allocator, &kv, &g, path);

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

    try save(io, allocator, &kv, &g, path);

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
