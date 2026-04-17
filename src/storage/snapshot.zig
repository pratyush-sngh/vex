const std = @import("std");
const Allocator = std.mem.Allocator;
const KVStore = @import("../engine/kv.zig").KVStore;
const graph_mod = @import("../engine/graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const NodeId = graph_mod.NodeId;
const EdgeId = graph_mod.EdgeId;

const MAGIC = [_]u8{ 'Z', 'G', 'D', 'B' };
const FORMAT_VERSION: u8 = 1;

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

// ── Save ─────────────────────────────────────────────────────────────

/// Write a full binary snapshot of KVStore + GraphEngine to disk.
/// Format: Header | KV Section | Graph Section | CRC-32 footer.
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
    try appendU32(&buf, @intCast(kv.map.count()));
    {
        var it = kv.map.iterator();
        while (it.next()) |entry| {
            try appendBytes(&buf, entry.key_ptr.*);
            try appendBytes(&buf, entry.value_ptr.value);
            if (entry.value_ptr.expires_at) |exp| {
                try buf.append(1);
                try appendI64(&buf, exp);
            } else {
                try buf.append(0);
            }
        }
    }

    // Graph: Nodes (dense array, including soft-deleted)
    const node_count: u32 = @intCast(graph.nodes.items.len);
    try appendU32(&buf, node_count);
    for (graph.nodes.items) |node| {
        try buf.append(if (node.deleted) @as(u8, 1) else @as(u8, 0));
        try appendBytes(&buf, node.key);
        try appendBytes(&buf, node.node_type);
        try appendU32(&buf, @intCast(node.properties.count()));
        {
            var it = node.properties.iterator();
            while (it.next()) |prop| {
                try appendBytes(&buf, prop.key_ptr.*);
                try appendBytes(&buf, prop.value_ptr.*);
            }
        }
    }

    // Graph: Edges (dense array, including tombstoned)
    const edge_count: u32 = @intCast(graph.edges.items.len);
    try appendU32(&buf, edge_count);
    for (graph.edges.items) |edge| {
        try appendU32(&buf, edge.from);
        try appendU32(&buf, edge.to);
        try appendBytes(&buf, edge.edge_type);
        try appendF64(&buf, edge.weight);
        try appendU32(&buf, @intCast(edge.properties.count()));
        {
            var it = edge.properties.iterator();
            while (it.next()) |prop| {
                try appendBytes(&buf, prop.key_ptr.*);
                try appendBytes(&buf, prop.value_ptr.*);
            }
        }
    }

    // Graph: Adjacency lists
    try appendU32(&buf, node_count);
    for (graph.outgoing.items) |list| {
        try appendU32(&buf, @intCast(list.items.len));
        for (list.items) |eid| try appendU32(&buf, eid);
    }
    try appendU32(&buf, node_count);
    for (graph.incoming.items) |list| {
        try appendU32(&buf, @intCast(list.items.len));
        for (list.items) |eid| try appendU32(&buf, eid);
    }

    // CRC-32 footer
    try appendU32(&buf, computeCrc32(buf.items));

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
}

// ── Load ─────────────────────────────────────────────────────────────

/// Load a binary snapshot into KVStore + GraphEngine.
/// Returns cleanly if the file does not exist (fresh start).
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

    // Verify CRC (last 4 bytes are checksum of everything before them)
    const payload = raw[0 .. raw.len - 4];
    const stored_crc = std.mem.readInt(u32, raw[raw.len - 4 ..][0..4], .little);
    if (stored_crc != computeCrc32(payload)) return error.ChecksumMismatch;

    var r = BinReader{ .data = payload, .pos = 0 };

    // Header
    const magic = try r.readSlice(4);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.InvalidMagic;
    const version = try r.readByte();
    if (version != FORMAT_VERSION) return error.UnsupportedVersion;
    _ = try r.readI64(); // snapshot timestamp (informational)

    // KV section
    const kv_count = try r.readU32();
    for (0..kv_count) |_| {
        const key = try r.readLenPrefixed();
        const value = try r.readLenPrefixed();
        const has_exp = try r.readByte();
        const expires: ?i64 = if (has_exp == 1) try r.readI64() else null;
        try kv.restoreEntry(key, value, expires);
    }

    // Graph: Nodes
    const node_count = try r.readU32();
    for (0..node_count) |_| {
        const deleted = (try r.readByte()) == 1;
        const key_raw = try r.readLenPrefixed();
        const type_raw = try r.readLenPrefixed();

        const owned_key = try allocator.dupe(u8, key_raw);
        errdefer allocator.free(owned_key);
        const owned_type = try allocator.dupe(u8, type_raw);
        errdefer allocator.free(owned_type);

        var props = std.StringHashMap([]const u8).init(allocator);
        const pc = try r.readU32();
        for (0..pc) |_| {
            const pk = try r.readLenPrefixed();
            const pv = try r.readLenPrefixed();
            try props.put(try allocator.dupe(u8, pk), try allocator.dupe(u8, pv));
        }

        const id: NodeId = @intCast(graph.nodes.items.len);
        try graph.nodes.append(.{
            .key = owned_key,
            .node_type = owned_type,
            .properties = props,
            .deleted = deleted,
        });

        if (!deleted) try graph.key_to_id.put(owned_key, id);
        try graph.outgoing.append(std.array_list.Managed(EdgeId).init(allocator));
        try graph.incoming.append(std.array_list.Managed(EdgeId).init(allocator));
    }

    // Graph: Edges
    const edge_count = try r.readU32();
    for (0..edge_count) |_| {
        const from = try r.readU32();
        const to = try r.readU32();
        const et_raw = try r.readLenPrefixed();
        const weight = try r.readF64();

        const owned_et = try allocator.dupe(u8, et_raw);
        var props = std.StringHashMap([]const u8).init(allocator);
        const pc = try r.readU32();
        for (0..pc) |_| {
            const pk = try r.readLenPrefixed();
            const pv = try r.readLenPrefixed();
            try props.put(try allocator.dupe(u8, pk), try allocator.dupe(u8, pv));
        }

        try graph.edges.append(.{
            .from = from,
            .to = to,
            .edge_type = owned_et,
            .weight = weight,
            .properties = props,
        });
    }

    // Graph: Adjacency outgoing
    const out_n = try r.readU32();
    for (0..out_n) |i| {
        const len = try r.readU32();
        for (0..len) |_| {
            try graph.outgoing.items[i].append(try r.readU32());
        }
    }

    // Graph: Adjacency incoming
    const in_n = try r.readU32();
    for (0..in_n) |i| {
        const len = try r.readU32();
        for (0..len) |_| {
            try graph.incoming.items[i].append(try r.readU32());
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "snapshot round-trip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/zigraph_test.zdb";
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
    try std.testing.expectEqualStrings("3", na.properties.get("version").?);
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
    try load(io, allocator, &kv, &g, "/tmp/nonexistent_zigraph_test.zdb");
    try std.testing.expectEqual(@as(usize, 0), kv.dbsize());
}

test "snapshot corrupted CRC" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/zigraph_crc_test.zdb";
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
