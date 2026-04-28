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
const ListStore = @import("../engine/list.zig").ListStore;
const HashStore = @import("../engine/hash.zig").HashStore;
const SetStore = @import("../engine/set.zig").SetStore;
const SortedSetStore = @import("../engine/sorted_set.zig").SortedSetStore;
const MAX_DATABASES: u8 = 16;
const KEYS_MAX_REPLY: usize = 1000;
const SCAN_DEFAULT_COUNT: usize = 10;

pub const KeysMode = enum {
    strict,
    autoscan,
};

/// Central command dispatcher. Parses a RESP array (the Redis command)
/// and routes to the appropriate KV or graph handler.
/// Shared atomic flag for BGSAVE (prevents concurrent background saves).
pub var bgsave_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub const CommandHandler = struct {
    kv: *KVStore,
    graph: *GraphEngine,
    allocator: Allocator,
    io: std.Io,
    aof: ?*AOF,
    selected_db: *std.atomic.Value(u8),
    keys_mode: KeysMode,
    graph_rwlock: ?*std.c.pthread_rwlock_t,
    list_store: ?*ListStore,
    hash_store: ?*HashStore,
    set_store: ?*SetStore,
    sorted_set_store: ?*SortedSetStore,
    data_dir: ?[]const u8,

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
            .graph_rwlock = null,
            .list_store = null,
            .hash_store = null,
            .set_store = null,
            .sorted_set_store = null,
            .data_dir = null,
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
                'P' => {
                    if (std.mem.eql(u8, cmd, "PING")) return self.cmdPing(args, w);
                    if (std.mem.eql(u8, cmd, "PTTL")) return self.cmdPttl(args, w);
                },
                'M' => {
                    if (std.mem.eql(u8, cmd, "MGET")) return self.cmdMget(args, w);
                    if (std.mem.eql(u8, cmd, "MSET")) return self.cmdMset(args, w);
                    if (std.mem.eql(u8, cmd, "MOVE")) return self.cmdMove(args, w);
                },
                'K' => if (std.mem.eql(u8, cmd, "KEYS")) return self.cmdKeys(args, w),
                'S' => {
                    if (std.mem.eql(u8, cmd, "SCAN")) return self.cmdScan(args, w);
                    if (std.mem.eql(u8, cmd, "SAVE")) return self.cmdSave(w);
                    if (std.mem.eql(u8, cmd, "SADD")) return self.cmdSadd(args, w);
                    if (std.mem.eql(u8, cmd, "SREM")) return self.cmdSrem(args, w);
                },
                'I' => {
                    if (std.mem.eql(u8, cmd, "INFO")) return self.cmdInfo(w);
                    if (std.mem.eql(u8, cmd, "INCR")) return self.cmdIncr(args, w);
                },
                'D' => if (std.mem.eql(u8, cmd, "DECR")) return self.cmdDecr(args, w),
                'T' => if (std.mem.eql(u8, cmd, "TYPE")) return self.cmdType(args, w),
                'Q' => if (std.mem.eql(u8, cmd, "QUIT")) return self.cmdQuit(w),
                'E' => if (std.mem.eql(u8, cmd, "ECHO")) return self.cmdEcho(args, w),
                'H' => {
                    if (std.mem.eql(u8, cmd, "HSET")) return self.cmdHset(args, w);
                    if (std.mem.eql(u8, cmd, "HGET")) return self.cmdHgetFn(args, w);
                    if (std.mem.eql(u8, cmd, "HDEL")) return self.cmdHdel(args, w);
                    if (std.mem.eql(u8, cmd, "HLEN")) return self.cmdHlen(args, w);
                },
                'L' => {
                    if (std.mem.eql(u8, cmd, "LLEN")) return self.cmdLlen(args, w);
                    if (std.mem.eql(u8, cmd, "LSET")) return self.cmdLset(args, w);
                    if (std.mem.eql(u8, cmd, "LREM")) return self.cmdLrem(args, w);
                    if (std.mem.eql(u8, cmd, "LPOP")) return self.cmdLpop(args, w);
                },
                'R' => if (std.mem.eql(u8, cmd, "RPOP")) return self.cmdRpop(args, w),
                'Z' => {
                    if (std.mem.eql(u8, cmd, "ZADD")) return self.cmdZadd(args, w);
                    if (std.mem.eql(u8, cmd, "ZREM")) return self.cmdZrem(args, w);
                },
                else => {},
            },
            5 => switch (first) {
                'S' => {
                    if (std.mem.eql(u8, cmd, "SETNX")) return self.cmdSetNx(args, w);
                    if (std.mem.eql(u8, cmd, "SETEX")) return self.cmdSetEx(args, w);
                    if (std.mem.eql(u8, cmd, "SCARD")) return self.cmdScard(args, w);
                    if (std.mem.eql(u8, cmd, "SDIFF")) return self.cmdSdiff(args, w);
                },
                'G' => if (std.mem.eql(u8, cmd, "GETEX")) return self.cmdGetEx(args, w),
                'L' => if (std.mem.eql(u8, cmd, "LPUSH")) return self.cmdLpush(args, w),
                'R' => if (std.mem.eql(u8, cmd, "RPUSH")) return self.cmdRpush(args, w),
                'H' => {
                    if (std.mem.eql(u8, cmd, "HMSET")) return self.cmdHmset(args, w);
                    if (std.mem.eql(u8, cmd, "HMGET")) return self.cmdHmget(args, w);
                    if (std.mem.eql(u8, cmd, "HKEYS")) return self.cmdHkeys(args, w);
                    if (std.mem.eql(u8, cmd, "HVALS")) return self.cmdHvals(args, w);
                },
                'Z' => {
                    if (std.mem.eql(u8, cmd, "ZCARD")) return self.cmdZcard(args, w);
                    if (std.mem.eql(u8, cmd, "ZRANK")) return self.cmdZrank(args, w);
                },
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
                'S' => {
                    if (std.mem.eql(u8, cmd, "SELECT")) return self.cmdSelect(args, w);
                    if (std.mem.eql(u8, cmd, "STRLEN")) return self.cmdStrlen(args, w);
                    if (std.mem.eql(u8, cmd, "SINTER")) return self.cmdSinter(args, w);
                    if (std.mem.eql(u8, cmd, "SUNION")) return self.cmdSunion(args, w);
                },
                'I' => if (std.mem.eql(u8, cmd, "INCRBY")) return self.cmdIncrBy(args, w),
                'A' => if (std.mem.eql(u8, cmd, "APPEND")) return self.cmdAppend(args, w),
                'B' => if (std.mem.eql(u8, cmd, "BGSAVE")) return self.cmdBgSave(w),
                'G' => {
                    if (std.mem.eql(u8, cmd, "GETDEL")) return self.cmdGetDel(args, w);
                    if (std.mem.eql(u8, cmd, "GETSET")) return self.cmdGetSet(args, w);
                },
                'R' => if (std.mem.eql(u8, cmd, "RENAME")) return self.cmdRename(args, w),
                'L' => {
                    if (std.mem.eql(u8, cmd, "LRANGE")) return self.cmdLrange(args, w);
                    if (std.mem.eql(u8, cmd, "LINDEX")) return self.cmdLindex(args, w);
                },
                'Z' => {
                    if (std.mem.eql(u8, cmd, "ZSCORE")) return self.cmdZscore(args, w);
                    if (std.mem.eql(u8, cmd, "ZRANGE")) return self.cmdZrange(args, w);
                    if (std.mem.eql(u8, cmd, "ZCOUNT")) return self.cmdZcount(args, w);
                },
                else => {},
            },
            7 => switch (first) {
                'F' => if (std.mem.eql(u8, cmd, "FLUSHDB")) return self.cmdFlushdb(args, w),
                'C' => if (std.mem.eql(u8, cmd, "COMMAND")) return self.cmdCommand(w),
                'P' => {
                    if (std.mem.eql(u8, cmd, "PERSIST")) return self.cmdPersist(args, w);
                    if (std.mem.eql(u8, cmd, "PEXPIRE")) return self.cmdPExpire(args, w);
                },
                'H' => {
                    if (std.mem.eql(u8, cmd, "HGETALL")) return self.cmdHgetall(args, w);
                    if (std.mem.eql(u8, cmd, "HEXISTS")) return self.cmdHexists(args, w);
                    if (std.mem.eql(u8, cmd, "HINCRBY")) return self.cmdHincrby(args, w);
                },
                'Z' => if (std.mem.eql(u8, cmd, "ZINCRBY")) return self.cmdZincrby(args, w),
                else => {},
            },
            8 => switch (first) {
                'S' => if (std.mem.eql(u8, cmd, "SMEMBERS")) return self.cmdSmembers(args, w),
                'F' => if (std.mem.eql(u8, cmd, "FLUSHALL")) return self.cmdFlushall(args, w),
                'L' => if (std.mem.eql(u8, cmd, "LASTSAVE")) return self.cmdLastSave(w),
                'R' => if (std.mem.eql(u8, cmd, "RENAMENX")) return self.cmdRenameNx(args, w),
                else => {},
            },
            9 => switch (first) {
                'R' => if (std.mem.eql(u8, cmd, "RANDOMKEY")) return self.cmdRandomKey(w),
                'S' => if (std.mem.eql(u8, cmd, "SISMEMBER")) return self.cmdSismember(args, w),
                else => {},
            },
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
                'G' => {
                    if (std.mem.eql(u8, sub, "GETNODE")) return self.cmdGraphGetNode(args, w);
                    if (std.mem.eql(u8, sub, "GETVEC")) return self.cmdGraphGetVec(args, w);
                },
                'D' => {
                    if (std.mem.eql(u8, sub, "DELNODE")) return self.cmdGraphDelNode(args, w);
                    if (std.mem.eql(u8, sub, "DELEDGE")) return self.cmdGraphDelEdge(args, w);
                },
                'S' => {
                    if (std.mem.eql(u8, sub, "SETPROP")) return self.cmdGraphSetProp(args, w);
                    if (std.mem.eql(u8, sub, "SETVEC")) return self.cmdGraphSetVec(args, w);
                    if (std.mem.eql(u8, sub, "STATS")) return self.cmdGraphStats(w);
                },
                'U' => {
                    if (std.mem.eql(u8, sub, "UPSERT_NODE")) return self.cmdGraphUpsertNode(args, w);
                    if (std.mem.eql(u8, sub, "UPSERT_EDGE")) return self.cmdGraphUpsertEdge(args, w);
                },
                'I' => {
                    if (std.mem.eql(u8, sub, "INGEST")) return self.cmdGraphIngest(args, w);
                    if (std.mem.eql(u8, sub, "IMPACT")) return self.cmdGraphImpact(args, w);
                },
                'L' => if (std.mem.eql(u8, sub, "LIST_BY_TYPE")) return self.cmdGraphListByType(args, w),
                'N' => if (std.mem.eql(u8, sub, "NEIGHBORS")) return self.cmdGraphNeighbors(args, w),
                'T' => if (std.mem.eql(u8, sub, "TRAVERSE")) return self.cmdGraphTraverse(args, w),
                'P' => {
                    if (std.mem.eql(u8, sub, "PATH")) return self.cmdGraphPath(args, w);
                    if (std.mem.eql(u8, sub, "PATHS")) return self.cmdGraphPaths(args, w);
                },
                'W' => if (std.mem.eql(u8, sub, "WPATH")) return self.cmdGraphWPath(args, w),
                'C' => if (std.mem.eql(u8, sub, "COMPACT")) return self.cmdGraphCompact(w),
                'V' => if (std.mem.eql(u8, sub, "VECSEARCH")) return self.cmdGraphVecSearch(args, w),
                'R' => if (std.mem.eql(u8, sub, "RAG")) return self.cmdGraphRag(args, w),
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

        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);

        // Parse optional flags: EX/PX/NX/XX
        var ttl_sec: ?i64 = null;
        var ttl_ms: ?i64 = null;
        var nx = false;
        var xx = false;
        var i: usize = 3;
        while (i < args.len) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[i], &flag_buf);
            if (std.mem.eql(u8, flag, "EX") and i + 1 < args.len) {
                ttl_sec = std.fmt.parseInt(i64, args[i + 1], 10) catch {
                    try resp.serializeError(w, "value is not an integer");
                    return;
                };
                i += 2;
            } else if (std.mem.eql(u8, flag, "PX") and i + 1 < args.len) {
                ttl_ms = std.fmt.parseInt(i64, args[i + 1], 10) catch {
                    try resp.serializeError(w, "value is not an integer");
                    return;
                };
                i += 2;
            } else if (std.mem.eql(u8, flag, "NX")) {
                nx = true;
                i += 1;
            } else if (std.mem.eql(u8, flag, "XX")) {
                xx = true;
                i += 1;
            } else {
                i += 1;
            }
        }

        // NX: only set if key does NOT exist
        if (nx and self.kv.exists(key_ref.key)) {
            try resp.serializeBulkString(w, null);
            return;
        }
        // XX: only set if key DOES exist
        if (xx and !self.kv.exists(key_ref.key)) {
            try resp.serializeBulkString(w, null);
            return;
        }

        if (ttl_sec) |t| {
            self.kv.setEx(key_ref.key, args[2], t) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        } else if (ttl_ms) |t| {
            self.kv.setPx(key_ref.key, args[2], t) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        } else {
            self.kv.set(key_ref.key, args[2]) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        }
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

    /// ECHO message
    fn cmdEcho(_: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'ECHO'");
            return;
        }
        try resp.serializeBulkString(w, args[1]);
    }

    /// QUIT — close connection (responds OK, caller handles close)
    fn cmdQuit(_: *CommandHandler, w: *std.Io.Writer) !void {
        try resp.serializeSimpleString(w, "OK");
    }

    /// TYPE key — returns "string" for all KV entries (only type we have), "none" if missing
    fn cmdType(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'TYPE'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeSimpleString(w, "none");
            return;
        };
        defer key_ref.deinit(self.allocator);
        if (self.kv.exists(key_ref.key)) {
            try resp.serializeSimpleString(w, "string");
        } else {
            try resp.serializeSimpleString(w, "none");
        }
    }

    /// STRLEN key — length of the string value
    fn cmdStrlen(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'STRLEN'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeInteger(w, 0);
            return;
        };
        defer key_ref.deinit(self.allocator);
        if (self.kv.get(key_ref.key)) |val| {
            try resp.serializeInteger(w, @intCast(val.len));
        } else {
            try resp.serializeInteger(w, 0);
        }
    }

    /// SETNX key value — set only if key does not exist
    fn cmdSetNx(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'SETNX'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeInteger(w, 0);
            return;
        };
        defer key_ref.deinit(self.allocator);
        if (self.kv.exists(key_ref.key)) {
            try resp.serializeInteger(w, 0);
        } else {
            self.kv.set(key_ref.key, args[2]) catch {
                try resp.serializeInteger(w, 0);
                return;
            };
            self.logToAOF(args);
            try resp.serializeInteger(w, 1);
        }
    }

    /// SETEX key seconds value — set with expiry (Redis compat)
    fn cmdSetEx(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) {
            try resp.serializeError(w, "wrong number of arguments for 'SETEX'");
            return;
        }
        const ttl = std.fmt.parseInt(i64, args[2], 10) catch {
            try resp.serializeError(w, "value is not an integer or out of range");
            return;
        };
        if (ttl <= 0) {
            try resp.serializeError(w, "invalid expire time in 'SETEX'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);
        self.kv.setEx(key_ref.key, args[3], ttl) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// GETSET key value — atomically set and return old value
    fn cmdGetSet(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'GETSET'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer key_ref.deinit(self.allocator);
        const old = self.kv.get(key_ref.key);
        // Must copy old value before overwriting since KV owns the memory
        var old_copy: ?[]u8 = null;
        if (old) |v| {
            old_copy = self.allocator.dupe(u8, v) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        }
        defer if (old_copy) |oc| self.allocator.free(oc);
        self.kv.set(key_ref.key, args[2]) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        self.logToAOF(args);
        try resp.serializeBulkString(w, old_copy);
    }

    /// GETDEL key — get value and delete the key
    fn cmdGetDel(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'GETDEL'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeBulkString(w, null);
            return;
        };
        defer key_ref.deinit(self.allocator);
        const val = self.kv.get(key_ref.key);
        if (val) |v| {
            const copy = self.allocator.dupe(u8, v) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
            defer self.allocator.free(copy);
            _ = self.kv.delete(key_ref.key);
            self.logToAOF(args);
            try resp.serializeBulkString(w, copy);
        } else {
            try resp.serializeBulkString(w, null);
        }
    }

    /// GETEX key [EX seconds | PX ms | PERSIST] — get and optionally set/clear expiry
    fn cmdGetEx(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'GETEX'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeBulkString(w, null);
            return;
        };
        defer key_ref.deinit(self.allocator);
        const val = self.kv.get(key_ref.key);
        if (val == null) {
            try resp.serializeBulkString(w, null);
            return;
        }
        // Copy value before potential re-set
        const copy = self.allocator.dupe(u8, val.?) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(copy);

        if (args.len >= 4) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[2], &flag_buf);
            if (std.mem.eql(u8, flag, "EX")) {
                const ttl = std.fmt.parseInt(i64, args[3], 10) catch {
                    try resp.serializeError(w, "value is not an integer or out of range");
                    return;
                };
                self.kv.setEx(key_ref.key, copy, ttl) catch {};
            } else if (std.mem.eql(u8, flag, "PX")) {
                const ttl = std.fmt.parseInt(i64, args[3], 10) catch {
                    try resp.serializeError(w, "value is not an integer or out of range");
                    return;
                };
                self.kv.setPx(key_ref.key, copy, ttl) catch {};
            }
        } else if (args.len == 3) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[2], &flag_buf);
            if (std.mem.eql(u8, flag, "PERSIST")) {
                self.kv.set(key_ref.key, copy) catch {};
            }
        }
        try resp.serializeBulkString(w, copy);
    }

    /// PTTL key — remaining TTL in milliseconds
    fn cmdPttl(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'PTTL'");
            return;
        }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeInteger(w, -2);
            return;
        };
        defer key_ref.deinit(self.allocator);
        if (!self.kv.exists(key_ref.key)) {
            try resp.serializeInteger(w, -2);
            return;
        }
        const entry = self.kv.map.getPtr(key_ref.key) orelse {
            try resp.serializeInteger(w, -2);
            return;
        };
        if (!entry.flags.has_ttl) {
            try resp.serializeInteger(w, -1);
            return;
        }
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const remaining = entry.expires_at - now;
        try resp.serializeInteger(w, if (remaining > 0) remaining else 0);
    }

    /// PEXPIRE key milliseconds — set TTL in milliseconds
    fn cmdPExpire(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'PEXPIRE'");
            return;
        }
        const ttl_ms = std.fmt.parseInt(i64, args[2], 10) catch {
            try resp.serializeError(w, "value is not an integer or out of range");
            return;
        };
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeInteger(w, 0);
            return;
        };
        defer key_ref.deinit(self.allocator);
        if (self.kv.get(key_ref.key)) |val| {
            self.kv.setPx(key_ref.key, val, ttl_ms) catch {
                try resp.serializeInteger(w, 0);
                return;
            };
            self.logToAOF(args);
            try resp.serializeInteger(w, 1);
        } else {
            try resp.serializeInteger(w, 0);
        }
    }

    /// RENAME key newkey
    fn cmdRename(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'RENAME'");
            return;
        }
        var src_buf: [512]u8 = undefined;
        var src_ref = namespacedKeyRef(self, args[1], &src_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer src_ref.deinit(self.allocator);
        const val = self.kv.get(src_ref.key);
        if (val == null) {
            try resp.serializeError(w, "no such key");
            return;
        }
        const copy = self.allocator.dupe(u8, val.?) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(copy);
        var dst_buf: [512]u8 = undefined;
        var dst_ref = namespacedKeyRef(self, args[2], &dst_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer dst_ref.deinit(self.allocator);
        self.kv.set(dst_ref.key, copy) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        _ = self.kv.delete(src_ref.key);
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// RENAMENX key newkey — rename only if newkey does not exist
    fn cmdRenameNx(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) {
            try resp.serializeError(w, "wrong number of arguments for 'RENAMENX'");
            return;
        }
        var src_buf: [512]u8 = undefined;
        var src_ref = namespacedKeyRef(self, args[1], &src_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer src_ref.deinit(self.allocator);
        if (!self.kv.exists(src_ref.key)) {
            try resp.serializeError(w, "no such key");
            return;
        }
        var dst_buf: [512]u8 = undefined;
        var dst_ref = namespacedKeyRef(self, args[2], &dst_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer dst_ref.deinit(self.allocator);
        if (self.kv.exists(dst_ref.key)) {
            try resp.serializeInteger(w, 0);
            return;
        }
        const val = self.kv.get(src_ref.key).?;
        const copy = self.allocator.dupe(u8, val) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(copy);
        self.kv.set(dst_ref.key, copy) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        _ = self.kv.delete(src_ref.key);
        self.logToAOF(args);
        try resp.serializeInteger(w, 1);
    }

    // ── List Commands ──────────────────────────────────────────────────

    fn getListStore(self: *CommandHandler) *ListStore {
        return self.list_store orelse @panic("list_store not initialized");
    }

    fn cmdLpush(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'LPUSH'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        const len = self.getListStore().lpush(key_ref.key, args[2..]) catch { try resp.serializeError(w, "internal error"); return; };
        self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(len));
    }

    fn cmdRpush(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'RPUSH'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        const len = self.getListStore().rpush(key_ref.key, args[2..]) catch { try resp.serializeError(w, "internal error"); return; };
        self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(len));
    }

    fn cmdLpop(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'LPOP'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeBulkString(w, null); return; };
        defer key_ref.deinit(self.allocator);
        if (self.getListStore().lpop(key_ref.key)) |val| {
            self.logToAOF(args);
            try resp.serializeBulkString(w, val);
        } else {
            try resp.serializeBulkString(w, null);
        }
    }

    fn cmdRpop(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'RPOP'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeBulkString(w, null); return; };
        defer key_ref.deinit(self.allocator);
        if (self.getListStore().rpop(key_ref.key)) |val| {
            self.logToAOF(args);
            try resp.serializeBulkString(w, val);
        } else {
            try resp.serializeBulkString(w, null);
        }
    }

    fn cmdLlen(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'LLEN'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeInteger(w, @intCast(self.getListStore().llen(key_ref.key)));
    }

    fn cmdLrange(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "wrong number of arguments for 'LRANGE'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const start = std.fmt.parseInt(i64, args[2], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        const stop = std.fmt.parseInt(i64, args[3], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        if (self.getListStore().lrange(key_ref.key, start, stop)) |items| {
            defer if (items.len > 0) self.allocator.free(items);
            try resp.serializeArrayHeader(w, items.len);
            for (items) |item| try resp.serializeBulkString(w, item);
        } else {
            try resp.serializeArrayHeader(w, 0);
        }
    }

    fn cmdLindex(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'LINDEX'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeBulkString(w, null); return; };
        defer key_ref.deinit(self.allocator);
        const idx = std.fmt.parseInt(i64, args[2], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        try resp.serializeBulkString(w, self.getListStore().lindex(key_ref.key, idx));
    }

    fn cmdLset(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "wrong number of arguments for 'LSET'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "no such key"); return; };
        defer key_ref.deinit(self.allocator);
        const idx = std.fmt.parseInt(i64, args[2], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        self.getListStore().lset(key_ref.key, idx, args[3]) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdLrem(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "wrong number of arguments for 'LREM'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const count = std.fmt.parseInt(i64, args[2], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        const removed = self.getListStore().lrem(key_ref.key, count, args[3]);
        if (removed > 0) self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(removed));
    }

    // ── Hash Commands ────────────────────────────────────────────────

    fn getHashStore(self: *CommandHandler) *HashStore {
        return self.hash_store orelse @panic("hash_store not initialized");
    }

    fn cmdHset(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4 or (args.len - 2) % 2 != 0) { try resp.serializeError(w, "wrong number of arguments for 'HSET'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        const added = self.getHashStore().hset(key_ref.key, args[2..]) catch { try resp.serializeError(w, "internal error"); return; };
        self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(added));
    }

    fn cmdHgetFn(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'HGET'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeBulkString(w, null); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeBulkString(w, self.getHashStore().hget(key_ref.key, args[2]));
    }

    fn cmdHdel(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'HDEL'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const removed = self.getHashStore().hdel(key_ref.key, args[2..]);
        if (removed > 0) self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(removed));
    }

    fn cmdHgetall(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'HGETALL'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const pairs = self.getHashStore().hgetall(key_ref.key, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (pairs.len > 0) self.allocator.free(pairs);
        try resp.serializeArrayHeader(w, pairs.len);
        for (pairs) |s| try resp.serializeBulkString(w, s);
    }

    fn cmdHlen(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'HLEN'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeInteger(w, @intCast(self.getHashStore().hlen(key_ref.key)));
    }

    fn cmdHexists(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'HEXISTS'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeInteger(w, if (self.getHashStore().hexists(key_ref.key, args[2])) @as(i64, 1) else 0);
    }

    fn cmdHmset(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4 or (args.len - 2) % 2 != 0) { try resp.serializeError(w, "wrong number of arguments for 'HMSET'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        _ = self.getHashStore().hset(key_ref.key, args[2..]) catch { try resp.serializeError(w, "internal error"); return; };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdHmget(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'HMGET'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch {
            try resp.serializeArrayHeader(w, args.len - 2);
            for (args[2..]) |_| try resp.serializeBulkString(w, null);
            return;
        };
        defer key_ref.deinit(self.allocator);
        try resp.serializeArrayHeader(w, args.len - 2);
        for (args[2..]) |field| {
            try resp.serializeBulkString(w, self.getHashStore().hget(key_ref.key, field));
        }
    }

    fn cmdHkeys(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'HKEYS'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const keys = self.getHashStore().hkeys(key_ref.key, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (keys.len > 0) self.allocator.free(keys);
        try resp.serializeArrayHeader(w, keys.len);
        for (keys) |k| try resp.serializeBulkString(w, k);
    }

    fn cmdHvals(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'HVALS'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const vals = self.getHashStore().hvals(key_ref.key, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (vals.len > 0) self.allocator.free(vals);
        try resp.serializeArrayHeader(w, vals.len);
        for (vals) |v| try resp.serializeBulkString(w, v);
    }

    fn cmdHincrby(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "wrong number of arguments for 'HINCRBY'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        const delta = std.fmt.parseInt(i64, args[3], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        const result = self.getHashStore().hincrby(key_ref.key, args[2], delta) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        self.logToAOF(args);
        try resp.serializeInteger(w, result);
    }

    // ── Set Commands ───────────────────────────────────────────────────

    fn getSetStore(self: *CommandHandler) *SetStore {
        return self.set_store orelse @panic("set_store not initialized");
    }

    fn cmdSadd(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'SADD'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        const added = self.getSetStore().sadd(key_ref.key, args[2..]) catch { try resp.serializeError(w, "internal error"); return; };
        self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(added));
    }

    fn cmdSrem(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'SREM'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const removed = self.getSetStore().srem(key_ref.key, args[2..]);
        if (removed > 0) self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(removed));
    }

    fn cmdSismember(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'SISMEMBER'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeInteger(w, if (self.getSetStore().sismember(key_ref.key, args[2])) @as(i64, 1) else 0);
    }

    fn cmdScard(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'SCARD'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeInteger(w, @intCast(self.getSetStore().scard(key_ref.key)));
    }

    fn cmdSmembers(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'SMEMBERS'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const members = self.getSetStore().smembers(key_ref.key, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (members.len > 0) self.allocator.free(members);
        try resp.serializeArrayHeader(w, members.len);
        for (members) |m| try resp.serializeBulkString(w, m);
    }

    fn cmdSunion(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'SUNION'"); return; }
        // Namespace all keys
        var ns_keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (ns_keys.items) |k| self.allocator.free(@constCast(k));
            ns_keys.deinit();
        }
        for (args[1..]) |user_key| {
            const nk = namespacedKey(self, user_key) catch continue;
            ns_keys.append(nk) catch { self.allocator.free(nk); };
        }
        const result = self.getSetStore().sunion(ns_keys.items, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (result.len > 0) self.allocator.free(result);
        try resp.serializeArrayHeader(w, result.len);
        for (result) |m| try resp.serializeBulkString(w, m);
    }

    fn cmdSinter(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'SINTER'"); return; }
        var ns_keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (ns_keys.items) |k| self.allocator.free(@constCast(k));
            ns_keys.deinit();
        }
        for (args[1..]) |user_key| {
            const nk = namespacedKey(self, user_key) catch continue;
            ns_keys.append(nk) catch { self.allocator.free(nk); };
        }
        const result = self.getSetStore().sinter(ns_keys.items, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (result.len > 0) self.allocator.free(result);
        try resp.serializeArrayHeader(w, result.len);
        for (result) |m| try resp.serializeBulkString(w, m);
    }

    fn cmdSdiff(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'SDIFF'"); return; }
        var ns_keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (ns_keys.items) |k| self.allocator.free(@constCast(k));
            ns_keys.deinit();
        }
        for (args[1..]) |user_key| {
            const nk = namespacedKey(self, user_key) catch continue;
            ns_keys.append(nk) catch { self.allocator.free(nk); };
        }
        const result = self.getSetStore().sdiff(ns_keys.items, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (result.len > 0) self.allocator.free(result);
        try resp.serializeArrayHeader(w, result.len);
        for (result) |m| try resp.serializeBulkString(w, m);
    }

    // ── Sorted Set Commands ──────────────────────────────────────────

    fn getSortedSetStore(self: *CommandHandler) *SortedSetStore {
        return self.sorted_set_store orelse @panic("sorted_set_store not initialized");
    }

    fn cmdZadd(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4 or (args.len - 2) % 2 != 0) { try resp.serializeError(w, "wrong number of arguments for 'ZADD'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        const added = self.getSortedSetStore().zadd(key_ref.key, args[2..]) catch { try resp.serializeError(w, "internal error"); return; };
        self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(added));
    }

    fn cmdZrem(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'ZREM'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const removed = self.getSortedSetStore().zrem(key_ref.key, args[2..]);
        if (removed > 0) self.logToAOF(args);
        try resp.serializeInteger(w, @intCast(removed));
    }

    fn cmdZscore(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'ZSCORE'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeBulkString(w, null); return; };
        defer key_ref.deinit(self.allocator);
        if (self.getSortedSetStore().zscore(key_ref.key, args[2])) |score| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.6}", .{score}) catch { try resp.serializeBulkString(w, null); return; };
            try resp.serializeBulkString(w, s);
        } else {
            try resp.serializeBulkString(w, null);
        }
    }

    fn cmdZcard(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'ZCARD'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeInteger(w, @intCast(self.getSortedSetStore().zcard(key_ref.key)));
    }

    fn cmdZrank(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "wrong number of arguments for 'ZRANK'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeBulkString(w, null); return; };
        defer key_ref.deinit(self.allocator);
        const rank = self.getSortedSetStore().zrank(key_ref.key, args[2], self.allocator) catch { try resp.serializeBulkString(w, null); return; };
        if (rank) |r| {
            try resp.serializeInteger(w, @intCast(r));
        } else {
            try resp.serializeBulkString(w, null);
        }
    }

    fn cmdZrange(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "wrong number of arguments for 'ZRANGE'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const start = std.fmt.parseInt(i64, args[2], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        const stop = std.fmt.parseInt(i64, args[3], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        // Check for WITHSCORES flag
        var with_scores = false;
        if (args.len >= 5) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[4], &flag_buf);
            if (std.mem.eql(u8, flag, "WITHSCORES")) with_scores = true;
        }
        const entries = self.getSortedSetStore().zrange(key_ref.key, start, stop, self.allocator) catch { try resp.serializeArrayHeader(w, 0); return; };
        defer if (entries.len > 0) self.allocator.free(entries);
        if (with_scores) {
            try resp.serializeArrayHeader(w, entries.len * 2);
            for (entries) |e| {
                try resp.serializeBulkString(w, e.member);
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d:.6}", .{e.score}) catch "0";
                try resp.serializeBulkString(w, s);
            }
        } else {
            try resp.serializeArrayHeader(w, entries.len);
            for (entries) |e| try resp.serializeBulkString(w, e.member);
        }
    }

    fn cmdZincrby(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "wrong number of arguments for 'ZINCRBY'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeError(w, "internal error"); return; };
        defer key_ref.deinit(self.allocator);
        const delta = std.fmt.parseFloat(f64, args[2]) catch { try resp.serializeError(w, "value is not a valid float"); return; };
        const new_score = self.getSortedSetStore().zincrby(key_ref.key, delta, args[3]) catch { try resp.serializeError(w, "internal error"); return; };
        self.logToAOF(args);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.6}", .{new_score}) catch "0";
        try resp.serializeBulkString(w, s);
    }

    fn cmdZcount(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "wrong number of arguments for 'ZCOUNT'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeInteger(w, 0); return; };
        defer key_ref.deinit(self.allocator);
        const min = std.fmt.parseFloat(f64, args[2]) catch { try resp.serializeError(w, "min is not a float"); return; };
        const max = std.fmt.parseFloat(f64, args[3]) catch { try resp.serializeError(w, "max is not a float"); return; };
        try resp.serializeInteger(w, @intCast(self.getSortedSetStore().zcount(key_ref.key, min, max)));
    }

    /// RANDOMKEY — return a random key from the current DB
    fn cmdRandomKey(self: *CommandHandler, w: *std.Io.Writer) !void {
        var it = self.kv.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
            if (stripDbPrefix(self, entry.key_ptr.*)) |user_key| {
                try resp.serializeBulkString(w, user_key);
                return;
            }
        }
        try resp.serializeBulkString(w, null);
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

        // Cluster section (if available)
        try aw.writer.writeAll("\r\n# Cluster\r\n");
        try aw.writer.print("graph_mutation_seq:{d}\r\n", .{self.graph.mutation_seq});

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

    // ── Vector Commands ────────────────────────────────────────────────

    fn cmdGraphSetVec(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "usage: GRAPH.SETVEC <key> <field> <f32_bytes>"); return; }
        const nk = graphNamespacedKey(self, args[1]) catch { try resp.serializeError(w, "internal error"); return; };
        defer self.allocator.free(nk);
        const raw = args[3];
        if (raw.len == 0 or raw.len % 4 != 0) { try resp.serializeError(w, "vector bytes must be non-empty and multiple of 4"); return; }
        const dim = raw.len / 4;
        const aligned = self.allocator.alloc(f32, dim) catch { try resp.serializeError(w, "out of memory"); return; };
        defer self.allocator.free(aligned);
        @memcpy(std.mem.sliceAsBytes(aligned), raw);
        self.graph.setVector(nk, args[2], aligned) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    fn cmdGraphGetVec(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "usage: GRAPH.GETVEC <key> <field>"); return; }
        const nk = graphNamespacedKey(self, args[1]) catch { try resp.serializeError(w, "internal error"); return; };
        defer self.allocator.free(nk);
        const vec = self.graph.getVector(nk, args[2]) orelse { try resp.serializeBulkString(w, null); return; };
        try resp.serializeBulkString(w, std.mem.sliceAsBytes(vec));
    }

    fn cmdGraphVecSearch(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 5) { try resp.serializeError(w, "usage: GRAPH.VECSEARCH <field> <query> K <n>"); return; }
        const field = args[1];
        const raw_query = args[2];
        if (raw_query.len == 0 or raw_query.len % 4 != 0) { try resp.serializeError(w, "query bytes must be multiple of 4"); return; }
        const k_str = if (args[3].len == 1 and (args[3][0] == 'K' or args[3][0] == 'k')) args[4] else args[3];
        const k = std.fmt.parseInt(u32, k_str, 10) catch { try resp.serializeError(w, "K must be integer"); return; };
        const dim = raw_query.len / 4;
        const qa = self.allocator.alloc(f32, dim) catch { try resp.serializeError(w, "out of memory"); return; };
        defer self.allocator.free(qa);
        @memcpy(std.mem.sliceAsBytes(qa), raw_query);
        const vi = self.graph.vec_indices orelse { try resp.serializeError(w, "no vector index for field"); return; };
        const idx = vi.get(field) orelse { try resp.serializeError(w, "no vector index for field"); return; };
        @import("../engine/vector_store.zig").VectorStore.normalize(qa);
        const results = idx.search(qa, k, &self.graph.node_alive) catch { try resp.serializeError(w, "search failed"); return; };
        defer self.allocator.free(results);
        try resp.serializeArrayHeader(w, results.len * 2);
        for (results) |r| {
            const node = self.graph.getNodeById(r.node_id);
            if (node) |n| { try resp.serializeBulkString(w, stripGraphDbPrefix(self, n.key) orelse n.key); } else { try resp.serializeBulkString(w, null); }
            var sb: [32]u8 = undefined;
            try resp.serializeBulkString(w, std.fmt.bufPrint(&sb, "{d:.4}", .{1.0 - r.distance}) catch "0");
        }
    }

    fn cmdGraphRag(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        const rag_mod = @import("../engine/rag.zig");
        if (args.len < 5) { try resp.serializeError(w, "usage: GRAPH.RAG <field> <query> K <n> [DEPTH d] [DIR d]"); return; }
        const field = args[1];
        const raw_query = args[2];
        if (raw_query.len == 0 or raw_query.len % 4 != 0) { try resp.serializeError(w, "query bytes must be multiple of 4"); return; }
        const k_idx: usize = if (args[3].len == 1 and (args[3][0] == 'K' or args[3][0] == 'k')) 4 else 3;
        const k = std.fmt.parseInt(u32, if (k_idx < args.len) args[k_idx] else "5", 10) catch 5;
        var opts = rag_mod.RagOptions{};
        var i: usize = k_idx + 1;
        while (i < args.len) {
            var fb: [64]u8 = undefined;
            const flag = toUpper(args[i], &fb);
            if (std.mem.eql(u8, flag, "DEPTH") and i + 1 < args.len) { opts.depth = std.fmt.parseInt(u32, args[i + 1], 10) catch 1; i += 2; } else if (std.mem.eql(u8, flag, "DIR") and i + 1 < args.len) { var db: [64]u8 = undefined; const d = toUpper(args[i + 1], &db); if (std.mem.eql(u8, d, "IN")) { opts.direction = .incoming; } else if (std.mem.eql(u8, d, "BOTH")) { opts.direction = .both; } i += 2; } else if (std.mem.eql(u8, flag, "EDGETYPE") and i + 1 < args.len) { opts.edge_type_filter = args[i + 1]; i += 2; } else if (std.mem.eql(u8, flag, "NODETYPE") and i + 1 < args.len) { opts.node_type_filter = args[i + 1]; i += 2; } else { i += 1; }
        }
        const dim = raw_query.len / 4;
        const qa = self.allocator.alloc(f32, dim) catch { try resp.serializeError(w, "out of memory"); return; };
        defer self.allocator.free(qa);
        @memcpy(std.mem.sliceAsBytes(qa), raw_query);
        const results = rag_mod.ragSearch(self.graph, self.allocator, field, qa, k, opts) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        defer { for (results) |*r| { var rm = r.*; rm.deinit(self.allocator); } self.allocator.free(results); }
        try resp.serializeArrayHeader(w, results.len);
        for (results) |r| {
            try resp.serializeArrayHeader(w, 4);
            try resp.serializeBulkString(w, stripGraphDbPrefix(self, r.key) orelse r.key);
            var sb: [32]u8 = undefined;
            try resp.serializeBulkString(w, std.fmt.bufPrint(&sb, "{d:.4}", .{r.score}) catch "0");
            try resp.serializeArrayHeader(w, r.props.len * 2);
            for (r.props) |p| { try resp.serializeBulkString(w, p.key); try resp.serializeBulkString(w, p.value); }
            try resp.serializeArrayHeader(w, r.neighbor_keys.len);
            for (r.neighbor_keys) |nk| { try resp.serializeBulkString(w, stripGraphDbPrefix(self, nk) orelse nk); }
        }
    }

    // ── Upsert / Ingest / List / Impact / Paths Commands ──────────────

    /// GRAPH.UPSERT_NODE <key> <type> [json_metadata]
    fn cmdGraphUpsertNode(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "usage: GRAPH.UPSERT_NODE <key> <type> [json_metadata]"); return; }
        const nk = graphNamespacedKey(self, args[1]) catch { try resp.serializeError(w, "internal error"); return; };
        defer self.allocator.free(nk);
        _ = self.graph.upsertNode(nk, args[2]) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        // Parse and set metadata if provided
        if (args.len >= 4) {
            self.applyJsonMetadataToNode(nk, args[3]) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        }
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.UPSERT_EDGE <from> <to> <type> [json_metadata]
    fn cmdGraphUpsertEdge(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 4) { try resp.serializeError(w, "usage: GRAPH.UPSERT_EDGE <from> <to> <type> [json_metadata]"); return; }
        const from = graphNamespacedKey(self, args[1]) catch { try resp.serializeError(w, "internal error"); return; };
        defer self.allocator.free(from);
        const to = graphNamespacedKey(self, args[2]) catch { try resp.serializeError(w, "internal error"); return; };
        defer self.allocator.free(to);
        // Create nodes if they don't exist (upsert semantics)
        _ = self.graph.upsertNode(from, "unknown") catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        _ = self.graph.upsertNode(to, "unknown") catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        // Find existing edge or create new
        const eid = self.graph.findEdge(from, to, args[3]) orelse blk: {
            break :blk self.graph.addEdge(from, to, args[3], 1.0) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        };
        // Apply metadata if provided
        if (args.len >= 5) {
            self.applyJsonMetadataToEdge(eid, args[4]) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        }
        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.INGEST <json>
    fn cmdGraphIngest(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "usage: GRAPH.INGEST <json>"); return; }
        const json_str = args[1];
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{}) catch {
            try resp.serializeError(w, "invalid JSON");
            return;
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) { try resp.serializeError(w, "JSON must be an object with 'nodes' and/or 'edges'"); return; }

        // Process nodes
        if (root.object.get("nodes")) |nodes_val| {
            if (nodes_val == .array) {
                for (nodes_val.array.items) |node_val| {
                    if (node_val != .object) continue;
                    const obj = node_val.object;
                    const id_str = if (obj.get("id")) |v| (if (v == .string) v.string else null) else null;
                    const type_str = if (obj.get("type")) |v| (if (v == .string) v.string else null) else null;
                    if (id_str == null or type_str == null) continue;
                    const nk = graphNamespacedKey(self, id_str.?) catch continue;
                    defer self.allocator.free(nk);
                    _ = self.graph.upsertNode(nk, type_str.?) catch continue;
                    // Apply metadata
                    if (obj.get("metadata")) |meta_val| {
                        if (meta_val == .object) {
                            var meta_iter = meta_val.object.iterator();
                            while (meta_iter.next()) |entry| {
                                const val_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                                self.graph.setNodeProperty(nk, entry.key_ptr.*, val_str) catch continue;
                            }
                        }
                    }
                }
            }
        }

        // Process edges
        if (root.object.get("edges")) |edges_val| {
            if (edges_val == .array) {
                for (edges_val.array.items) |edge_val| {
                    if (edge_val != .object) continue;
                    const obj = edge_val.object;
                    const from_str = if (obj.get("from")) |v| (if (v == .string) v.string else null) else null;
                    const to_str = if (obj.get("to")) |v| (if (v == .string) v.string else null) else null;
                    const etype_str = if (obj.get("type")) |v| (if (v == .string) v.string else null) else null;
                    if (from_str == null or to_str == null or etype_str == null) continue;
                    const from = graphNamespacedKey(self, from_str.?) catch continue;
                    defer self.allocator.free(from);
                    const to = graphNamespacedKey(self, to_str.?) catch continue;
                    defer self.allocator.free(to);
                    // Ensure nodes exist
                    _ = self.graph.upsertNode(from, "unknown") catch continue;
                    _ = self.graph.upsertNode(to, "unknown") catch continue;
                    // Upsert edge
                    const eid = self.graph.findEdge(from, to, etype_str.?) orelse (self.graph.addEdge(from, to, etype_str.?, 1.0) catch continue);
                    // Apply edge metadata
                    if (obj.get("metadata")) |meta_val| {
                        if (meta_val == .object) {
                            var meta_iter = meta_val.object.iterator();
                            while (meta_iter.next()) |entry| {
                                const val_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                                self.graph.setEdgeProperty(eid, entry.key_ptr.*, val_str) catch continue;
                            }
                        }
                    }
                }
            }
        }

        self.logToAOF(args);
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.LIST_BY_TYPE <type> [LIMIT n]
    fn cmdGraphListByType(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "usage: GRAPH.LIST_BY_TYPE <type> [LIMIT n]"); return; }
        const node_type = args[1];
        var limit: u32 = 0;
        var i: usize = 2;
        while (i < args.len) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[i], &flag_buf);
            if (std.mem.eql(u8, flag, "LIMIT") and i + 1 < args.len) {
                limit = std.fmt.parseInt(u32, args[i + 1], 10) catch 0;
                i += 2;
            } else { i += 1; }
        }
        // listByType uses interned type name — graph engine compares type_ids directly
        // But we need to find the type in the intern table. The type is NOT namespaced.
        const ids = self.graph.listByType(node_type, limit) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        defer self.allocator.free(ids);
        try resp.serializeArrayHeader(w, ids.len);
        for (ids) |nid| {
            const node = self.graph.getNodeById(nid);
            if (node) |n| {
                try resp.serializeArrayHeader(w, 2);
                try resp.serializeBulkString(w, stripGraphDbPrefix(self, n.key) orelse n.key);
                try resp.serializeBulkString(w, n.node_type);
            }
        }
    }

    /// GRAPH.IMPACT <id> [EDGES e1 e2 ...] [NODES n1 n2 ...] [DEPTH n]
    fn cmdGraphImpact(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "usage: GRAPH.IMPACT <id> [EDGES e1 ...] [NODES n1 ...] [DEPTH n]"); return; }
        const nk = graphNamespacedKey(self, args[1]) catch { try resp.serializeError(w, "internal error"); return; };
        defer self.allocator.free(nk);

        var opts = query.ImpactOptions{};
        var edge_filters_buf: [32][]const u8 = undefined;
        var edge_filters_len: usize = 0;
        var node_filters_buf: [32][]const u8 = undefined;
        var node_filters_len: usize = 0;

        var i: usize = 2;
        while (i < args.len) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[i], &flag_buf);
            if (std.mem.eql(u8, flag, "DEPTH") and i + 1 < args.len) {
                opts.max_depth = std.fmt.parseInt(u32, args[i + 1], 10) catch 10;
                i += 2;
            } else if (std.mem.eql(u8, flag, "EDGES")) {
                i += 1;
                while (i < args.len) {
                    var check_buf: [64]u8 = undefined;
                    const check = toUpper(args[i], &check_buf);
                    if (std.mem.eql(u8, check, "NODES") or std.mem.eql(u8, check, "DEPTH")) break;
                    if (edge_filters_len < 32) { edge_filters_buf[edge_filters_len] = args[i]; edge_filters_len += 1; }
                    i += 1;
                }
            } else if (std.mem.eql(u8, flag, "NODES")) {
                i += 1;
                while (i < args.len) {
                    var check_buf: [64]u8 = undefined;
                    const check = toUpper(args[i], &check_buf);
                    if (std.mem.eql(u8, check, "EDGES") or std.mem.eql(u8, check, "DEPTH")) break;
                    if (node_filters_len < 32) { node_filters_buf[node_filters_len] = args[i]; node_filters_len += 1; }
                    i += 1;
                }
            } else { i += 1; }
        }
        if (edge_filters_len > 0) opts.edge_type_filters = edge_filters_buf[0..edge_filters_len];
        if (node_filters_len > 0) opts.node_type_filters = node_filters_buf[0..node_filters_len];

        const results = query.impact(self.graph, self.allocator, nk, opts) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        defer self.allocator.free(results);

        // Serialize as flat array: [type_name, count, type_name, count, ...]
        try resp.serializeArrayHeader(w, results.len * 2);
        for (results) |r| {
            try resp.serializeBulkString(w, r.type_name);
            try resp.serializeInteger(w, @intCast(r.count));
        }
    }

    /// GRAPH.PATHS <start> <target_type> [EDGES e1 e2 ...] [LIMIT n] [DEPTH n]
    fn cmdGraphPaths(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 3) { try resp.serializeError(w, "usage: GRAPH.PATHS <start> <target_type> [EDGES ...] [LIMIT n] [DEPTH n]"); return; }
        const nk = graphNamespacedKey(self, args[1]) catch { try resp.serializeError(w, "internal error"); return; };
        defer self.allocator.free(nk);
        const target_type = args[2];

        var opts = query.FindPathsOptions{};
        var edge_filters_buf: [32][]const u8 = undefined;
        var edge_filters_len: usize = 0;

        var i: usize = 3;
        while (i < args.len) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[i], &flag_buf);
            if (std.mem.eql(u8, flag, "DEPTH") and i + 1 < args.len) {
                opts.max_depth = std.fmt.parseInt(u32, args[i + 1], 10) catch 10;
                i += 2;
            } else if (std.mem.eql(u8, flag, "LIMIT") and i + 1 < args.len) {
                opts.limit = std.fmt.parseInt(u32, args[i + 1], 10) catch 100;
                i += 2;
            } else if (std.mem.eql(u8, flag, "EDGES")) {
                i += 1;
                while (i < args.len) {
                    var check_buf: [64]u8 = undefined;
                    const check = toUpper(args[i], &check_buf);
                    if (std.mem.eql(u8, check, "LIMIT") or std.mem.eql(u8, check, "DEPTH")) break;
                    if (edge_filters_len < 32) { edge_filters_buf[edge_filters_len] = args[i]; edge_filters_len += 1; }
                    i += 1;
                }
            } else { i += 1; }
        }
        if (edge_filters_len > 0) opts.edge_type_filters = edge_filters_buf[0..edge_filters_len];

        const paths = query.findPaths(self.graph, self.allocator, nk, target_type, opts) catch |err| { try resp.serializeError(w, @errorName(err)); return; };
        defer {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }

        try resp.serializeArrayHeader(w, paths.len);
        for (paths) |path| {
            try resp.serializeArrayHeader(w, path.len);
            for (path) |nid| {
                const node = self.graph.getNodeById(nid);
                if (node) |n| {
                    try resp.serializeArrayHeader(w, 2);
                    try resp.serializeBulkString(w, stripGraphDbPrefix(self, n.key) orelse n.key);
                    try resp.serializeBulkString(w, n.node_type);
                } else {
                    try resp.serializeArrayHeader(w, 2);
                    try resp.serializeBulkString(w, null);
                    try resp.serializeBulkString(w, null);
                }
            }
        }
    }

    // ── JSON metadata helper ────────────────────────────────────────────

    fn applyJsonMetadataToNode(self: *CommandHandler, key: []const u8, json_str: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{}) catch return error.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJSON;
        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const val_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
            try self.graph.setNodeProperty(key, entry.key_ptr.*, val_str);
        }
    }

    fn applyJsonMetadataToEdge(self: *CommandHandler, eid: graph_mod.EdgeId, json_str: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{}) catch return error.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJSON;
        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const val_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
            try self.graph.setEdgeProperty(eid, entry.key_ptr.*, val_str);
        }
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
        // Save vector files
        if (self.data_dir) |dd| {
            self.graph.saveVectors(dd) catch {};
        }
        a.last_save_time = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        try resp.serializeSimpleString(w, "OK");
    }

    /// BGSAVE -- background snapshot in a separate thread
    fn cmdBgSave(self: *CommandHandler, w: *std.Io.Writer) !void {
        const a = self.aof orelse {
            try resp.serializeError(w, "persistence not configured");
            return;
        };
        // Check if a BGSAVE is already in progress
        if (bgsave_in_progress.load(.acquire)) {
            try resp.serializeError(w, "Background save already in progress");
            return;
        }
        // Set the flag atomically
        if (bgsave_in_progress.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            try resp.serializeError(w, "Background save already in progress");
            return;
        }

        const BgSaveCtx = struct {
            io: std.Io,
            allocator: Allocator,
            kv: *KVStore,
            graph: *GraphEngine,
            snapshot_path: []const u8,
            aof_ptr: *AOF,
            graph_rwlock: ?*std.c.pthread_rwlock_t,
            data_dir: ?[]const u8,

            fn run(ctx: *@This()) void {
                defer {
                    bgsave_in_progress.store(false, .release);
                    ctx.allocator.destroy(ctx);
                }
                if (ctx.graph_rwlock) |rwl| {
                    _ = std.c.pthread_rwlock_rdlock(rwl);
                }
                defer if (ctx.graph_rwlock) |rwl| {
                    _ = std.c.pthread_rwlock_unlock(rwl);
                };

                snapshot.save(ctx.io, ctx.allocator, ctx.kv, ctx.graph, ctx.snapshot_path) catch return;
                ctx.aof_ptr.truncate() catch {};
                if (ctx.data_dir) |dd| {
                    ctx.graph.saveVectors(dd) catch {};
                }
                ctx.aof_ptr.last_save_time = std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();
            }
        };

        const ctx = self.allocator.create(BgSaveCtx) catch {
            bgsave_in_progress.store(false, .release);
            try resp.serializeError(w, "out of memory");
            return;
        };
        ctx.* = .{
            .io = self.io,
            .allocator = self.allocator,
            .kv = self.kv,
            .graph = self.graph,
            .snapshot_path = a.snapshot_path,
            .aof_ptr = a,
            .graph_rwlock = self.graph_rwlock,
            .data_dir = self.data_dir,
        };

        const t = std.Thread.spawn(.{}, BgSaveCtx.run, .{ctx}) catch {
            bgsave_in_progress.store(false, .release);
            self.allocator.destroy(ctx);
            try resp.serializeError(w, "failed to spawn background save thread");
            return;
        };
        t.detach();
        try resp.serializeSimpleString(w, "Background saving started");
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

test "BGSAVE without persistence returns error" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    const bgsave = [_][]const u8{"BGSAVE"};
    const r = try testExec(&handler, allocator, &bgsave);
    defer allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "-ERR") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "persistence") != null);
}

test "ECHO and TYPE" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // ECHO
    const echo = [_][]const u8{ "ECHO", "hello" };
    const r1 = try testExec(&handler, allocator, &echo);
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("$5\r\nhello\r\n", r1);

    // TYPE on missing key
    const type_miss = [_][]const u8{ "TYPE", "nokey" };
    const r2 = try testExec(&handler, allocator, &type_miss);
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("+none\r\n", r2);

    // TYPE on existing key
    const set = [_][]const u8{ "SET", "k1", "v1" };
    const rs = try testExec(&handler, allocator, &set);
    defer allocator.free(rs);
    const type_hit = [_][]const u8{ "TYPE", "k1" };
    const r3 = try testExec(&handler, allocator, &type_hit);
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("+string\r\n", r3);
}

test "STRLEN" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // Missing key → 0
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "STRLEN", "nokey" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(":0\r\n", r1);

    // Set and check
    const rs = try testExec(&handler, allocator, &[_][]const u8{ "SET", "k", "hello" });
    defer allocator.free(rs);
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "STRLEN", "k" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(":5\r\n", r2);
}

test "SETNX and SET NX/XX" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // SETNX on new key → 1
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "SETNX", "lock", "holder1" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(":1\r\n", r1);

    // SETNX on existing key → 0
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "SETNX", "lock", "holder2" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(":0\r\n", r2);

    // SET key value NX — should fail (key exists)
    const r3 = try testExec(&handler, allocator, &[_][]const u8{ "SET", "lock", "new", "NX" });
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("$-1\r\n", r3);

    // SET key value XX — should succeed (key exists)
    const r4 = try testExec(&handler, allocator, &[_][]const u8{ "SET", "lock", "updated", "XX" });
    defer allocator.free(r4);
    try std.testing.expectEqualStrings("+OK\r\n", r4);

    // SET key value XX on missing key — should fail
    const r5 = try testExec(&handler, allocator, &[_][]const u8{ "SET", "nokey", "val", "XX" });
    defer allocator.free(r5);
    try std.testing.expectEqualStrings("$-1\r\n", r5);
}

test "GETSET and GETDEL" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // SET initial
    const rs = try testExec(&handler, allocator, &[_][]const u8{ "SET", "k", "old" });
    defer allocator.free(rs);

    // GETSET → returns old, sets new
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "GETSET", "k", "new" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("$3\r\nold\r\n", r1);

    // Verify new value
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "GET", "k" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("$3\r\nnew\r\n", r2);

    // GETDEL → returns value and deletes
    const r3 = try testExec(&handler, allocator, &[_][]const u8{ "GETDEL", "k" });
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("$3\r\nnew\r\n", r3);

    // Key should be gone
    const r4 = try testExec(&handler, allocator, &[_][]const u8{ "GET", "k" });
    defer allocator.free(r4);
    try std.testing.expectEqualStrings("$-1\r\n", r4);
}

test "RENAME and RENAMENX" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    const rs = try testExec(&handler, allocator, &[_][]const u8{ "SET", "src", "val" });
    defer allocator.free(rs);

    // RENAME
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "RENAME", "src", "dst" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("+OK\r\n", r1);

    // Old key gone
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "GET", "src" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("$-1\r\n", r2);

    // New key exists
    const r3 = try testExec(&handler, allocator, &[_][]const u8{ "GET", "dst" });
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("$3\r\nval\r\n", r3);

    // RENAMENX — dst exists, should fail
    const rs2 = try testExec(&handler, allocator, &[_][]const u8{ "SET", "other", "x" });
    defer allocator.free(rs2);
    const r4 = try testExec(&handler, allocator, &[_][]const u8{ "RENAMENX", "other", "dst" });
    defer allocator.free(r4);
    try std.testing.expectEqualStrings(":0\r\n", r4);

    // RENAMENX to new name — should succeed
    const r5 = try testExec(&handler, allocator, &[_][]const u8{ "RENAMENX", "other", "newname" });
    defer allocator.free(r5);
    try std.testing.expectEqualStrings(":1\r\n", r5);
}

test "PTTL and PEXPIRE" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    const rs = try testExec(&handler, allocator, &[_][]const u8{ "SET", "k", "v" });
    defer allocator.free(rs);

    // PTTL without expiry → -1
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "PTTL", "k" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(":-1\r\n", r1);

    // PEXPIRE 60000 (60 seconds in ms)
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "PEXPIRE", "k", "60000" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(":1\r\n", r2);

    // PTTL now > 0
    const r3 = try testExec(&handler, allocator, &[_][]const u8{ "PTTL", "k" });
    defer allocator.free(r3);
    try std.testing.expect(r3[0] == ':');
    try std.testing.expect(r3[1] != '-');

    // PTTL on missing key → -2
    const r4 = try testExec(&handler, allocator, &[_][]const u8{ "PTTL", "nokey" });
    defer allocator.free(r4);
    try std.testing.expectEqualStrings(":-2\r\n", r4);
}

test "SETEX" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // SETEX key seconds value
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "SETEX", "sess", "3600", "data" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("+OK\r\n", r1);

    // Key exists with value
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "GET", "sess" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("$4\r\ndata\r\n", r2);

    // Has TTL
    const r3 = try testExec(&handler, allocator, &[_][]const u8{ "TTL", "sess" });
    defer allocator.free(r3);
    try std.testing.expect(r3[0] == ':');
    try std.testing.expect(r3[1] != '-');
}

test "LPUSH/RPUSH/LRANGE/LPOP/RPOP" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var ls = ListStore.init(allocator);
    defer ls.deinit();
    var hs = HashStore.init(allocator);
    defer hs.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);
    handler.list_store = &ls;
    handler.hash_store = &hs;

    // RPUSH
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "RPUSH", "mylist", "a", "b", "c" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(":3\r\n", r1);

    // LPUSH
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "LPUSH", "mylist", "z" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings(":4\r\n", r2);

    // LRANGE 0 -1
    const r3 = try testExec(&handler, allocator, &[_][]const u8{ "LRANGE", "mylist", "0", "-1" });
    defer allocator.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "*4\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "z") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "a") != null);

    // LPOP
    const r4 = try testExec(&handler, allocator, &[_][]const u8{ "LPOP", "mylist" });
    defer allocator.free(r4);
    try std.testing.expectEqualStrings("$1\r\nz\r\n", r4);

    // RPOP
    const r5 = try testExec(&handler, allocator, &[_][]const u8{ "RPOP", "mylist" });
    defer allocator.free(r5);
    try std.testing.expectEqualStrings("$1\r\nc\r\n", r5);

    // LLEN
    const r6 = try testExec(&handler, allocator, &[_][]const u8{ "LLEN", "mylist" });
    defer allocator.free(r6);
    try std.testing.expectEqualStrings(":2\r\n", r6);
}

test "HSET/HGET/HGETALL/HDEL/HINCRBY" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var ls = ListStore.init(allocator);
    defer ls.deinit();
    var hs = HashStore.init(allocator);
    defer hs.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);
    handler.list_store = &ls;
    handler.hash_store = &hs;

    // HSET
    const r1 = try testExec(&handler, allocator, &[_][]const u8{ "HSET", "u", "name", "Bob", "age", "25" });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(":2\r\n", r1);

    // HGET
    const r2 = try testExec(&handler, allocator, &[_][]const u8{ "HGET", "u", "name" });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("$3\r\nBob\r\n", r2);

    // HGETALL
    const r3 = try testExec(&handler, allocator, &[_][]const u8{ "HGETALL", "u" });
    defer allocator.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "*4\r\n") != null);

    // HLEN
    const r4 = try testExec(&handler, allocator, &[_][]const u8{ "HLEN", "u" });
    defer allocator.free(r4);
    try std.testing.expectEqualStrings(":2\r\n", r4);

    // HINCRBY
    const r5 = try testExec(&handler, allocator, &[_][]const u8{ "HINCRBY", "u", "visits", "5" });
    defer allocator.free(r5);
    try std.testing.expectEqualStrings(":5\r\n", r5);

    // HDEL
    const r6 = try testExec(&handler, allocator, &[_][]const u8{ "HDEL", "u", "age" });
    defer allocator.free(r6);
    try std.testing.expectEqualStrings(":1\r\n", r6);

    // HMGET
    const r7 = try testExec(&handler, allocator, &[_][]const u8{ "HMGET", "u", "name", "age", "visits" });
    defer allocator.free(r7);
    try std.testing.expect(std.mem.indexOf(u8, r7, "*3\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r7, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, r7, "$-1\r\n") != null); // age deleted
}

test "bgsave_in_progress flag" {
    // Verify the atomic flag prevents concurrent saves
    try std.testing.expect(!bgsave_in_progress.load(.acquire));
    bgsave_in_progress.store(true, .release);
    try std.testing.expect(bgsave_in_progress.load(.acquire));
    bgsave_in_progress.store(false, .release);
    try std.testing.expect(!bgsave_in_progress.load(.acquire));
}
