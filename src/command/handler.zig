const std = @import("std");
const Allocator = std.mem.Allocator;
const vex_root = @import("../root.zig");
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
const obs_stats = @import("../observability/stats.zig");
const obs_cmd_table = @import("../observability/cmd_table.zig");
const event_stats = @import("../observability/event_stats.zig");
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
pub var bgrewriteaof_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub const ConcurrentKV = @import("../engine/concurrent_kv.zig").ConcurrentKV;

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
    /// RESP protocol version for this connection (2 or 3)
    protocol_version: resp.ProtocolVersion = .resp2,
    /// ConcurrentKV for reactor mode — when set, KV ops route through CKV instead of plain KVStore
    ckv: ?*ConcurrentKV = null,
    /// Stashed OwnedValue from last kvGet — freed on next kvGet or cleanup
    last_owned_get: ?ConcurrentKV.OwnedValue = null,
    /// Global per-process command lock. Set by production callers (Worker,
    /// reactor accept loop) so BGSAVE / BGREWRITEAOF can take it briefly
    /// to snapshot kv.map. Tests / single-threaded callers leave it null.
    kv_mutex: ?*std.atomic.Mutex = null,

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

    // ── CKV-aware KV helpers (dispatch to ConcurrentKV in reactor mode) ──

    fn kvGet(self: *CommandHandler, key: []const u8) ?[]const u8 {
        // Free previous CKV get result
        if (self.last_owned_get) |prev| prev.deinit();
        self.last_owned_get = null;

        if (self.ckv) |ckv| {
            const owned = ckv.get(key) orelse return null;
            self.last_owned_get = owned;
            return owned.data;
        }
        return self.kv.get(key);
    }

    pub fn kvGetCleanup(self: *CommandHandler) void {
        if (self.last_owned_get) |prev| prev.deinit();
        self.last_owned_get = null;
    }

    fn kvSet(self: *CommandHandler, key: []const u8, value: []const u8) !void {
        if (self.ckv) |ckv| return ckv.setInternal(key, value, 0);
        return self.kv.set(key, value);
    }

    fn kvSetEx(self: *CommandHandler, key: []const u8, value: []const u8, ttl_seconds: i64) !void {
        if (self.ckv) |ckv| return ckv.setEx(key, value, ttl_seconds);
        return self.kv.setEx(key, value, ttl_seconds);
    }

    fn kvSetPx(self: *CommandHandler, key: []const u8, value: []const u8, ttl_millis: i64) !void {
        if (self.ckv) |ckv| return ckv.setPx(key, value, ttl_millis);
        return self.kv.setPx(key, value, ttl_millis);
    }

    fn kvDelete(self: *CommandHandler, key: []const u8) bool {
        if (self.ckv) |ckv| return ckv.delete(key);
        return self.kv.delete(key);
    }

    fn kvExists(self: *CommandHandler, key: []const u8) bool {
        if (self.ckv) |ckv| return ckv.exists(key);
        return self.kv.exists(key);
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
                    if (std.mem.eql(u8, cmd, "HELLO")) return self.cmdHello(args, w);
                    if (std.mem.eql(u8, cmd, "HMSET")) return self.cmdHmset(args, w);
                    if (std.mem.eql(u8, cmd, "HMGET")) return self.cmdHmget(args, w);
                    if (std.mem.eql(u8, cmd, "HKEYS")) return self.cmdHkeys(args, w);
                    if (std.mem.eql(u8, cmd, "HVALS")) return self.cmdHvals(args, w);
                },
                'Z' => {
                    if (std.mem.eql(u8, cmd, "ZCARD")) return self.cmdZcard(args, w);
                    if (std.mem.eql(u8, cmd, "ZRANK")) return self.cmdZrank(args, w);
                },
                'D' => if (std.mem.eql(u8, cmd, "DEBUG")) return self.cmdDebug(args, w),
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
                'M' => if (std.mem.eql(u8, cmd, "MEMORY")) return self.cmdMemory(args, w),
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
                'S' => if (std.mem.eql(u8, cmd, "SLOWLOG")) return self.cmdSlowlog(args, w),
                'L' => if (std.mem.eql(u8, cmd, "LATENCY")) return self.cmdLatency(args, w),
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

        // ── Admin commands (VEX.*) — cluster + operational tooling ────
        if (cmd.len >= 4 and std.mem.eql(u8, cmd[0..4], "VEX.")) {
            const sub = cmd[4..];
            if (std.mem.eql(u8, sub, "PROMOTE")) return self.cmdVexPromote(args, w);
            if (std.mem.eql(u8, sub, "STATUS")) return self.cmdVexStatus(w);
            try resp.serializeError(w, "unknown VEX subcommand");
            return;
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
                'C' => {
                    if (std.mem.eql(u8, sub, "COMPACT")) return self.cmdGraphCompact(w);
                    if (std.mem.eql(u8, sub, "CHBUILD")) return self.cmdGraphCHBuild(w);
                    if (std.mem.eql(u8, sub, "CHSTATS")) return self.cmdGraphCHStats(w);
                },
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
        if (nx and self.kvExists(key_ref.key)) {
            try resp.serializeNullValue(w, self.protocol_version);
            return;
        }
        // XX: only set if key DOES exist
        if (xx and !self.kvExists(key_ref.key)) {
            try resp.serializeNullValue(w, self.protocol_version);
            return;
        }

        if (ttl_sec) |t| {
            self.kvSetEx(key_ref.key, args[2], t) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        } else if (ttl_ms) |t| {
            self.kvSetPx(key_ref.key, args[2], t) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        } else {
            self.kvSet(key_ref.key, args[2]) catch {
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
        const val = self.kvGet(key_ref.key);
        try resp.serializeBulkStringProto(w, val, self.protocol_version);
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
            if (self.kvDelete(key_ref.key)) count += 1;
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
            if (self.kvExists(key_ref.key)) count += 1;
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
            _ = self.kvDelete(k);
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
                _ = self.kvDelete(src);
                try resp.serializeInteger(w, 0);
                return;
            }
            self.kvSetPx(dst, src_entry.value, remaining) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        } else {
            self.kvSet(dst, src_entry.value) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        }
        _ = self.kvDelete(src);
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
                try resp.serializeNullValue(w, self.protocol_version);
                continue;
            };
            defer key_ref.deinit(self.allocator);
            if (self.kvGet(key_ref.key)) |val| {
                try resp.serializeBulkString(w, val);
            } else {
                try resp.serializeNullValue(w, self.protocol_version);
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
            self.kvSet(key_ref.key, args[i + 1]) catch continue;
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
        if (self.kvGet(key_ref.key)) |val| {
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
        self.kvSet(key_ref.key, val_str) catch {
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
        if (self.kvGet(key_ref.key)) |val| {
            self.kvSetEx(key_ref.key, val, ttl_seconds) catch {
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
        if (self.kvGet(key_ref.key)) |val| {
            self.kvSet(key_ref.key, val) catch {
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

        if (self.kvGet(key_ref.key)) |existing| {
            // Concatenate existing + new
            const new_len = existing.len + args[2].len;
            const new_val = self.allocator.alloc(u8, new_len) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
            defer self.allocator.free(new_val);
            @memcpy(new_val[0..existing.len], existing);
            @memcpy(new_val[existing.len..], args[2]);
            self.kvSet(key_ref.key, new_val) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
            self.logToAOF(args);
            try resp.serializeInteger(w, @intCast(new_len));
        } else {
            // Key doesn't exist — create with just the append value
            self.kvSet(key_ref.key, args[2]) catch {
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
        if (self.kvExists(key_ref.key)) {
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
        if (self.kvGet(key_ref.key)) |val| {
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
        if (self.kvExists(key_ref.key)) {
            try resp.serializeInteger(w, 0);
        } else {
            self.kvSet(key_ref.key, args[2]) catch {
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
        self.kvSetEx(key_ref.key, args[3], ttl) catch {
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
        const old = self.kvGet(key_ref.key);
        // Must copy old value before overwriting since KV owns the memory
        var old_copy: ?[]u8 = null;
        if (old) |v| {
            old_copy = self.allocator.dupe(u8, v) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
        }
        defer if (old_copy) |oc| self.allocator.free(oc);
        self.kvSet(key_ref.key, args[2]) catch {
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
            try resp.serializeNullValue(w, self.protocol_version);
            return;
        };
        defer key_ref.deinit(self.allocator);
        const val = self.kvGet(key_ref.key);
        if (val) |v| {
            const copy = self.allocator.dupe(u8, v) catch {
                try resp.serializeError(w, "internal error");
                return;
            };
            defer self.allocator.free(copy);
            _ = self.kvDelete(key_ref.key);
            self.logToAOF(args);
            try resp.serializeBulkString(w, copy);
        } else {
            try resp.serializeNullValue(w, self.protocol_version);
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
            try resp.serializeNullValue(w, self.protocol_version);
            return;
        };
        defer key_ref.deinit(self.allocator);
        const val = self.kvGet(key_ref.key);
        if (val == null) {
            try resp.serializeNullValue(w, self.protocol_version);
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
                self.kvSetEx(key_ref.key, copy, ttl) catch {};
            } else if (std.mem.eql(u8, flag, "PX")) {
                const ttl = std.fmt.parseInt(i64, args[3], 10) catch {
                    try resp.serializeError(w, "value is not an integer or out of range");
                    return;
                };
                self.kvSetPx(key_ref.key, copy, ttl) catch {};
            }
        } else if (args.len == 3) {
            var flag_buf: [64]u8 = undefined;
            const flag = toUpper(args[2], &flag_buf);
            if (std.mem.eql(u8, flag, "PERSIST")) {
                self.kvSet(key_ref.key, copy) catch {};
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
        if (!self.kvExists(key_ref.key)) {
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
        if (self.kvGet(key_ref.key)) |val| {
            self.kvSetPx(key_ref.key, val, ttl_ms) catch {
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
        const val = self.kvGet(src_ref.key);
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
        self.kvSet(dst_ref.key, copy) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        _ = self.kvDelete(src_ref.key);
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
        if (!self.kvExists(src_ref.key)) {
            try resp.serializeError(w, "no such key");
            return;
        }
        var dst_buf: [512]u8 = undefined;
        var dst_ref = namespacedKeyRef(self, args[2], &dst_buf) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer dst_ref.deinit(self.allocator);
        if (self.kvExists(dst_ref.key)) {
            try resp.serializeInteger(w, 0);
            return;
        }
        const val = self.kvGet(src_ref.key).?;
        const copy = self.allocator.dupe(u8, val) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(copy);
        self.kvSet(dst_ref.key, copy) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        _ = self.kvDelete(src_ref.key);
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
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeNullValue(w, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        if (self.getListStore().lpop(key_ref.key)) |val| {
            self.logToAOF(args);
            try resp.serializeBulkString(w, val);
        } else {
            try resp.serializeNullValue(w, self.protocol_version);
        }
    }

    fn cmdRpop(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for 'RPOP'"); return; }
        var key_buf: [512]u8 = undefined;
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeNullValue(w, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        if (self.getListStore().rpop(key_ref.key)) |val| {
            self.logToAOF(args);
            try resp.serializeBulkString(w, val);
        } else {
            try resp.serializeNullValue(w, self.protocol_version);
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
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeNullValue(w, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        const idx = std.fmt.parseInt(i64, args[2], 10) catch { try resp.serializeError(w, "value is not an integer"); return; };
        try resp.serializeBulkStringProto(w, self.getListStore().lindex(key_ref.key, idx), self.protocol_version);
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
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeNullValue(w, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        try resp.serializeBulkStringProto(w, self.getHashStore().hget(key_ref.key, args[2]), self.protocol_version);
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
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeMapOrArrayHeader(w, 0, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        const pairs = self.getHashStore().hgetall(key_ref.key, self.allocator) catch { try resp.serializeMapOrArrayHeader(w, 0, self.protocol_version); return; };
        defer if (pairs.len > 0) self.allocator.free(pairs);
        try resp.serializeMapOrArrayHeader(w, pairs.len / 2, self.protocol_version);
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
            for (args[2..]) |_| try resp.serializeNullValue(w, self.protocol_version);
            return;
        };
        defer key_ref.deinit(self.allocator);
        try resp.serializeArrayHeader(w, args.len - 2);
        for (args[2..]) |field| {
            try resp.serializeBulkStringProto(w, self.getHashStore().hget(key_ref.key, field), self.protocol_version);
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
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeSetOrArrayHeader(w, 0, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        const members = self.getSetStore().smembers(key_ref.key, self.allocator) catch { try resp.serializeSetOrArrayHeader(w, 0, self.protocol_version); return; };
        defer if (members.len > 0) self.allocator.free(members);
        try resp.serializeSetOrArrayHeader(w, members.len, self.protocol_version);
        for (members) |m| try resp.serializeBulkString(w, m);
    }

    fn cmdSunion(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        return self.cmdSetOp(args, w, .sunion, "SUNION");
    }

    fn cmdSinter(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        return self.cmdSetOp(args, w, .sinter, "SINTER");
    }

    fn cmdSdiff(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        return self.cmdSetOp(args, w, .sdiff, "SDIFF");
    }

    const SetOp = enum { sunion, sinter, sdiff };

    fn cmdSetOp(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer, comptime op: SetOp, comptime name: []const u8) !void {
        if (args.len < 2) { try resp.serializeError(w, "wrong number of arguments for '" ++ name ++ "'"); return; }
        var ns_keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (ns_keys.items) |k| self.allocator.free(@constCast(k));
            ns_keys.deinit();
        }
        for (args[1..]) |user_key| {
            const nk = namespacedKey(self, user_key) catch continue;
            ns_keys.append(nk) catch { self.allocator.free(nk); };
        }
        const ss = self.getSetStore();
        const result = switch (op) {
            .sunion => ss.sunion(ns_keys.items, self.allocator),
            .sinter => ss.sinter(ns_keys.items, self.allocator),
            .sdiff => ss.sdiff(ns_keys.items, self.allocator),
        } catch { try resp.serializeSetOrArrayHeader(w, 0, self.protocol_version); return; };
        defer if (result.len > 0) self.allocator.free(result);
        try resp.serializeSetOrArrayHeader(w, result.len, self.protocol_version);
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
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeNullValue(w, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        if (self.getSortedSetStore().zscore(key_ref.key, args[2])) |score| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.6}", .{score}) catch { try resp.serializeNullValue(w, self.protocol_version); return; };
            try resp.serializeBulkString(w, s);
        } else {
            try resp.serializeNullValue(w, self.protocol_version);
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
        var key_ref = namespacedKeyRef(self, args[1], &key_buf) catch { try resp.serializeNullValue(w, self.protocol_version); return; };
        defer key_ref.deinit(self.allocator);
        const rank = self.getSortedSetStore().zrank(key_ref.key, args[2]);
        if (rank) |r| {
            try resp.serializeInteger(w, @intCast(r));
        } else {
            try resp.serializeNullValue(w, self.protocol_version);
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
        try resp.serializeNullValue(w, self.protocol_version);
    }

    /// HELLO [protover] — RESP3 protocol negotiation
    fn cmdHello(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) !void {
        var target_proto = self.protocol_version;

        if (args.len >= 2) {
            const proto_num = std.fmt.parseInt(u8, args[1], 10) catch {
                try resp.serializeError(w, "Protocol version is not an integer or out of range");
                return;
            };
            switch (proto_num) {
                2 => target_proto = .resp2,
                3 => target_proto = .resp3,
                else => {
                    try resp.serializeErrorTyped(w, "NOPROTO", "unsupported protocol version");
                    return;
                },
            }
        }

        self.protocol_version = target_proto;

        // Response: 7 key-value pairs — server, version, proto, id, mode, role, modules
        if (target_proto == .resp3) {
            try resp.serializeMapHeader(w, 7);
        } else {
            try resp.serializeArrayHeader(w, 14);
        }
        try resp.serializeBulkString(w, "server");
        try resp.serializeBulkString(w, "vex");
        try resp.serializeBulkString(w, "version");
        try resp.serializeBulkString(w, vex_root.VERSION);
        try resp.serializeBulkString(w, "proto");
        try resp.serializeInteger(w, @intFromEnum(target_proto));
        try resp.serializeBulkString(w, "id");
        try resp.serializeInteger(w, 1); // placeholder
        try resp.serializeBulkString(w, "mode");
        try resp.serializeBulkString(w, "standalone");
        try resp.serializeBulkString(w, "role");
        try resp.serializeBulkString(w, "master");
        try resp.serializeBulkString(w, "modules");
        if (target_proto == .resp3) {
            try resp.serializeSetHeader(w, 0);
        } else {
            try resp.serializeArrayHeader(w, 0);
        }
    }

    fn cmdInfo(self: *CommandHandler, out: *std.Io.Writer) std.Io.Writer.Error!void {
        // Prefer the CKV (reactor mode store) when available — that's the live
        // KV in reactor mode and the legacy `self.kv` won't be populated.
        var kv_keys: usize = 0;
        var kv_with_ttl: u32 = 0;
        if (self.ckv) |ckv| {
            kv_keys = ckv.dbsize();
            // CKV doesn't expose a TTL count cheaply; report 0 to avoid a full scan.
        } else {
            var it = self.kv.map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.flags.deleted) continue;
                if (stripDbPrefix(self, entry.key_ptr.*) != null) {
                    kv_keys += 1;
                    if (entry.value_ptr.flags.has_ttl) kv_with_ttl += 1;
                }
            }
        }
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();

        // Resource usage snapshot — read once, used by Memory + CPU sections.
        var ru: std.c.rusage = undefined;
        const ru_ok = std.c.getrusage(std.c.rusage.SELF, &ru) == 0;

        // Server section
        try aw.writer.writeAll("# Server\r\n");
        try aw.writer.print("vex_version:{s}\r\n", .{vex_root.VERSION});
        try aw.writer.writeAll("engine:csr_soa_v2\r\n");
        try aw.writer.print("os:{s}\r\n", .{@tagName(@import("builtin").os.tag)});
        try aw.writer.print("arch:{s}\r\n", .{@tagName(@import("builtin").cpu.arch)});
        try aw.writer.print("process_id:{d}\r\n", .{std.c.getpid()});
        const now_ms = obsNowMillis();
        const start_ms = obs_stats.start_time_ms;
        const uptime_sec: i64 = if (start_ms == 0) 0 else @divTrunc(now_ms - start_ms, 1000);
        try aw.writer.print("uptime_in_seconds:{d}\r\n", .{uptime_sec});

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

        // Clients section
        try aw.writer.writeAll("\r\n# Clients\r\n");
        try aw.writer.print("connected_clients:{d}\r\n", .{obs_stats.connected_clients.load(.monotonic)});

        // Memory section
        try aw.writer.writeAll("\r\n# Memory\r\n");
        if (ru_ok) {
            // On Linux ru_maxrss is in KiB; on macOS it's in bytes. Normalize to bytes.
            const is_darwin_target = @import("builtin").os.tag == .macos;
            const rss_bytes: u64 = if (is_darwin_target)
                @intCast(@max(@as(i64, ru.maxrss), 0))
            else
                @as(u64, @intCast(@max(@as(i64, ru.maxrss), 0))) * 1024;
            try aw.writer.print("used_memory_rss:{d}\r\n", .{rss_bytes});
        } else {
            try aw.writer.writeAll("used_memory_rss:0\r\n");
        }
        try aw.writer.print("maxmemory:{d}\r\n", .{self.kv.maxmemory});
        const policy_str: []const u8 = switch (self.kv.eviction_policy) {
            .noeviction => "noeviction",
            .allkeys_lru => "allkeys-lru",
        };
        try aw.writer.print("maxmemory_policy:{s}\r\n", .{policy_str});

        // Persistence section
        try aw.writer.writeAll("\r\n# Persistence\r\n");
        if (self.aof) |a| {
            try aw.writer.writeAll("aof_enabled:1\r\n");
            try aw.writer.print("aof_current_size:{d}\r\n", .{a.file_offset});
            try aw.writer.print("aof_buffer_length:{d}\r\n", .{if (a.group_buf_inited) a.group_buf.items.len else @as(usize, 0)});
            try aw.writer.print("aof_fsync_mode:{s}\r\n", .{a.fsync_mode.label()});
            try aw.writer.print("aof_last_fsync:{d}\r\n", .{@divTrunc(a.lastFsyncMs(), 1000)});
            const broken = obs_stats.persistence_broken.load(.monotonic);
            try aw.writer.print("aof_last_write_status:{s}\r\n", .{if (broken) "err" else "ok"});
            try aw.writer.print("last_save_time:{d}\r\n", .{@divTrunc(a.last_save_time, 1000)});
        } else {
            try aw.writer.writeAll("aof_enabled:0\r\n");
        }

        // CPU section — process-wide times since start.
        try aw.writer.writeAll("\r\n# CPU\r\n");
        if (ru_ok) {
            const user_sec: f64 = @as(f64, @floatFromInt(ru.utime.sec)) + @as(f64, @floatFromInt(ru.utime.usec)) / 1_000_000.0;
            const sys_sec: f64 = @as(f64, @floatFromInt(ru.stime.sec)) + @as(f64, @floatFromInt(ru.stime.usec)) / 1_000_000.0;
            try aw.writer.print("used_cpu_user:{d:.3}\r\n", .{user_sec});
            try aw.writer.print("used_cpu_sys:{d:.3}\r\n", .{sys_sec});
        } else {
            try aw.writer.writeAll("used_cpu_user:0\r\nused_cpu_sys:0\r\n");
        }

        // Replication section — role, leader/follower state, lag.
        const repl_mod = @import("../cluster/replication.zig");
        const cur_leader = repl_mod.current_leader_ptr.load(.acquire);
        const cur_follower = repl_mod.current_follower_ptr.load(.acquire);
        try aw.writer.writeAll("\r\n# Replication\r\n");
        if (cur_leader) |ld| {
            try aw.writer.writeAll("role:master\r\n");
            try aw.writer.print("connected_slaves:{d}\r\n", .{ld.follower_count.load(.monotonic)});
            try aw.writer.print("master_repl_offset:{d}\r\n", .{ld.mutation_seq.load(.monotonic)});
            try aw.writer.print("master_replid:{s}\r\n", .{"0000000000000000000000000000000000000000"});
            try aw.writer.print("cluster_epoch:{d}\r\n", .{repl_mod.current_epoch.load(.monotonic)});
            // Per-follower lag — Redis-shaped one line per follower:
            //   slaveN:ip=...,port=...,offset=O,applied=A,lag_seq=L-A,lag_sec=S
            _ = std.c.pthread_mutex_lock(&ld.mutex);
            defer _ = std.c.pthread_mutex_unlock(&ld.mutex);
            const master_seq = ld.mutation_seq.load(.monotonic);
            const repl_now_ms = obsNowMillis();
            for (ld.followers.items, 0..) |state, i| {
                const applied = state.last_ack_seq.load(.monotonic);
                const lag_seq: u64 = if (master_seq > applied) master_seq - applied else 0;
                const ack_ts = state.last_ack_ts_ms.load(.monotonic);
                const lag_sec: i64 = if (ack_ts == 0) -1 else @divTrunc(repl_now_ms - ack_ts, 1000);
                try aw.writer.print(
                    "slave{d}:addr={s},offset={d},applied={d},lag_seq={d},lag_sec={d}\r\n",
                    .{ i, state.addrSlice(), master_seq, applied, lag_seq, lag_sec },
                );
            }
        } else if (cur_follower) |fl| {
            try aw.writer.writeAll("role:slave\r\n");
            // Link is "down" if either the socket is gone OR the heartbeat
            // timeout flag is set (set by replication.zig when no heartbeat
            // arrived within HEARTBEAT_TIMEOUT_MS — the fd may still be open
            // but the leader is silent).
            const link_down = fl.leader_fd < 0 or obs_stats.leader_unreachable.load(.acquire);
            try aw.writer.print("master_link_status:{s}\r\n", .{if (link_down) "down" else "up"});
            try aw.writer.print("master_repl_offset:{d}\r\n", .{fl.leader_seq.load(.monotonic)});
            try aw.writer.print("slave_repl_offset:{d}\r\n", .{fl.local_seq.load(.monotonic)});
            try aw.writer.print("slave_replayed_count:{d}\r\n", .{fl.replayed_count.load(.monotonic)});
            try aw.writer.print("cluster_epoch:{d}\r\n", .{repl_mod.current_epoch.load(.monotonic)});
            const last_hb = fl.last_heartbeat_ms.load(.monotonic);
            const lag_ms: i64 = if (last_hb == 0) -1 else obsNowMillis() - last_hb;
            const lag_sec: i64 = if (lag_ms < 0) -1 else @divTrunc(lag_ms, 1000);
            try aw.writer.print("master_last_io_seconds_ago:{d}\r\n", .{lag_sec});
        } else {
            try aw.writer.writeAll("role:standalone\r\n");
            try aw.writer.writeAll("connected_slaves:0\r\n");
        }

        // Cluster section (if available)
        try aw.writer.writeAll("\r\n# Cluster\r\n");
        try aw.writer.print("graph_mutation_seq:{d}\r\n", .{self.graph.mutation_seq});

        // Stats section — aggregate counters across all workers.
        var cmd_calls: [obs_stats.N_CMDS]u64 = undefined;
        obs_stats.aggregateCmdCalls(&cmd_calls);
        var total_calls: u64 = 0;
        for (cmd_calls) |n| total_calls +%= n;
        const scalars = obs_stats.aggregateScalars();
        try aw.writer.writeAll("\r\n# Stats\r\n");
        try aw.writer.print("total_commands_processed:{d}\r\n", .{total_calls});
        try aw.writer.print("total_connections_received:{d}\r\n", .{scalars.accepted_conns});
        try aw.writer.print("rejected_connections:{d}\r\n", .{scalars.rejected_conns});
        try aw.writer.print("total_net_input_bytes:{d}\r\n", .{scalars.net_in_bytes});
        try aw.writer.print("total_net_output_bytes:{d}\r\n", .{scalars.net_out_bytes});
        try aw.writer.print("total_error_replies:{d}\r\n", .{scalars.total_errors});
        try aw.writer.print("evicted_keys:{d}\r\n", .{obs_stats.evicted_keys.load(.monotonic)});
        try aw.writer.print("expired_keys:{d}\r\n", .{obs_stats.expired_keys.load(.monotonic)});

        // Commandstats section — one line per command with non-zero calls.
        // Field names mirror Redis: `cmdstat_<name>:calls=N,usec=0,...`.
        // usec/usec_per_call/failed_calls land at 0 until timings are wired.
        try aw.writer.writeAll("\r\n# Commandstats\r\n");
        for (cmd_calls, 0..) |n, i| {
            if (n == 0) continue;
            const name = obs_cmd_table.nameOf(@intCast(i));
            try aw.writer.print(
                "cmdstat_{s}:calls={d},usec=0,usec_per_call=0,rejected_calls=0,failed_calls=0\r\n",
                .{ name, n },
            );
        }

        try resp.serializeBulkString(out, aw.written());
    }

    fn cmdCommand(_: *CommandHandler, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try resp.serializeSimpleString(w, "OK");
    }

    /// SLOWLOG GET [count] | SLOWLOG LEN | SLOWLOG RESET | SLOWLOG HELP
    /// Redis-compatible. Aggregates per-worker rings; entries returned
    /// newest-first.
    fn cmdSlowlog(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'slowlog'");
            return;
        }
        var sub_buf: [16]u8 = undefined;
        const sub = toUpperBuf(args[1], &sub_buf);

        if (std.mem.eql(u8, sub, "LEN")) {
            try resp.serializeInteger(w, @intCast(obs_stats.slowlogTotalLen()));
            return;
        }
        if (std.mem.eql(u8, sub, "RESET")) {
            obs_stats.slowlogResetAll(self.allocator);
            try resp.serializeSimpleString(w, "OK");
            return;
        }
        if (std.mem.eql(u8, sub, "HELP")) {
            const lines = [_][]const u8{
                "SLOWLOG GET [count] -- Return up to <count> (default 10) most recent slow commands.",
                "SLOWLOG LEN         -- Total number of slowlog entries across workers.",
                "SLOWLOG RESET       -- Clear the slowlog ring on every worker.",
                "SLOWLOG HELP        -- Show this help.",
            };
            try resp.serializeArrayHeader(w, lines.len);
            for (lines) |line| try resp.serializeBulkString(w, line);
            return;
        }
        if (std.mem.eql(u8, sub, "GET")) {
            const requested: usize = if (args.len >= 3)
                std.fmt.parseInt(usize, args[2], 10) catch 10
            else
                10;
            const entries = obs_stats.slowlogSnapshot(self.allocator, requested) catch {
                try resp.serializeError(w, "internal: slowlog snapshot failed");
                return;
            };
            defer {
                for (entries) |e| self.allocator.free(e.args_blob);
                self.allocator.free(entries);
            }
            try resp.serializeArrayHeader(w, entries.len);
            for (entries) |entry| {
                // Each entry is itself an array of 4 elements:
                //   [id, ts_ms, duration_us, [cmd, args...]]
                try resp.serializeArrayHeader(w, 4);
                try resp.serializeInteger(w, @intCast(entry.id));
                try resp.serializeInteger(w, @intCast(@divTrunc(entry.ts_ms, 1000)));
                try resp.serializeInteger(w, @intCast(entry.duration_us));
                // argv array
                const argc: usize = if (entry.args_blob.len > 0) entry.args_blob[0] else 0;
                try resp.serializeArrayHeader(w, argc);
                if (argc > 0) {
                    var pos: usize = 1;
                    var i: usize = 0;
                    while (i < argc and pos < entry.args_blob.len) : (i += 1) {
                        const alen = entry.args_blob[pos];
                        pos += 1;
                        if (pos + alen > entry.args_blob.len) break;
                        try resp.serializeBulkString(w, entry.args_blob[pos .. pos + alen]);
                        pos += alen;
                    }
                }
            }
            return;
        }

        try resp.serializeError(w, "unknown SLOWLOG subcommand");
    }

    /// LATENCY LATEST | HISTORY <event> | RESET [event ...] | DOCTOR | HELP
    /// Redis-compatible event-latency monitor for rare slow operations
    /// (fsync stalls, snapshot saves, AOF rewrites, eviction sweeps).
    fn cmdLatency(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'latency'");
            return;
        }
        var sub_buf: [16]u8 = undefined;
        const sub = toUpperBuf(args[1], &sub_buf);

        if (std.mem.eql(u8, sub, "LATEST")) {
            // Return array of [event_name, ts_sec, latest_duration_ms, max_duration_ms]
            // — one entry per kind that has at least one sample.
            const kinds = [_]event_stats.EventKind{ .aof_fsync, .aof_rewrite, .snapshot_save, .snapshot_load, .eviction_cycle };
            // Count kinds with samples for the array header.
            var n_present: usize = 0;
            inline for (kinds) |k| if (event_stats.latest(k).sample != null) {
                n_present += 1;
            };
            try resp.serializeArrayHeader(w, n_present);
            inline for (kinds) |k| {
                const li = event_stats.latest(k);
                if (li.sample) |s| {
                    try resp.serializeArrayHeader(w, 4);
                    try resp.serializeBulkString(w, k.name());
                    try resp.serializeInteger(w, @intCast(@divTrunc(s.ts_ms, 1000)));
                    try resp.serializeInteger(w, @intCast(@divTrunc(s.duration_us, 1000)));
                    try resp.serializeInteger(w, @intCast(@divTrunc(li.max_us, 1000)));
                }
            }
            return;
        }
        if (std.mem.eql(u8, sub, "HISTORY")) {
            if (args.len < 3) {
                try resp.serializeError(w, "wrong number of arguments for 'latency history'");
                return;
            }
            const kind = event_stats.EventKind.fromName(args[2]) orelse {
                try resp.serializeArrayHeader(w, 0);
                return;
            };
            const hist = event_stats.history(self.allocator, kind) catch {
                try resp.serializeError(w, "internal: history snapshot failed");
                return;
            };
            defer self.allocator.free(hist);
            try resp.serializeArrayHeader(w, hist.len);
            for (hist) |s| {
                try resp.serializeArrayHeader(w, 2);
                try resp.serializeInteger(w, @intCast(@divTrunc(s.ts_ms, 1000)));
                try resp.serializeInteger(w, @intCast(@divTrunc(s.duration_us, 1000)));
            }
            return;
        }
        if (std.mem.eql(u8, sub, "RESET")) {
            if (args.len <= 2) {
                const n = event_stats.resetAll();
                try resp.serializeInteger(w, @intCast(n));
                return;
            }
            var count: u32 = 0;
            for (args[2..]) |name| {
                if (event_stats.EventKind.fromName(name)) |kind| {
                    if (event_stats.reset(kind)) count += 1;
                }
            }
            try resp.serializeInteger(w, @intCast(count));
            return;
        }
        if (std.mem.eql(u8, sub, "DOCTOR")) {
            // Human-readable summary. Walk each kind, build text.
            var aw = std.Io.Writer.Allocating.init(self.allocator);
            defer aw.deinit();
            const kinds = [_]event_stats.EventKind{ .aof_fsync, .aof_rewrite, .snapshot_save, .snapshot_load, .eviction_cycle };
            var any: bool = false;
            inline for (kinds) |k| {
                const li = event_stats.latest(k);
                if (li.sample) |s| {
                    any = true;
                    try aw.writer.print(
                        "{s}: latest {d}ms (peak {d}ms)\n",
                        .{ k.name(), @divTrunc(s.duration_us, 1000), @divTrunc(li.max_us, 1000) },
                    );
                }
            }
            if (!any) try aw.writer.writeAll("No latency events recorded. Tune `latency-monitor-threshold` lower to capture finer-grained stalls.\n");
            try resp.serializeBulkString(w, aw.written());
            return;
        }
        if (std.mem.eql(u8, sub, "HELP")) {
            const lines = [_][]const u8{
                "LATENCY LATEST                   -- Most recent event per kind (name, ts, latest_ms, max_ms).",
                "LATENCY HISTORY <event>          -- All samples for an event kind (newest-first).",
                "LATENCY RESET [event ...]        -- Reset one, several, or all event rings.",
                "LATENCY DOCTOR                   -- Human-readable summary.",
                "Event kinds: aof-fsync aof-rewrite snapshot-save snapshot-load eviction-cycle",
            };
            try resp.serializeArrayHeader(w, lines.len);
            for (lines) |line| try resp.serializeBulkString(w, line);
            return;
        }
        try resp.serializeError(w, "unknown LATENCY subcommand");
    }

    /// DEBUG OBJECT <key> | DEBUG SLEEP <seconds> | DEBUG HELP
    /// Operator-facing introspection. OBJECT returns key metadata,
    /// SLEEP blocks the connection for N seconds — useful for testing
    /// SLOWLOG/LATENCY end-to-end.
    fn cmdDebug(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'debug'");
            return;
        }
        var sub_buf: [16]u8 = undefined;
        const sub = toUpperBuf(args[1], &sub_buf);

        if (std.mem.eql(u8, sub, "OBJECT")) {
            if (args.len < 3) {
                try resp.serializeError(w, "wrong number of arguments for 'debug object'");
                return;
            }
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRef(self, args[2], &key_buf) catch {
                try resp.serializeError(w, "internal: namespace failure");
                return;
            };
            defer key_ref.deinit(self.allocator);
            // The "Value at:0x..." format is what redis-cli prints for legacy
            // clients. We omit a real address (we don't expose memory layout)
            // and emit serializedlength + encoding hint based on the type.
            const v = self.kvGet(key_ref.key);
            if (v == null) {
                try resp.serializeError(w, "no such key");
                return;
            }
            const val = v.?;
            const encoding: []const u8 = if (val.len <= 44) "embstr" else "raw";
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "Value at:0x0 refcount:1 encoding:{s} serializedlength:{d} lru:0 lru_seconds_idle:0",
                .{ encoding, val.len },
            ) catch {
                try resp.serializeError(w, "internal: format failure");
                return;
            };
            try resp.serializeSimpleString(w, line);
            return;
        }
        if (std.mem.eql(u8, sub, "SLEEP")) {
            if (args.len < 3) {
                try resp.serializeError(w, "wrong number of arguments for 'debug sleep'");
                return;
            }
            const secs = std.fmt.parseFloat(f64, args[2]) catch {
                try resp.serializeError(w, "invalid seconds value");
                return;
            };
            if (secs <= 0) {
                try resp.serializeSimpleString(w, "OK");
                return;
            }
            // Cap at 60s to keep the worker thread from being held forever by
            // a misused operator command.
            const capped: f64 = if (secs > 60.0) 60.0 else secs;
            const whole_sec: i64 = @intFromFloat(@floor(capped));
            const frac_ns: i64 = @intFromFloat((capped - @floor(capped)) * 1_000_000_000.0);
            var ts = std.c.timespec{ .sec = whole_sec, .nsec = frac_ns };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&ts, &rem);
            try resp.serializeSimpleString(w, "OK");
            return;
        }
        if (std.mem.eql(u8, sub, "HELP")) {
            const lines = [_][]const u8{
                "DEBUG OBJECT <key>   -- Metadata about a key (encoding, serializedlength).",
                "DEBUG SLEEP <secs>   -- Block the worker for N seconds (capped at 60). For testing SLOWLOG.",
                "DEBUG HELP           -- This help.",
            };
            try resp.serializeArrayHeader(w, lines.len);
            for (lines) |line| try resp.serializeBulkString(w, line);
            return;
        }
        try resp.serializeError(w, "unknown DEBUG subcommand");
    }

    /// MEMORY USAGE <key> [SAMPLES N] | MEMORY STATS | MEMORY HELP
    fn cmdMemory(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'memory'");
            return;
        }
        var sub_buf: [16]u8 = undefined;
        const sub = toUpperBuf(args[1], &sub_buf);

        if (std.mem.eql(u8, sub, "USAGE")) {
            if (args.len < 3) {
                try resp.serializeError(w, "wrong number of arguments for 'memory usage'");
                return;
            }
            var key_buf: [512]u8 = undefined;
            var key_ref = namespacedKeyRef(self, args[2], &key_buf) catch {
                try resp.serializeError(w, "internal: namespace failure");
                return;
            };
            defer key_ref.deinit(self.allocator);
            const v = self.kvGet(key_ref.key);
            if (v == null) {
                try resp.serializeBulkString(w, null);
                return;
            }
            // Approximation: value bytes + small per-entry overhead (key copy,
            // map slot, alignment). Redis's MEMORY USAGE is also an estimate.
            const usage: i64 = @intCast(v.?.len + args[2].len + 56);
            try resp.serializeInteger(w, usage);
            return;
        }
        if (std.mem.eql(u8, sub, "STATS")) {
            // Process-wide breakdown — mirrors a subset of Redis's MEMORY STATS.
            // Returned as a flat RESP array of alternating key/value bulk strings.
            var ru: std.c.rusage = undefined;
            const ru_ok = std.c.getrusage(std.c.rusage.SELF, &ru) == 0;
            const is_darwin_target = @import("builtin").os.tag == .macos;
            const rss_bytes: u64 = if (!ru_ok) 0 else if (is_darwin_target)
                @intCast(@max(@as(i64, ru.maxrss), 0))
            else
                @as(u64, @intCast(@max(@as(i64, ru.maxrss), 0))) * 1024;

            const start_ms = obs_stats.start_time_ms;
            const uptime_ms: i64 = if (start_ms == 0) 0 else obsNowMillis() - start_ms;

            const Pair = struct { k: []const u8, v: u64 };
            const pairs = [_]Pair{
                .{ .k = "peak.allocated", .v = rss_bytes },
                .{ .k = "total.allocated", .v = rss_bytes },
                .{ .k = "startup.allocated", .v = 0 },
                .{ .k = "replication.backlog", .v = 0 },
                .{ .k = "clients.slaves", .v = 0 },
                .{ .k = "clients.normal", .v = @intCast(obs_stats.connected_clients.load(.monotonic)) },
                .{ .k = "cluster.links", .v = 0 },
                .{ .k = "aof.buffer", .v = if (self.aof) |a| (if (a.group_buf_inited) a.group_buf.items.len else 0) else 0 },
                .{ .k = "lua.caches", .v = 0 },
                .{ .k = "overhead.total", .v = 0 },
                .{ .k = "keys.count", .v = if (self.ckv) |ckv| ckv.dbsize() else 0 },
                .{ .k = "dataset.bytes", .v = rss_bytes }, // approximation
                .{ .k = "allocator.fragmentation.ratio", .v = 1 }, // we don't track yet
                .{ .k = "uptime.ms", .v = @intCast(@max(uptime_ms, 0)) },
            };
            try resp.serializeArrayHeader(w, pairs.len * 2);
            for (pairs) |p| {
                try resp.serializeBulkString(w, p.k);
                try resp.serializeInteger(w, @intCast(p.v));
            }
            return;
        }
        if (std.mem.eql(u8, sub, "HELP")) {
            const lines = [_][]const u8{
                "MEMORY USAGE <key>   -- Approximate bytes used by a key's value.",
                "MEMORY STATS         -- Process-wide memory breakdown (flat key/value pairs).",
                "MEMORY HELP          -- This help.",
            };
            try resp.serializeArrayHeader(w, lines.len);
            for (lines) |line| try resp.serializeBulkString(w, line);
            return;
        }
        try resp.serializeError(w, "unknown MEMORY subcommand");
    }

    /// VEX.PROMOTE <epoch> — admin command for cluster failover.
    /// Atomically validates `epoch > current_epoch`, persists the new epoch
    /// to vex.epoch, and (when cluster mode is configured) starts the
    /// replication leader. Intended to be called by vex-sentinel; not used
    /// by regular clients.
    fn cmdVexPromote(self: *CommandHandler, args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (args.len < 2) {
            try resp.serializeError(w, "wrong number of arguments for 'vex.promote'");
            return;
        }
        const requested_epoch = std.fmt.parseInt(u64, args[1], 10) catch {
            try resp.serializeError(w, "invalid epoch (must be a positive integer)");
            return;
        };
        const repl_mod = @import("../cluster/replication.zig");
        const dd = self.data_dir orelse {
            try resp.serializeError(w, "vex.promote requires --data-dir (persistence) to be configured");
            return;
        };
        _ = repl_mod.bumpAndPersistEpoch(self.allocator, dd, requested_epoch) catch |err| switch (err) {
            error.StaleEpoch => {
                try resp.serializeError(w, "epoch must be strictly greater than the current epoch");
                return;
            },
            else => {
                try resp.serializeError(w, "failed to persist epoch");
                return;
            },
        };
        // VEX.PROMOTE currently persists the new epoch only. The in-process
        // role flip (stopping the ReplicationFollower, spinning up a
        // ReplicationLeader, swapping current_leader_ptr) is intentionally
        // not done here yet — it's a follow-on PR. Until that lands, an
        // operator running manual failover should: bump the epoch via
        // VEX.PROMOTE, then restart the chosen node with a leader-role
        // config. vex-sentinel will drive both steps together once it
        // ships.
        try resp.serializeSimpleString(w, "OK");
    }

    /// VEX.STATUS — return role / epoch / replication info as a flat map.
    /// Used by vex-sentinel's health poll.
    fn cmdVexStatus(self: *CommandHandler, w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        const repl_mod = @import("../cluster/replication.zig");
        const epoch = repl_mod.current_epoch.load(.monotonic);
        const cur_leader = repl_mod.current_leader_ptr.load(.acquire);
        const cur_follower = repl_mod.current_follower_ptr.load(.acquire);

        const role: []const u8 = if (cur_leader != null) "leader" else if (cur_follower != null) "follower" else "standalone";
        const repl_offset: u64 = if (cur_leader) |ld| ld.mutation_seq.load(.monotonic) else if (cur_follower) |fl| fl.local_seq.load(.monotonic) else 0;
        const slaves: u32 = if (cur_leader) |ld| ld.follower_count.load(.monotonic) else 0;

        // Flat array of [key, value, key, value, ...] like MEMORY STATS.
        try resp.serializeArrayHeader(w, 8);
        try resp.serializeBulkString(w, "role");
        try resp.serializeBulkString(w, role);
        try resp.serializeBulkString(w, "epoch");
        try resp.serializeInteger(w, @intCast(epoch));
        try resp.serializeBulkString(w, "repl_offset");
        try resp.serializeInteger(w, @intCast(repl_offset));
        try resp.serializeBulkString(w, "connected_slaves");
        try resp.serializeInteger(w, @intCast(slaves));
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
            try resp.serializeNullValue(w, self.protocol_version);
            return;
        };

        // RESP3: map {key, type, properties: {k1: v1, ...}}
        // RESP2: flat array [key, type, prop_count, k1, v1, k2, v2, ...]
        const prop_count = self.graph.node_props.countProps(node.id);
        const pairs = self.graph.node_props.collectAll(node.id, self.allocator) catch {
            try resp.serializeError(w, "internal error");
            return;
        };
        defer self.allocator.free(pairs);
        const user_key = stripGraphDbPrefix(self, node.key) orelse node.key;
        if (self.protocol_version == .resp3) {
            try resp.serializeMapHeader(w, 3);
            try resp.serializeBulkString(w, "key");
            try resp.serializeBulkString(w, user_key);
            try resp.serializeBulkString(w, "type");
            try resp.serializeBulkString(w, node.node_type);
            try resp.serializeBulkString(w, "properties");
            try resp.serializeMapHeader(w, prop_count);
            for (pairs) |pair| {
                try resp.serializeBulkString(w, pair.key);
                try resp.serializeBulkString(w, pair.value);
            }
        } else {
            const total: usize = 3 + prop_count * 2;
            try resp.serializeArrayHeader(w, total);
            try resp.serializeBulkString(w, user_key);
            try resp.serializeBulkString(w, node.node_type);
            try resp.serializeInteger(w, @intCast(prop_count));
            for (pairs) |pair| {
                try resp.serializeBulkString(w, pair.key);
                try resp.serializeBulkString(w, pair.value);
            }
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
                try resp.serializeNullValue(w, self.protocol_version);
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
            } else if (std.mem.eql(u8, flag, "LIMIT") and i + 1 < args.len) {
                opts.max_results = std.fmt.parseInt(u32, args[i + 1], 10) catch 0;
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

        // Pre-build entire RESP response in one buffer — single writeAll instead of 3*N calls.
        // The previous manual buf+pos+realloc(buf, buf.len * 2) doubling pattern silently
        // OOB'd on @memcpy whenever a single user_key.len > buf.len * 2 - pos. In ReleaseFast
        // that corrupted an adjacent heap chunk and surfaced later as glibc's
        //   realloc(): invalid next size
        // Fix: walk ids once to compute the exact response size, allocate once, then
        // fill with appendSliceAssumeCapacity. Single allocation, no realloc cycle,
        // no in-loop error paths.
        const keys = self.graph.node_keys.items;
        const null_bytes: []const u8 = if (self.protocol_version == .resp3) "_\r\n" else "$-1\r\n";

        // Pass 1: exact size. "$N\r\n<bytes>" framing costs 3 + digits(N) + bytes.len.
        var total: usize = 3 + std.fmt.count("{d}", .{ids.len}); // "*N\r\n" array header
        for (ids) |nid| {
            if (nid < keys.len) {
                const user_key = stripGraphDbPrefix(self, keys[nid]) orelse keys[nid];
                total += 3 + std.fmt.count("{d}", .{user_key.len}) + user_key.len;
            } else {
                total += null_bytes.len;
            }
            total += 2; // trailing "\r\n" written for both branches
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.ensureTotalCapacity(self.allocator, total) catch {
            // Fallback on OOM: stream per-node. Matches the prior code's behavior
            // when the initial alloc failed, so OOM degradation is unchanged.
            try resp.serializeArrayHeader(w, ids.len);
            for (ids) |nid| {
                if (nid < keys.len) {
                    try resp.serializeBulkString(w, stripGraphDbPrefix(self, keys[nid]) orelse keys[nid]);
                } else {
                    try resp.serializeNullValue(w, self.protocol_version);
                }
            }
            return;
        };

        // Pass 2: fill. Capacity is guaranteed; appendSliceAssumeCapacity is infallible.
        var hdr_buf: [16]u8 = undefined;
        const arr_hdr = std.fmt.bufPrint(&hdr_buf, "*{d}\r\n", .{ids.len}) catch unreachable;
        buf.appendSliceAssumeCapacity(arr_hdr);
        for (ids) |nid| {
            if (nid < keys.len) {
                const user_key = stripGraphDbPrefix(self, keys[nid]) orelse keys[nid];
                const entry_hdr = std.fmt.bufPrint(&hdr_buf, "${d}\r\n", .{user_key.len}) catch unreachable;
                buf.appendSliceAssumeCapacity(entry_hdr);
                buf.appendSliceAssumeCapacity(user_key);
            } else {
                buf.appendSliceAssumeCapacity(null_bytes);
            }
            buf.appendSliceAssumeCapacity("\r\n");
        }

        try w.writeAll(buf.items);
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
                try resp.serializeNullValue(w, self.protocol_version);
            }
        }
    }

    /// GRAPH.WPATH <from_key> <to_key>  (weighted shortest path — CH-accelerated when available)
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

        // Try CH-accelerated path if available and fresh
        const ch_result = self.tryCHQuery(from, to);
        if (ch_result) |r| {
            const result = r;
            defer self.allocator.free(result.nodes);
            try resp.serializeArrayHeader(w, result.nodes.len + 1);
            var weight_buf: [32]u8 = undefined;
            const weight_str = std.fmt.bufPrint(&weight_buf, "{d:.2}", .{result.weight}) catch "0";
            try resp.serializeBulkString(w, weight_str);
            for (result.nodes) |nid| {
                const node = self.graph.getNodeById(nid);
                if (node) |n| {
                    const user_key = stripGraphDbPrefix(self, n.key) orelse n.key;
                    try resp.serializeBulkString(w, user_key);
                } else {
                    try resp.serializeNullValue(w, self.protocol_version);
                }
            }
            return;
        }

        // Fall back to Dijkstra
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
                try resp.serializeNullValue(w, self.protocol_version);
            }
        }
    }

    const CHResult = struct { weight: f64, nodes: []graph_mod.NodeId };

    /// Try CH-accelerated query. Returns null if CH is unavailable or stale.
    fn tryCHQuery(self: *CommandHandler, from_key: []const u8, to_key: []const u8) ?CHResult {
        const ch_data = &(self.graph.ch orelse return null);
        // Stale check: CH was built at a different mutation_seq
        if (ch_data.mutation_seq != self.graph.mutation_seq) return null;
        var qe = &(self.graph.ch_query_engine orelse return null);

        const from_id = self.graph.resolveKey(from_key) orelse return null;
        const to_id = self.graph.resolveKey(to_key) orelse return null;

        const r = qe.query(ch_data, from_id, to_id) catch return null;
        return CHResult{ .weight = r.weight, .nodes = r.nodes };
    }

    /// GRAPH.CHBUILD -- build Contraction Hierarchies for accelerated WPATH
    fn cmdGraphCHBuild(self: *CommandHandler, w: *std.Io.Writer) !void {
        self.graph.rebuildCH() catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.COMPACT -- rebuild CSR from delta edges for fast traversals
    fn cmdGraphCompact(self: *CommandHandler, w: *std.Io.Writer) !void {
        self.graph.compact() catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        try resp.serializeSimpleString(w, "OK");
    }

    /// GRAPH.CHSTATS — report Contraction Hierarchies status
    fn cmdGraphCHStats(self: *CommandHandler, w: *std.Io.Writer) !void {
        const ch_data = self.graph.ch;
        const fresh = if (ch_data) |c| c.mutation_seq == self.graph.mutation_seq else false;
        const node_count: i64 = if (ch_data) |c| @intCast(c.node_count) else 0;

        // Count shortcut edges (edges with middle != INVALID)
        var shortcuts: i64 = 0;
        if (ch_data) |c| {
            for (c.up_out_middles) |m| {
                if (m != graph_mod.INVALID_ID) shortcuts += 1;
            }
        }
        const total_up_edges: i64 = if (ch_data) |c| @intCast(c.up_out_targets.len) else 0;

        try resp.serializeMapOrArrayHeader(w, 5, self.protocol_version);
        try resp.serializeBulkString(w, "status");
        try resp.serializeBulkString(w, if (ch_data == null) "none" else if (fresh) "fresh" else "stale");
        try resp.serializeBulkString(w, "nodes");
        try resp.serializeInteger(w, node_count);
        try resp.serializeBulkString(w, "up_edges");
        try resp.serializeInteger(w, total_up_edges);
        try resp.serializeBulkString(w, "shortcuts");
        try resp.serializeInteger(w, shortcuts);
        try resp.serializeBulkString(w, "original");
        try resp.serializeInteger(w, total_up_edges - shortcuts);
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
        try resp.serializeMapOrArrayHeader(w, 2, self.protocol_version);
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
        const vec = self.graph.getVector(nk, args[2]) orelse { try resp.serializeNullValue(w, self.protocol_version); return; };
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
        try resp.serializeMapOrArrayHeader(w, results.len, self.protocol_version);
        for (results) |r| {
            const node = self.graph.getNodeById(r.node_id);
            if (node) |n| { try resp.serializeBulkString(w, stripGraphDbPrefix(self, n.key) orelse n.key); } else { try resp.serializeNullValue(w, self.protocol_version); }
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
            try resp.serializeMapOrArrayHeader(w, r.props.len, self.protocol_version);
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
    ///
    /// Payload: {"nodes":[{"id","node_type"|"type","metadata"?}, ...],
    ///           "edges":[{"from_id"|"from","to_id"|"to","edge_type"|"type","metadata"?}, ...]}
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
                    const id_str = jsonStringField(obj, &.{"id"});
                    const type_str = jsonStringField(obj, &.{ "node_type", "type" });
                    if (id_str == null or type_str == null) continue;
                    const nk = graphNamespacedKey(self, id_str.?) catch continue;
                    defer self.allocator.free(nk);
                    _ = self.graph.upsertNode(nk, type_str.?) catch continue;
                    if (obj.get("metadata")) |meta_val| {
                        if (meta_val == .object) self.applyNodeMetadataFromObject(nk, meta_val.object) catch {};
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
                    const from_str = jsonStringField(obj, &.{ "from_id", "from" });
                    const to_str = jsonStringField(obj, &.{ "to_id", "to" });
                    const etype_str = jsonStringField(obj, &.{ "edge_type", "type" });
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
                    if (obj.get("metadata")) |meta_val| {
                        if (meta_val == .object) self.applyEdgeMetadataFromObject(eid, meta_val.object) catch {};
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
            try resp.serializeArrayHeader(w, 2);
            const node = self.graph.getNodeById(nid);
            if (node) |n| {
                try resp.serializeBulkString(w, stripGraphDbPrefix(self, n.key) orelse n.key);
                try resp.serializeBulkString(w, n.node_type);
            } else {
                try resp.serializeNullValue(w, self.protocol_version);
                try resp.serializeNullValue(w, self.protocol_version);
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

        // Serialize as map (RESP3) or flat array (RESP2): [type_name, count, ...]
        try resp.serializeMapOrArrayHeader(w, results.len, self.protocol_version);
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
                    try resp.serializeNullValue(w, self.protocol_version);
                    try resp.serializeNullValue(w, self.protocol_version);
                }
            }
        }
    }

    // ── JSON metadata helpers ───────────────────────────────────────────

    fn applyJsonMetadataToNode(self: *CommandHandler, key: []const u8, json_str: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{}) catch return error.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJSON;
        try self.applyNodeMetadataFromObject(key, parsed.value.object);
    }

    fn applyJsonMetadataToEdge(self: *CommandHandler, eid: graph_mod.EdgeId, json_str: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{}) catch return error.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJSON;
        try self.applyEdgeMetadataFromObject(eid, parsed.value.object);
    }

    fn applyNodeMetadataFromObject(self: *CommandHandler, key: []const u8, obj: std.json.ObjectMap) !void {
        var iter = obj.iterator();
        while (iter.next()) |entry| {
            const val_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
            try self.graph.setNodeProperty(key, entry.key_ptr.*, val_str);
        }
    }

    fn applyEdgeMetadataFromObject(self: *CommandHandler, eid: graph_mod.EdgeId, obj: std.json.ObjectMap) !void {
        var iter = obj.iterator();
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
        // Foreground SAVE runs on the worker thread which already holds
        // kv_mutex for the duration of the command, so the snapshot is
        // built inline (no extra lock needed).
        const kv_snap = self.kv.snapshot(self.allocator) catch |err| {
            try resp.serializeError(w, @errorName(err));
            return;
        };
        defer KVStore.freeSnapshot(kv_snap, self.allocator);
        snapshot.save(self.io, self.allocator, kv_snap, self.graph, a.snapshot_path) catch |err| {
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
            kv_mutex: ?*std.atomic.Mutex,
            data_dir: ?[]const u8,

            fn run(ctx: *@This()) void {
                defer {
                    bgsave_in_progress.store(false, .release);
                    ctx.allocator.destroy(ctx);
                }

                // Phase 1: snapshot kv under kv_mutex (brief — O(N) memcopy).
                // We release kv_mutex before touching graph_rwlock or disk so
                // non-hot-path workers aren't blocked through seconds of I/O.
                const kv_snap = blk: {
                    if (ctx.kv_mutex) |m| {
                        while (!m.tryLock()) std.Thread.yield() catch {};
                    }
                    defer if (ctx.kv_mutex) |m| m.unlock();
                    break :blk ctx.kv.snapshot(ctx.allocator) catch return;
                };
                defer KVStore.freeSnapshot(kv_snap, ctx.allocator);

                // Phase 2: hold graph rdlock for the file write (writers block,
                // readers proceed). Graph data is iterated live; no copy.
                if (ctx.graph_rwlock) |rwl| {
                    _ = std.c.pthread_rwlock_rdlock(rwl);
                }
                defer if (ctx.graph_rwlock) |rwl| {
                    _ = std.c.pthread_rwlock_unlock(rwl);
                };

                snapshot.save(ctx.io, ctx.allocator, kv_snap, ctx.graph, ctx.snapshot_path) catch return;
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
            .kv_mutex = self.kv_mutex,
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

    /// BGREWRITEAOF -- rewrite AOF from current state on a background thread.
    /// Returns immediately. Holds graph_rwlock rdlock for the duration of
    /// the iteration (matches BGSAVE). KV map iteration is racy with KV
    /// writers in the same way BGSAVE is — both background persistence
    /// paths share that posture; do not diverge here without also fixing
    /// BGSAVE.
    fn cmdBgRewriteAof(self: *CommandHandler, w: *std.Io.Writer) !void {
        const a = self.aof orelse {
            try resp.serializeError(w, "persistence not configured");
            return;
        };
        // Refuse if a rewrite OR snapshot is already running. They both
        // hold graph_rwlock rdlock + thrash disk; running concurrently
        // doubles I/O and serves no purpose.
        if (bgrewriteaof_in_progress.load(.acquire) or bgsave_in_progress.load(.acquire)) {
            try resp.serializeError(w, "Background append only file rewriting already in progress");
            return;
        }
        if (bgrewriteaof_in_progress.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            try resp.serializeError(w, "Background append only file rewriting already in progress");
            return;
        }

        const BgRewriteCtx = struct {
            allocator: Allocator,
            kv: *KVStore,
            graph: *GraphEngine,
            aof_ptr: *AOF,
            graph_rwlock: ?*std.c.pthread_rwlock_t,
            kv_mutex: ?*std.atomic.Mutex,

            fn run(ctx: *@This()) void {
                defer {
                    bgrewriteaof_in_progress.store(false, .release);
                    ctx.allocator.destroy(ctx);
                }

                // See BGSAVE: snapshot kv briefly under kv_mutex, then drop
                // it before the file-write phase so workers aren't stalled.
                const snap_now_ms: i64 = blk_now: {
                    if (ctx.kv_mutex) |m| {
                        while (!m.tryLock()) std.Thread.yield() catch {};
                    }
                    break :blk_now ctx.kv.cached_now_ms;
                };
                const kv_snap = blk: {
                    defer if (ctx.kv_mutex) |m| m.unlock();
                    break :blk ctx.kv.snapshot(ctx.allocator) catch return;
                };
                defer KVStore.freeSnapshot(kv_snap, ctx.allocator);

                if (ctx.graph_rwlock) |rwl| {
                    _ = std.c.pthread_rwlock_rdlock(rwl);
                }
                defer if (ctx.graph_rwlock) |rwl| {
                    _ = std.c.pthread_rwlock_unlock(rwl);
                };

                ctx.aof_ptr.rewriteFromState(ctx.allocator, kv_snap, snap_now_ms, ctx.graph) catch return;
            }
        };

        const ctx = self.allocator.create(BgRewriteCtx) catch {
            bgrewriteaof_in_progress.store(false, .release);
            try resp.serializeError(w, "out of memory");
            return;
        };
        ctx.* = .{
            .allocator = self.allocator,
            .kv = self.kv,
            .graph = self.graph,
            .aof_ptr = a,
            .graph_rwlock = self.graph_rwlock,
            .kv_mutex = self.kv_mutex,
        };

        const t = std.Thread.spawn(.{}, BgRewriteCtx.run, .{ctx}) catch {
            bgrewriteaof_in_progress.store(false, .release);
            self.allocator.destroy(ctx);
            try resp.serializeError(w, "failed to spawn background rewrite thread");
            return;
        };
        t.detach();
        try resp.serializeSimpleString(w, "Background append only file rewriting started");
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
fn obsNowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

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

const db_prefix = @import("../db_prefix.zig");

fn namespacedKeyRef(self: *CommandHandler, key: []const u8, stack_buf: []u8) !NamespacedKeyRef {
    const db = self.selected_db.load(.monotonic);
    if (db >= db_prefix.MAX_DATABASES) {
        const owned = try namespacedKey(self, key);
        return .{ .key = owned, .owned = owned };
    }
    const prefix = db_prefix.DB_PREFIXES[db];
    const total_len = prefix.len + key.len;
    if (total_len <= stack_buf.len) {
        @memcpy(stack_buf[0..prefix.len], prefix);
        @memcpy(stack_buf[prefix.len..total_len], key);
        return .{ .key = stack_buf[0..total_len] };
    }
    const owned = try namespacedKey(self, key);
    return .{ .key = owned, .owned = owned };
}

fn namespacedKeyForDb(self: *CommandHandler, db: u8, key: []const u8) ![]u8 {
    if (db < db_prefix.MAX_DATABASES) {
        const prefix = db_prefix.DB_PREFIXES[db];
        const result = try self.allocator.alloc(u8, prefix.len + key.len);
        @memcpy(result[0..prefix.len], prefix);
        @memcpy(result[prefix.len..], key);
        return result;
    }
    return std.fmt.allocPrint(self.allocator, "db:{d}:{s}", .{ db, key });
}

fn stripDbPrefix(self: *CommandHandler, raw_key: []const u8) ?[]const u8 {
    const db = self.selected_db.load(.monotonic);
    if (db >= db_prefix.MAX_DATABASES) return null;
    const prefix = db_prefix.DB_PREFIXES[db];
    if (!std.mem.startsWith(u8, raw_key, prefix)) return null;
    return raw_key[prefix.len..];
}

fn graphNamespacedKey(self: *CommandHandler, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(self.allocator, "gdb:{d}:{s}", .{ self.selected_db.load(.monotonic), key });
}

/// Return the first string-valued field from `obj` matching any of `names`, or null.
/// Lets bulk decoders accept both canonical snake-case (`node_type`) and legacy short
/// forms (`type`) without diverging the wire schema.
fn jsonStringField(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (obj.get(name)) |v| {
            if (v == .string) return v.string;
        }
    }
    return null;
}

fn stripGraphDbPrefix(self: *CommandHandler, raw_key: []const u8) ?[]const u8 {
    const db = self.selected_db.load(.monotonic);
    if (db >= db_prefix.MAX_DATABASES) return null;
    const prefix = db_prefix.GRAPH_DB_PREFIXES[db];
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

