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

        // ── Fast dispatch: switch on (cmd.len, first_byte) ────────────
        // Most commands resolved in 1-2 comparisons instead of linear scan.
        const first = if (cmd.len > 0) std.ascii.toUpper(cmd[0]) else 0;
        switch (cmd.len) {
            3 => switch (first) {
                'S' => if (std.mem.eql(u8, cmd, "SET")) return self.cmdSet(args, w),
                'G' => if (std.mem.eql(u8, cmd, "GET")) return self.cmdGet(args, w),
                'D' => if (std.mem.eql(u8, cmd, "DEL")) return self.cmdDel(args, w),
                'T' => if (std.mem.eql(u8, cmd, "TTL")) return self.cmdTtl(args, w),
                else => {},
            },
            4 => switch (first) {
                'P' => if (std.mem.eql(u8, cmd, "PING")) return self.cmdPing(args, w),
                'M' => {
                    if (std.mem.eql(u8, cmd, "MGET")) return self.cmdMget(args, w);
                    if (std.mem.eql(u8, cmd, "MSET")) return self.cmdMset(args, w);
                    if (std.mem.eql(u8, cmd, "MOVE")) return self.cmdMove(args, w);
                },
                'K' => if (std.mem.eql(u8, cmd, "KEYS")) return self.cmdKeys(args, w),
                'S' => {
                    if (std.mem.eql(u8, cmd, "SCAN")) return self.cmdScan(args, w);
                    if (std.mem.eql(u8, cmd, "SAVE")) return self.cmdSave(w);
                },
                'I' => {
                    if (std.mem.eql(u8, cmd, "INFO")) return self.cmdInfo(w);
                    if (std.mem.eql(u8, cmd, "INCR")) return self.cmdIncr(args, w);
                },
                'D' => if (std.mem.eql(u8, cmd, "DECR")) return self.cmdDecr(args, w),
                else => {},
            },
            5 => switch (first) {
                'E' => {},
                else => {},
            },
            6 => switch (first) {
                'E' => {
                    if (std.mem.eql(u8, cmd, "EXISTS")) return self.cmdExists(args, w);
                    if (std.mem.eql(u8, cmd, "EXPIRE")) return self.cmdExpire(args, w);
                },
                'D' => {
                    if (std.mem.eql(u8, cmd, "DBSIZE")) return self.cmdDbsize(w);
                    if (std.mem.eql(u8, cmd, "DECRBY")) return self.cmdDecrBy(args, w);
                },
                'S' => if (std.mem.eql(u8, cmd, "SELECT")) return self.cmdSelect(args, w),
                'I' => if (std.mem.eql(u8, cmd, "INCRBY")) return self.cmdIncrBy(args, w),
                'A' => if (std.mem.eql(u8, cmd, "APPEND")) return self.cmdAppend(args, w),
                else => {},
            },
            7 => switch (first) {
                'F' => {
                    if (std.mem.eql(u8, cmd, "FLUSHDB")) return self.cmdFlushdb(args, w);
                },
                'C' => if (std.mem.eql(u8, cmd, "COMMAND")) return self.cmdCommand(w),
                'P' => if (std.mem.eql(u8, cmd, "PERSIST")) return self.cmdPersist(args, w),
                else => {},
            },
            8 => if (first == 'F' and std.mem.eql(u8, cmd, "FLUSHALL")) return self.cmdFlushall(args, w)
                else if (first == 'L' and std.mem.eql(u8, cmd, "LASTSAVE")) return self.cmdLastSave(w),
            12 => if (first == 'B' and std.mem.eql(u8, cmd, "BGREWRITEAOF")) return self.cmdBgRewriteAof(w),
            else => {},
        }

        // ── Graph commands (GRAPH.*) — dispatch on suffix ────────────
        if (cmd.len >= 6 and std.mem.eql(u8, cmd[0..6], "GRAPH.")) {
            const sub = cmd[6..];
            const sub_first = if (sub.len > 0) std.ascii.toUpper(sub[0]) else 0;
            switch (sub_first) {
                'A' => {
                    if (std.mem.eql(u8, sub, "ADDNODE")) return self.cmdGraphAddNode(args, w);
                    if (std.mem.eql(u8, sub, "ADDEDGE")) return self.cmdGraphAddEdge(args, w);
                },
                'G' => if (std.mem.eql(u8, sub, "GETNODE")) return self.cmdGraphGetNode(args, w),
                'D' => {
                    if (std.mem.eql(u8, sub, "DELNODE")) return self.cmdGraphDelNode(args, w);
                    if (std.mem.eql(u8, sub, "DELEDGE")) return self.cmdGraphDelEdge(args, w);
                },
                'S' => {
                    if (std.mem.eql(u8, sub, "SETPROP")) return self.cmdGraphSetProp(args, w);
                    if (std.mem.eql(u8, sub, "STATS")) return self.cmdGraphStats(w);
                },
                'N' => if (std.mem.eql(u8, sub, "NEIGHBORS")) return self.cmdGraphNeighbors(args, w),
                'T' => if (std.mem.eql(u8, sub, "TRAVERSE")) return self.cmdGraphTraverse(args, w),
                'P' => if (std.mem.eql(u8, sub, "PATH")) return self.cmdGraphPath(args, w),
                'W' => if (std.mem.eql(u8, sub, "WPATH")) return self.cmdGraphWPath(args, w),
                'C' => if (std.mem.eql(u8, sub, "COMPACT")) return self.cmdGraphCompact(w),
                else => {},
            }
        }

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
        var giter = self.graph.key_to_id.iterator();
        while (giter.next()) |entry| {
            if (stripGraphDbPrefix(self, entry.key_ptr.*) != null) {
                const dup = self.allocator.dupe(u8, entry.key_ptr.*) catch {
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
        if (src_entry.flags.has_ttl) {
            const remaining = src_entry.expires_at - now;
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

    /// MGET key [key ...] — get multiple keys
    fn cmdMget(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'MGET'");
            return;
        }
        try resp.serializeArrayHeader(w, args.len - 1);
        for (args[1..]) |user_key| {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRef(self, user_key, &key_buf) catch {
                try resp.serializeBulkString(w, null);
                continue;
            };
            defer key_ref.deinit(self.allocator);
            if (self.kv.get(key_ref.key)) |val| {
                try resp.serializeBulkString(w, val);
            } else {
                try resp.serializeBulkString(w, null);
            }
        }
    }

    /// MSET key value [key value ...] — set multiple keys
    fn cmdMset(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3 or (args.len - 1) % 2 != 0) {
            try resp.serializeError(w, "wrong number of arguments for 'MSET'");
            return;
        }
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 2) {
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRef(self, args[i], &key_buf) catch continue;
            defer key_ref.deinit(self.allocator);
            self.kv.set(key_ref.key, args[i + 1]) catch continue;
        }
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// INCR key — increment integer value by 1
    fn cmdIncr(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        return self.incrByN(args, w, 1);
    }

    /// DECR key — decrement integer value by 1
    fn cmdDecr(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        return self.incrByN(args, w, -1);
    }

    /// INCRBY key increment
    fn cmdIncrBy(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'INCRBY'");
            return;
        }
        const delta = std.fmt.parseInt(i64, args[2], 10) catch {
            try resp.serializeError(w, "value is not an integer or out of range");
            return;
        };
        return self.incrByN(args, w, delta);
    }

    /// DECRBY key decrement
    fn cmdDecrBy(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'DECRBY'");
            return;
        }
        const delta = std.fmt.parseInt(i64, args[2], 10) catch {
            try resp.serializeError(w, "value is not an integer or out of range");
            return;
        };
        return self.incrByN(args, w, -delta);
    }

    fn incrByN(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer, delta: i64) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);

        // Get current value (default 0)
        var current: i64 = 0;
        if (self.kv.get(key_ref.key)) |val| {
            current = std.fmt.parseInt(i64, val, 10) catch {
                try resp.serializeError(w, "value is not an integer or out of range");
                return;
            };
        }

        const new_val = current + delta;
        var val_buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&val_buf, "{d}", .{new_val}) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        self.kv.set(key_ref.key, val_str) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        self.logToAOF(args);
        try resp.serializeInteger(w, new_val);
    }

    /// EXPIRE key seconds — set TTL on existing key
    fn cmdExpire(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'EXPIRE'");
            return;
        }
        const ttl_seconds = std.fmt.parseInt(i64, args[2], 10) catch {
            try resp.serializeError(w, "value is not an integer or out of range");
            return;
        };
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);

        // Get current value, re-set with TTL
        if (self.kv.get(key_ref.key)) |val| {
            self.kv.setEx(key_ref.key, val, ttl_seconds) catch {
                try resp.serializeInteger(w, 0);
                return;
            };
            self.logToAOF(args);
            try resp.serializeInteger(w, 1);
        } else {
            try resp.serializeInteger(w, 0); // key doesn't exist
        }
    }

    /// PERSIST key — remove TTL from key
    fn cmdPersist(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'PERSIST'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);

        // Get current value, re-set without TTL
        if (self.kv.get(key_ref.key)) |val| {
            self.kv.set(key_ref.key, val) catch {
                try resp.serializeInteger(w, 0);
                return;
            };
            self.logToAOF(args);
            try resp.serializeInteger(w, 1);
        } else {
            try resp.serializeInteger(w, 0);
        }
    }

    /// APPEND key value — append to existing value
    fn cmdAppend(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'APPEND'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);

        if (self.kv.get(key_ref.key)) |existing| {
            // Concatenate existing + new
            const new_len = existing.len + args[2].len;
            const new_val = self.allocator.alloc(u8, new_len) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
            defer self.allocator.free(new_val);
            @memcpy(new_val[0..existing.len], existing);
            @memcpy(new_val[existing.len..], args[2]);
            self.kv.set(key_ref.key, new_val) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
            self.logToAOF(args);
            try resp.serializeInteger(w, @intCast(new_len));
        } else {
            // Key doesn't exist — create with just the append value
            self.kv.set(key_ref.key, args[2]) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
            self.logToAOF(args);
            try resp.serializeInteger(w, @intCast(args[2].len));
        }
    }

    fn cmdInfo(self: *CommandHandler, out: *std.Io.Writer) std.Io.Writer.Error!void {
        var kv_keys: usize = 0;
        var kv_with_ttl: u32 = 0;
        var it = self.kv.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
            if (stripDbPrefix(self, entry.key_ptr.*) != null) {
                kv_keys += 1;
                if (entry.value_ptr.flags.has_ttl) kv_with_ttl += 1;
            }
        }
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();

        // Server section
        try aw.writer.writeAll("# Server\r\n");
        try aw.writer.writeAll("vex_version:0.2.0\r\n");
        try aw.writer.writeAll("engine:csr_soa_v2\r\n");

        // Keyspace section
        try aw.writer.writeAll("\r\n# Keyspace\r\n");
        try aw.writer.print("kv_keys:{d}\r\n", .{kv_keys});
        try aw.writer.print("kv_with_ttl:{d}\r\n", .{kv_with_ttl});
        try aw.writer.print("kv_tombstones:{d}\r\n", .{self.kv.tombstone_count});
        try aw.writer.print("db_selected:{d}\r\n", .{self.selected_db.load(.monotonic)});
        try aw.writer.print("db_max:{d}\r\n", .{MAX_DATABASES});

        // Graph section
        try aw.writer.writeAll("\r\n# Graph\r\n");
        try aw.writer.print("graph_nodes:{d}\r\n", .{self.graph.nodeCount()});
        try aw.writer.print("graph_edges:{d}\r\n", .{self.graph.edgeCount()});
        try aw.writer.print("graph_types:{d}\r\n", .{self.graph.type_intern.count()});
        try aw.writer.print("graph_delta_edges:{d}\r\n", .{self.graph.delta_edges.items.len});
        try aw.writer.print("graph_needs_compact:{d}\r\n", .{@intFromBool(self.graph.needs_compact)});

        // Persistence section
        try aw.writer.writeAll("\r\n# Persistence\r\n");
        if (self.aof) |a| {
            try aw.writer.writeAll("aof_enabled:1\r\n");
            try aw.writer.print("last_save_time:{d}\r\n", .{@divTrunc(a.last_save_time, 1000)});
        } else {
            try aw.writer.writeAll("aof_enabled:0\r\n");
        }

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
        const prop_count = self.graph.node_props.countProps(node.id);
        const pairs = self.graph.node_props.collectAll(node.id, self.allocator) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(pairs);
        const total: usize = 3 + prop_count * 2;
        try resp.serializeArrayHeader(w, total);
        const user_key = stripGraphDbPrefix(self, node.key) orelse node.key;
        try resp.serializeBulkString(w, user_key);
        try resp.serializeBulkString(w, node.node_type);
        try resp.serializeInteger(w, @intCast(prop_count));
        for (pairs) |pair| {
            try resp.serializeBulkString(w, pair.key);
            try resp.serializeBulkString(w, pair.value);
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
    /// GRAPH.COMPACT -- rebuild CSR from delta edges for fast traversals
    fn cmdGraphCompact(self: *CommandHandler, w: *std.Io.Writer) !void {
        self.graph.compact() catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdGraphStats(self: *CommandHandler, w: *std.Io.Writer) !void {
        var nodes: usize = 0;
        var key_iter = self.graph.key_to_id.iterator();
        while (key_iter.next()) |entry| {
            if (stripGraphDbPrefix(self, entry.key_ptr.*) != null) nodes += 1;
        }
        var edges: usize = 0;
        for (0..self.graph.edge_from.items.len) |eidx| {
            if (!self.graph.edge_alive.isSet(eidx)) continue;
            const from_id = self.graph.edge_from.items[eidx];
            const from_node = self.graph.getNodeById(from_id) orelse continue;
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

    /// BGREWRITEAOF -- rewrite AOF from current state (compacts redundant ops)
    fn cmdBgRewriteAof(self: *CommandHandler, w: *std.Io.Writer) !void {
        const a = self.aof orelse {
            try resp.serializeError(w, "persistence not configured");
            return;
        };
        a.rewriteFromState(self.allocator, self.kv, self.graph) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        try resp.serializeSimpleString(w, "Background AOF rewrite started");
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

// ─── Helper: create a fresh handler + run a command, return response string ───
fn testExec(handler: *CommandHandler, allocator: Allocator, args: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();
    try handler.execute(args, &aw.writer);
    return allocator.dupe(u8, aw.written());
}

test "MGET/MSET" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // MSET k1 v1 k2 v2
    const mset = [_][]const u8{ "MSET", "k1", "v1", "k2", "v2" };
    const r1 = try testExec(&handler, allocator, &mset);
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("+OK\r\n", r1);

    // MGET k1 k2 missing
    const mget = [_][]const u8{ "MGET", "k1", "k2", "missing" };
    const r2 = try testExec(&handler, allocator, &mget);
    defer allocator.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "*3\r\n") != null); // array of 3
    try std.testing.expect(std.mem.indexOf(u8, r2, "$2\r\nv1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "$2\r\nv2\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "$-1\r\n") != null); // null for missing
}

test "INCR/DECR" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // INCR on non-existent key → 1
    const incr1 = [_][]const u8{ "INCR", "counter" };
    const r1 = try testExec(&handler, allocator, &incr1);
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(":1\r\n", r1);

    // INCR again → 2
    const r2 = try testExec(&handler, allocator, &incr1);
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(":2\r\n", r2);

    // DECR → 1
    const decr = [_][]const u8{ "DECR", "counter" };
    const r3 = try testExec(&handler, allocator, &decr);
    defer allocator.free(r3);
    try std.testing.expectEqualStrings(":1\r\n", r3);

    // INCRBY 10 → 11
    const incrby = [_][]const u8{ "INCRBY", "counter", "10" };
    const r4 = try testExec(&handler, allocator, &incrby);
    defer allocator.free(r4);
    try std.testing.expectEqualStrings(":11\r\n", r4);

    // DECRBY 5 → 6
    const decrby = [_][]const u8{ "DECRBY", "counter", "5" };
    const r5 = try testExec(&handler, allocator, &decrby);
    defer allocator.free(r5);
    try std.testing.expectEqualStrings(":6\r\n", r5);

    // INCR on non-integer value → error
    const set_str = [_][]const u8{ "SET", "str", "hello" };
    const rs = try testExec(&handler, allocator, &set_str);
    defer allocator.free(rs);
    const incr_str = [_][]const u8{ "INCR", "str" };
    const re = try testExec(&handler, allocator, &incr_str);
    defer allocator.free(re);
    try std.testing.expect(std.mem.indexOf(u8, re, "-ERR") != null);
}

test "EXPIRE/PERSIST/TTL" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // SET key
    const set = [_][]const u8{ "SET", "mykey", "val" };
    const r1 = try testExec(&handler, allocator, &set);
    defer allocator.free(r1);

    // TTL returns -1 (no expiry)
    const ttl1 = [_][]const u8{ "TTL", "mykey" };
    const r2 = try testExec(&handler, allocator, &ttl1);
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(":-1\r\n", r2);

    // EXPIRE 3600
    const expire = [_][]const u8{ "EXPIRE", "mykey", "3600" };
    const r3 = try testExec(&handler, allocator, &expire);
    defer allocator.free(r3);
    try std.testing.expectEqualStrings(":1\r\n", r3);

    // TTL now > 0
    const r4 = try testExec(&handler, allocator, &ttl1);
    defer allocator.free(r4);
    try std.testing.expect(r4[0] == ':');
    try std.testing.expect(r4[1] != '-'); // positive TTL

    // PERSIST removes TTL
    const persist = [_][]const u8{ "PERSIST", "mykey" };
    const r5 = try testExec(&handler, allocator, &persist);
    defer allocator.free(r5);
    try std.testing.expectEqualStrings(":1\r\n", r5);

    // TTL back to -1
    const r6 = try testExec(&handler, allocator, &ttl1);
    defer allocator.free(r6);
    try std.testing.expectEqualStrings(":-1\r\n", r6);

    // EXPIRE on non-existent key → 0
    const expire_missing = [_][]const u8{ "EXPIRE", "nokey", "100" };
    const r7 = try testExec(&handler, allocator, &expire_missing);
    defer allocator.free(r7);
    try std.testing.expectEqualStrings(":0\r\n", r7);
}

test "APPEND" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // APPEND to non-existent key → creates it
    const append1 = [_][]const u8{ "APPEND", "msg", "hello" };
    const r1 = try testExec(&handler, allocator, &append1);
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(":5\r\n", r1); // length 5

    // APPEND more
    const append2 = [_][]const u8{ "APPEND", "msg", " world" };
    const r2 = try testExec(&handler, allocator, &append2);
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(":11\r\n", r2); // length 11

    // GET to verify
    const get = [_][]const u8{ "GET", "msg" };
    const r3 = try testExec(&handler, allocator, &get);
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("$11\r\nhello world\r\n", r3);
}
