const std = @import("std");
const Allocator = std.mem.Allocator;
const resp = @import("../server/resp.zig");
const KVStore = @import("../engine/kv.zig").KVStore;
const graph_mod = @import("../engine/graph.zig");
const GraphEngine = graph_mod.GraphEngine;
const query = @import("../engine/query.zig");
const snapshot = @import("../storage/snapshot.zig");
const aof_mod = @import("../storage/aof.zig");
const AOF = aof_mod.AOF;
const MAX_DATABASES: u8 = 16;
const KEYS_MAX_REPLY: usize = 1000;
const SCAN_DEFAULT_COUNT: usize = 10;

pub const KeysMode = enum {
    strict,
    autoscan,
};

/// Central command dispatcher. Parses a RESP array (the Redis command)
/// and routes to the appropriate KV or graph handler.
pub const CommandHandler = struct {
    kv: *KVStore,
    graph: *GraphEngine,
    allocator: Allocator,
    io: std.Io,
    aof: ?*AOF,
    selected_db: *std.atomic.Value(u8),
    keys_mode: KeysMode,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        kv: *KVStore,
        g: *GraphEngine,
        aof: ?*AOF,
        selected_db: *std.atomic.Value(u8),
        keys_mode: KeysMode,
    ) CommandHandler {
        return .{
            .kv = kv,
            .graph = g,
            .allocator = allocator,
            .io = io,
            .aof = aof,
            .selected_db = selected_db,
            .keys_mode = keys_mode,
        };
    }

    /// Execute a command from a parsed RESP array and write the response.
    pub fn execute(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (args.len == 0) {
            try resp.serializeError(w, "empty command");
            return;
        }

        var cmd_buf: [64]u8 = undefined;
        const cmd = toUpper(args[0], &cmd_buf);

        // ── Standard Redis KV commands ────────────────────────────────
        if (std.mem.eql(u8, cmd, "PING")) return self.cmdPing(args, w);
        if (std.mem.eql(u8, cmd, "SET")) return self.cmdSet(args, w);
        if (std.mem.eql(u8, cmd, "GET")) return self.cmdGet(args, w);
        if (std.mem.eql(u8, cmd, "DEL")) return self.cmdDel(args, w);
        if (std.mem.eql(u8, cmd, "EXISTS")) return self.cmdExists(args, w);
        if (std.mem.eql(u8, cmd, "KEYS")) return self.cmdKeys(args, w);
        if (std.mem.eql(u8, cmd, "SCAN")) return self.cmdScan(args, w);
        if (std.mem.eql(u8, cmd, "DBSIZE")) return self.cmdDbsize(w);
        if (std.mem.eql(u8, cmd, "FLUSHDB")) return self.cmdFlushdb(args, w);
        if (std.mem.eql(u8, cmd, "FLUSHALL")) return self.cmdFlushall(args, w);
        if (std.mem.eql(u8, cmd, "MOVE")) return self.cmdMove(args, w);
        if (std.mem.eql(u8, cmd, "SELECT")) return self.cmdSelect(args, w);
        if (std.mem.eql(u8, cmd, "TTL")) return self.cmdTtl(args, w);
        if (std.mem.eql(u8, cmd, "INFO")) return self.cmdInfo(w);
        if (std.mem.eql(u8, cmd, "COMMAND")) return self.cmdCommand(w);
        if (std.mem.eql(u8, cmd, "SAVE")) return self.cmdSave(w);
        if (std.mem.eql(u8, cmd, "LASTSAVE")) return self.cmdLastSave(w);

        // ── Graph commands (GRAPH.*) ──────────────────────────────────
        if (std.mem.eql(u8, cmd, "GRAPH.ADDNODE")) return self.cmdGraphAddNode(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.GETNODE")) return self.cmdGraphGetNode(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.DELNODE")) return self.cmdGraphDelNode(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.SETPROP")) return self.cmdGraphSetProp(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.ADDEDGE")) return self.cmdGraphAddEdge(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.DELEDGE")) return self.cmdGraphDelEdge(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.NEIGHBORS")) return self.cmdGraphNeighbors(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.TRAVERSE")) return self.cmdGraphTraverse(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.PATH")) return self.cmdGraphPath(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.WPATH")) return self.cmdGraphWPath(args, w);
        if (std.mem.eql(u8, cmd, "GRAPH.STATS")) return self.cmdGraphStats(w);

        try resp.serializeErrorTyped(w, "ERR", "unknown command");
    }

    // ── KV Commands ───────────────────────────────────────────────────

    fn cmdPing(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        _ = self;
        if (args.len > 1) {
            try resp.serializeBulkString(w, args[1]);
        } else {
            try resp.serializeSimpleString(w, "PONG");
        }
    }

    fn cmdSet(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'SET'");
            return;
        }

        // Parse optional EX/PX flags
        if (args.len >= 5) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[3], &flag_buf);
            const ttl = std.fmt.parseInt(i64, args[4], 10) catch {
                try resp.serializeError(w, "value is not an integer");
                return;
            };
            if (std.mem.eql(u8, flag, "EX")) {
                var key_buf: [512]u8 = undefined;
                var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                defer key_ref.deinit(self.allocator);
                self.kv.setEx(key_ref.key, args[2], ttl) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                self.logToAOF(args);
                try resp.serializeSimpleString(w, "OK");
                return;
            } else if (std.mem.eql(u8, flag, "PX")) {
                var key_buf: [512]u8 = undefined;
                var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                defer key_ref.deinit(self.allocator);
                self.kv.setPx(key_ref.key, args[2], ttl) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                self.logToAOF(args);
                try resp.serializeSimpleString(w, "OK");
                return;
            }
        }

        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);
        self.kv.set(key_ref.key, args[2]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdGet(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'GET'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);
        const val = self.kv.get(key_ref.key);
        try resp.serializeBulkString(w, val);
    }

    fn cmdDel(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'DEL'");
            return;
        }
        var count: i64 = 0;
        for (args[1..]) |key| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRef(self, key, &key_buf) catch continue;
            if (self.kv.delete(key_ref.key)) count += 1;
            key_ref.deinit(self.allocator);
        }
        if (count > 0) self.logToAOF(args);
        try resp.serializeInteger(w, count);
    }

    fn cmdExists(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'EXISTS'");
            return;
        }
        var count: i64 = 0;
        for (args[1..]) |key| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRef(self, key, &key_buf) catch continue;
            if (self.kv.exists(key_ref.key)) count += 1;
            key_ref.deinit(self.allocator);
        }
        try resp.serializeInteger(w, count);
    }

    fn cmdKeys(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const pattern = if (args.len > 1) args[1] else "*";
        var db_key_count: usize = 0;
        var counter = self.kv.map.iterator();
        while (counter.next()) |entry| {
            if (stripDbPrefix(self, entry.key_ptr.*) != null) db_key_count += 1;
        }
        if (self.keys_mode == .strict and db_key_count > KEYS_MAX_REPLY) {
            try resp.serializeError(w, "ERR KEYS disabled for large DB, use SCAN");
            return;
        }
        var matched = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (matched.items) |k| self.allocator.free(k);
            matched.deinit();
        }

        var it = self.kv.map.iterator();
        while (it.next()) |entry| {
            const raw = entry.key_ptr.*;
            const user_key = stripDbPrefix(self, raw) orelse continue;
            if (globMatch(pattern, user_key)) {
                const dup = self.allocator.dupe(u8, user_key) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                matched.append(dup) catch {
                    self.allocator.free(dup);
                    try resp.serializeError(w, "internal error");
                    return;
                };
            }
        }

        try resp.serializeArrayHeader(w, matched.items.len);
        for (matched.items) |key| {
            try resp.serializeBulkString(w, key);
        }
    }

    fn cmdScan(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'SCAN'");
            return;
        }
        var cursor = std.fmt.parseInt(usize, args[1], 10) catch {
            try resp.serializeError(w, "invalid cursor");
            return;
        };
        var pattern: []const u8 = "*";
        var count: usize = SCAN_DEFAULT_COUNT;
        var i: usize = 2;
        while (i < args.len) {
            var flag_buf: [16]u8 = undefined;
            const flag = toUpperBuf(args[i], &flag_buf);
            if (std.mem.eql(u8, flag, "MATCH") and i + 1 < args.len) {
                pattern = args[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, flag, "COUNT") and i + 1 < args.len) {
                count = std.fmt.parseInt(usize, args[i + 1], 10) catch SCAN_DEFAULT_COUNT;
                if (count == 0) count = SCAN_DEFAULT_COUNT;
                i += 2;
            } else {
                i += 1;
            }
        }

        var all = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (all.items) |k| self.allocator.free(k);
            all.deinit();
        }
        var it = self.kv.map.iterator();
        while (it.next()) |entry| {
            const user_key = stripDbPrefix(self, entry.key_ptr.*) orelse continue;
            if (globMatch(pattern, user_key)) {
                const dup = self.allocator.dupe(u8, user_key) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                all.append(dup) catch {
                    self.allocator.free(dup);
                    try resp.serializeError(w, "internal error");
                    return;
                };
            }
        }

        if (cursor > all.items.len) cursor = all.items.len;
        const end = @min(all.items.len, cursor + count);
        const next_cursor: usize = if (end >= all.items.len) 0 else end;

        try resp.serializeArrayHeader(w, 2);
        var cursor_buf: [32]u8 = undefined;
        const cur = std.fmt.bufPrint(&cursor_buf, "{d}", .{next_cursor}) catch "0";
        try resp.serializeBulkString(w, cur);
        try resp.serializeArrayHeader(w, end - cursor);
        var idx = cursor;
        while (idx < end) : (idx += 1) {
            try resp.serializeBulkString(w, all.items[idx]);
        }
    }

    fn cmdDbsize(self: *CommandHandler, w: *std.Io.Writer) !void {
        var count: i64 = 0;
        var it = self.kv.map.iterator();
        while (it.next()) |entry| {
            if (stripDbPrefix(self, entry.key_ptr.*) != null) count += 1;
        }
        try resp.serializeInteger(w, count);
    }

    fn cmdFlushdb(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var to_delete = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (to_delete.items) |k| self.allocator.free(k);
            to_delete.deinit();
        }

        var it = self.kv.map.iterator();
        while (it.next()) |entry| {
            const raw = entry.key_ptr.*;
            if (stripDbPrefix(self, raw) != null) {
                const dup = self.allocator.dupe(u8, raw) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                to_delete.append(dup) catch {
                    self.allocator.free(dup);
                    try resp.serializeError(w, "internal error");
                    return;
                };
            }
        }
        for (to_delete.items) |k| {
            _ = self.kv.delete(k);
        }
        var graph_to_delete = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (graph_to_delete.items) |k| self.allocator.free(k);
            graph_to_delete.deinit();
        }
        for (self.graph.nodes.items) |node| {
            if (node.deleted) continue;
            if (stripGraphDbPrefix(self, node.key) != null) {
                const dup = self.allocator.dupe(u8, node.key) catch {
                    try resp.serializeError(w, "internal error");
                    return;
                };
                graph_to_delete.append(dup) catch {
                    self.allocator.free(dup);
                    try resp.serializeError(w, "internal error");
                    return;
                };
            }
        }
        for (graph_to_delete.items) |k| {
            _ = self.graph.removeNode(k) catch {};
        }
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdFlushall(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        self.kv.flushdb();
        self.graph.deinit();
        self.graph.* = GraphEngine.init(self.allocator);
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdMove(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len != 3) {
            try resp.serializeError(w, "wrong number of arguments for 'MOVE'");
            return;
        }
        const dst_db = std.fmt.parseInt(u8, args[2], 10) catch {
            try resp.serializeError(w, "DB index is out of range");
            return;
        };
        if (dst_db >= MAX_DATABASES) {
            try resp.serializeError(w, "DB index is out of range");
            return;
        }
        if (dst_db == self.selected_db.load(.monotonic)) {
            try resp.serializeError(w, "ERR source and destination objects are the same");
            return;
        }

        const src = namespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(src);

        const dst = namespacedKeyForDb(self, dst_db, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(dst);

        const src_entry = self.kv.map.getPtr(src) orelse {
            try resp.serializeInteger(w, 0);
            return;
        };
        if (self.kv.map.getPtr(dst) != null) {
            try resp.serializeInteger(w, 0);
            return;
        }

        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        if (src_entry.expires_at) |exp| {
            const remaining = exp - now;
            if (remaining <= 0) {
                _ = self.kv.delete(src);
                try resp.serializeInteger(w, 0);
                return;
            }
            self.kv.setPx(dst, src_entry.value, remaining) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        } else {
            self.kv.set(dst, src_entry.value) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        }
        _ = self.kv.delete(src);
        self.logToAOF(args);
        try resp.serializeInteger(w, 1);
    }

    fn cmdSelect(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len != 2) {
            try resp.serializeError(w, "wrong number of arguments for 'SELECT'");
            return;
        }
        const db_index = std.fmt.parseInt(u8, args[1], 10) catch {
            try resp.serializeError(w, "DB index is out of range");
            return;
        };
        if (db_index >= MAX_DATABASES) {
            try resp.serializeError(w, "DB index is out of range");
            return;
        }
        self.selected_db.store(db_index, .monotonic);
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdTtl(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'TTL'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);
        const result = self.kv.ttl(key_ref.key);
        if (result) |t| {
            try resp.serializeInteger(w, t);
        } else {
            try resp.serializeInteger(w, -2); // key doesn't exist
        }
    }

    fn cmdInfo(self: *CommandHandler, out: *std.Io.Writer) std.Io.Writer.Error!void {
        var kv_keys: usize = 0;
        var it = self.kv.map.iterator();
        while (it.next()) |entry| {
            if (stripDbPrefix(self, entry.key_ptr.*) != null) kv_keys += 1;
        }
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll("# Zigraph\r\n");
        try aw.writer.writeAll("zigraph_version:0.1.0\r\n");
        try aw.writer.print("kv_keys:{d}\r\n", .{kv_keys});
        try aw.writer.print("db_selected:{d}\r\n", .{self.selected_db.load(.monotonic)});
        try aw.writer.print("db_max:{d}\r\n", .{MAX_DATABASES});
        try aw.writer.print("graph_nodes:{d}\r\n", .{self.graph.nodeCount()});
        try aw.writer.print("graph_edges:{d}\r\n", .{self.graph.edgeCount()});
        try resp.serializeBulkString(out, aw.written());
    }

    fn cmdCommand(_: *CommandHandler, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try resp.serializeSimpleString(w, "OK");
    }

    // ── Graph Commands ────────────────────────────────────────────────

    /// GRAPH.ADDNODE <key> <type>
    fn cmdGraphAddNode(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "usage: GRAPH.ADDNODE <key> <type>");
            return;
        }
        const nk = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(nk);
        const id = self.graph.addNode(nk, args[2]) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(id));
    }

    /// GRAPH.GETNODE <key>
    fn cmdGraphGetNode(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "usage: GRAPH.GETNODE <key>");
            return;
        }
        const nk = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(nk);
        const node = self.graph.getNode(nk) orelse {
            try resp.serializeBulkString(w, null);
            return;
        };

        // Return as array: [key, type, prop_count, k1, v1, k2, v2, ...]
        const prop_count = node.properties.count();
        const total: usize = 3 + prop_count * 2;
        try resp.serializeArrayHeader(w, total);
        const user_key = stripGraphDbPrefix(self, node.key) orelse node.key;
        try resp.serializeBulkString(w, user_key);
        try resp.serializeBulkString(w, node.node_type);
        try resp.serializeInteger(w, @intCast(prop_count));
        var iter = node.properties.iterator();
        while (iter.next()) |entry| {
            try resp.serializeBulkString(w, entry.key_ptr.*);
            try resp.serializeBulkString(w, entry.value_ptr.*);
        }
    }

    /// GRAPH.DELNODE <key>
    fn cmdGraphDelNode(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "usage: GRAPH.DELNODE <key>");
            return;
        }
        const nk = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(nk);
        self.graph.removeNode(nk) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.SETPROP <node_key> <prop_key> <prop_value>
    fn cmdGraphSetProp(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) {
            try resp.serializeError(w, "usage: GRAPH.SETPROP <key> <prop> <value>");
            return;
        }
        const nk = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(nk);
        self.graph.setNodeProperty(nk, args[2], args[3]) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.ADDEDGE <from_key> <to_key> <type> [weight]
    fn cmdGraphAddEdge(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) {
            try resp.serializeError(w, "usage: GRAPH.ADDEDGE <from> <to> <type> [weight]");
            return;
        }
        const weight: f64 = if (args.len > 4)
            std.fmt.parseFloat(f64, args[4]) catch 1.0
        else
            1.0;

        const from = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(from);
        const to = graphNamespacedKey(self, args[2]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(to);
        const eid = self.graph.addEdge(from, to, args[3], weight) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(eid));
    }

    /// GRAPH.DELEDGE <edge_id>
    fn cmdGraphDelEdge(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "usage: GRAPH.DELEDGE <edge_id>");
            return;
        }
        const eid = std.fmt.parseInt(u32, args[1], 10) catch {
            try resp.serializeError(w, "invalid edge id");
            return;
        };
        self.graph.removeEdge(eid) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.NEIGHBORS <key> [OUT|IN|BOTH]
    fn cmdGraphNeighbors(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "usage: GRAPH.NEIGHBORS <key> [OUT|IN|BOTH]");
            return;
        }
        const direction = parseDirection(args);

        const nk = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(nk);
        const ids = query.neighbors(self.graph, self.allocator, nk, direction) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        defer self.allocator.free(ids);

        try resp.serializeArrayHeader(w, ids.len);
        for (ids) |nid| {
            const node = self.graph.getNodeById(nid);
            if (node) |n| {
                const user_key = stripGraphDbPrefix(self, n.key) orelse n.key;
                try resp.serializeBulkString(w, user_key);
            } else {
                try resp.serializeBulkString(w, null);
            }
        }
    }

    /// GRAPH.TRAVERSE <key> [DEPTH <n>] [DIR OUT|IN|BOTH] [EDGETYPE <type>] [NODETYPE <type>]
    fn cmdGraphTraverse(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "usage: GRAPH.TRAVERSE <key> [DEPTH n] [DIR OUT|IN|BOTH]");
            return;
        }

        var opts = query.TraversalOptions{};
        var i: usize = 2;
        while (i < args.len) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[i], &flag_buf);
            if (std.mem.eql(u8, flag, "DEPTH") and i + 1 < args.len) {
                opts.max_depth = std.fmt.parseInt(u32, args[i + 1], 10) catch 10;
                i += 2;
            } else if (std.mem.eql(u8, flag, "DIR") and i + 1 < args.len) {
                var dir_buf: [64]u8 = undefined;
                const dir = toUpper(args[i + 1], &dir_buf);
                if (std.mem.eql(u8, dir, "IN")) {
                    opts.direction = .incoming;
                } else if (std.mem.eql(u8, dir, "BOTH")) {
                    opts.direction = .both;
                } else {
                    opts.direction = .outgoing;
                }
                i += 2;
            } else if (std.mem.eql(u8, flag, "EDGETYPE") and i + 1 < args.len) {
                opts.edge_type_filter = args[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, flag, "NODETYPE") and i + 1 < args.len) {
                opts.node_type_filter = args[i + 1];
                i += 2;
            } else {
                i += 1;
            }
        }

        const nk = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(nk);
        const ids = query.traverse(self.graph, self.allocator, nk, opts) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        defer self.allocator.free(ids);

        try resp.serializeArrayHeader(w, ids.len);
        for (ids) |nid| {
            const node = self.graph.getNodeById(nid);
            if (node) |n| {
                const user_key = stripGraphDbPrefix(self, n.key) orelse n.key;
                try resp.serializeBulkString(w, user_key);
            } else {
                try resp.serializeBulkString(w, null);
            }
        }
    }

    /// GRAPH.PATH <from_key> <to_key> [MAXDEPTH <n>]
    fn cmdGraphPath(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "usage: GRAPH.PATH <from> <to> [MAXDEPTH n]");
            return;
        }

        var max_depth: u32 = 20;
        if (args.len >= 5) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[3], &flag_buf);
            if (std.mem.eql(u8, flag, "MAXDEPTH")) {
                max_depth = std.fmt.parseInt(u32, args[4], 10) catch 20;
            }
        }

        const from = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(from);
        const to = graphNamespacedKey(self, args[2]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(to);
        var result = query.shortestPath(self.graph, self.allocator, from, to, max_depth) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        defer result.deinit(self.allocator);

        try resp.serializeArrayHeader(w, result.nodes.len);
        for (result.nodes) |nid| {
            const node = self.graph.getNodeById(nid);
            if (node) |n| {
                const user_key = stripGraphDbPrefix(self, n.key) orelse n.key;
                try resp.serializeBulkString(w, user_key);
            } else {
                try resp.serializeBulkString(w, null);
            }
        }
    }

    /// GRAPH.WPATH <from_key> <to_key>  (weighted shortest path via Dijkstra)
    fn cmdGraphWPath(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "usage: GRAPH.WPATH <from> <to>");
            return;
        }

        const from = graphNamespacedKey(self, args[1]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(from);
        const to = graphNamespacedKey(self, args[2]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(to);
        var result = query.weightedShortestPath(self.graph, self.allocator, from, to) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        defer result.deinit(self.allocator);

        // Return [weight, node1, node2, ...]
        try resp.serializeArrayHeader(w, result.nodes.len + 1);

        var weight_buf: [32]u8 = undefined;
        const weight_str = std.fmt.bufPrint(&weight_buf, "{d:.2}", .{result.total_weight}) catch "0";
        try resp.serializeBulkString(w, weight_str);

        for (result.nodes) |nid| {
            const node = self.graph.getNodeById(nid);
            if (node) |n| {
                const user_key = stripGraphDbPrefix(self, n.key) orelse n.key;
                try resp.serializeBulkString(w, user_key);
            } else {
                try resp.serializeBulkString(w, null);
            }
        }
    }

    /// GRAPH.STATS
    fn cmdGraphStats(self: *CommandHandler, w: *std.Io.Writer) !void {
        var nodes: usize = 0;
        for (self.graph.nodes.items) |node| {
            if (node.deleted) continue;
            if (stripGraphDbPrefix(self, node.key) != null) nodes += 1;
        }
        var edges: usize = 0;
        for (self.graph.edges.items) |edge| {
            if (edge.isDeleted()) continue;
            const from_node = self.graph.getNodeById(edge.from) orelse continue;
            if (stripGraphDbPrefix(self, from_node.key) != null) edges += 1;
        }
        try resp.serializeArrayHeader(w, 4);
        try resp.serializeBulkString(w, "nodes");
        try resp.serializeInteger(w, @intCast(nodes));
        try resp.serializeBulkString(w, "edges");
        try resp.serializeInteger(w, @intCast(edges));
    }

    // ── Persistence Commands ─────────────────────────────────────────

    /// SAVE -- foreground snapshot + AOF truncate
    fn cmdSave(self: *CommandHandler, w: *std.Io.Writer) !void {
        const a = self.aof orelse {
            try resp.serializeError(w, "persistence not configured");
            return;
        };
        snapshot.save(self.io, self.allocator, self.kv, self.graph, a.snapshot_path) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        a.truncate() catch {};
        a.last_save_time = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        try resp.serializeSimpleString(w, "OK");
    }

    /// LASTSAVE -- unix timestamp (seconds) of last successful snapshot
    fn cmdLastSave(self: *CommandHandler, w: *std.Io.Writer) !void {
        const ts = if (self.aof) |a| @divTrunc(a.last_save_time, 1000) else 0;
        try resp.serializeInteger(w, ts);
    }

    fn logToAOF(self: *CommandHandler, args: []const []const u8) void {
        if (self.aof) |a| a.logCommand(args);
    }

    // ── Helpers ───────────────────────────────────────────────────────

    fn parseDirection(args: []const []const u8) query.Direction {
        if (args.len < 3) return .outgoing;
        var buf: [64]u8 = undefined;
        const d = toUpper(args[2], &buf);
        if (std.mem.eql(u8, d, "IN")) return .incoming;
        if (std.mem.eql(u8, d, "BOTH")) return .both;
        return .outgoing;
    }
};

const NamespacedKeyRef = struct {
    key: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *const NamespacedKeyRef, allocator: Allocator) void {
        if (self.owned) |buf| allocator.free(buf);
    }
};

fn toUpper(input: []const u8, buf: *[64]u8) []const u8 {
    const len = @min(input.len, 64);
    for (0..len) |i| {
        buf[i] = std.ascii.toUpper(input[i]);
    }
    return buf[0..len];
}

// Overload for smaller buffers
fn toUpperBuf(input: []const u8, buf: []u8) []const u8 {
    const len = @min(input.len, buf.len);
    for (0..len) |i| {
        buf[i] = std.ascii.toUpper(input[i]);
    }
    return buf[0..len];
}

fn namespacedKey(self: *CommandHandler, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(self.allocator, "db:{d}:{s}", .{ self.selected_db.load(.monotonic), key });
}

fn namespacedKeyRef(self: *CommandHandler, key: []const u8, stack_buf: []u8) !NamespacedKeyRef {
    const db = self.selected_db.load(.monotonic);
    const prefix = std.fmt.bufPrint(stack_buf, "db:{d}:", .{db}) catch {
        const owned = try namespacedKey(self, key);
        return .{ .key = owned, .owned = owned };
    };
    const total_len = prefix.len + key.len;
    if (total_len <= stack_buf.len) {
        std.mem.copyForwards(u8, stack_buf[prefix.len .. prefix.len + key.len], key);
        return .{ .key = stack_buf[0..total_len] };
    }
    const owned = try namespacedKey(self, key);
    return .{ .key = owned, .owned = owned };
}

fn namespacedKeyForDb(self: *CommandHandler, db: u8, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(self.allocator, "db:{d}:{s}", .{ db, key });
}

fn stripDbPrefix(self: *CommandHandler, raw_key: []const u8) ?[]const u8 {
    const prefix = std.fmt.allocPrint(self.allocator, "db:{d}:", .{self.selected_db.load(.monotonic)}) catch return null;
    defer self.allocator.free(prefix);
    if (!std.mem.startsWith(u8, raw_key, prefix)) return null;
    return raw_key[prefix.len..];
}

fn graphNamespacedKey(self: *CommandHandler, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(self.allocator, "gdb:{d}:{s}", .{ self.selected_db.load(.monotonic), key });
}

fn stripGraphDbPrefix(self: *CommandHandler, raw_key: []const u8) ?[]const u8 {
    const prefix = std.fmt.allocPrint(self.allocator, "gdb:{d}:", .{self.selected_db.load(.monotonic)}) catch return null;
    defer self.allocator.free(prefix);
    if (!std.mem.startsWith(u8, raw_key, prefix)) return null;
    return raw_key[prefix.len..];
}

fn globMatch(pattern: []const u8, string: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;

    while (si < string.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == string[si])) {
            pi += 1;
            si += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_p = pi;
            star_s = si;
            pi += 1;
        } else if (star_p) |sp| {
            pi = sp + 1;
            star_s += 1;
            si = star_s;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ─── Tests ────────────────────────────────────────────────────────────

test "command handler PING" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();

    const args = [_][]const u8{"PING"};
    try handler.execute(&args, &aw.writer);
    try std.testing.expectEqualStrings("+PONG\r\n", aw.written());
}

test "command handler SET/GET" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    var list1: std.ArrayList(u8) = .empty;
    defer list1.deinit(allocator);
    var aw1 = std.Io.Writer.Allocating.fromArrayList(allocator, &list1);
    defer aw1.deinit();

    const set_args = [_][]const u8{ "SET", "mykey", "myvalue" };
    try handler.execute(&set_args, &aw1.writer);
    try std.testing.expectEqualStrings("+OK\r\n", aw1.written());

    var list2: std.ArrayList(u8) = .empty;
    defer list2.deinit(allocator);
    var aw2 = std.Io.Writer.Allocating.fromArrayList(allocator, &list2);
    defer aw2.deinit();

    const get_args = [_][]const u8{ "GET", "mykey" };
    try handler.execute(&get_args, &aw2.writer);
    try std.testing.expectEqualStrings("$7\r\nmyvalue\r\n", aw2.written());
}

test "command handler GRAPH.ADDNODE" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();

    const args = [_][]const u8{ "GRAPH.ADDNODE", "user:1", "person" };
    try handler.execute(&args, &aw.writer);
    try std.testing.expectEqualStrings(":0\r\n", aw.written());
}

test "command handler SELECT isolates KV namespace" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(allocator);
    var aw1 = std.Io.Writer.Allocating.fromArrayList(allocator, &out1);
    defer aw1.deinit();
    const set_db0 = [_][]const u8{ "SET", "same", "db0" };
    try handler.execute(&set_db0, &aw1.writer);

    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(allocator);
    var aw2 = std.Io.Writer.Allocating.fromArrayList(allocator, &out2);
    defer aw2.deinit();
    const select1 = [_][]const u8{ "SELECT", "1" };
    try handler.execute(&select1, &aw2.writer);

    var out3: std.ArrayList(u8) = .empty;
    defer out3.deinit(allocator);
    var aw3 = std.Io.Writer.Allocating.fromArrayList(allocator, &out3);
    defer aw3.deinit();
    const get_missing = [_][]const u8{ "GET", "same" };
    try handler.execute(&get_missing, &aw3.writer);
    try std.testing.expectEqualStrings("$-1\r\n", aw3.written());

    var out4: std.ArrayList(u8) = .empty;
    defer out4.deinit(allocator);
    var aw4 = std.Io.Writer.Allocating.fromArrayList(allocator, &out4);
    defer aw4.deinit();
    const set_db1 = [_][]const u8{ "SET", "same", "db1" };
    try handler.execute(&set_db1, &aw4.writer);

    var out5: std.ArrayList(u8) = .empty;
    defer out5.deinit(allocator);
    var aw5 = std.Io.Writer.Allocating.fromArrayList(allocator, &out5);
    defer aw5.deinit();
    const select0 = [_][]const u8{ "SELECT", "0" };
    try handler.execute(&select0, &aw5.writer);

    var out6: std.ArrayList(u8) = .empty;
    defer out6.deinit(allocator);
    var aw6 = std.Io.Writer.Allocating.fromArrayList(allocator, &out6);
    defer aw6.deinit();
    const get_db0 = [_][]const u8{ "GET", "same" };
    try handler.execute(&get_db0, &aw6.writer);
    try std.testing.expectEqualStrings("$3\r\ndb0\r\n", aw6.written());
}
