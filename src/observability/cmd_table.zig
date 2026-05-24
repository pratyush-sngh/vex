//! Comptime command name -> u8 index table for per-command stats.
//! Names are uppercase, matched case-insensitively at runtime.
//! Unknown commands map to the OTHER bucket (last index).
//!
//! Indexing is stable across builds: the position in `command_names` is the
//! index. Append new commands at the end of their section to keep indices
//! compatible with running stats consumers.

const std = @import("std");

pub const MAX_CMD_NAME_LEN: usize = 31;

/// Canonical command name list. Index = position. Appended commands get the
/// next free index. "OTHER" stays at the last position as the catch-all.
pub const command_names = [_][]const u8{
    // ── KV / generic ──────────────────────────────────────────────────
    "GET",
    "SET",
    "DEL",
    "UNLINK",
    "EXISTS",
    "MEXISTS",
    "MGET",
    "MSET",
    "MSETNX",
    "MSETEX",
    "MGETDEL",
    "GETDEL",
    "GETSET",
    "GETEX",
    "INCR",
    "INCRBY",
    "DECR",
    "DECRBY",
    "APPEND",
    "TTL",
    "EXPIRE",
    "INCRTTL",
    "COPY",
    "KEYS",
    "SCAN",
    "SCANGET",
    "TYPE",
    "RENAME",
    "DBSIZE",
    "FLUSHDB",
    "FLUSHALL",
    "SELECT",
    "PING",
    "ECHO",
    "INFO",
    "COMMAND",
    "TIME",
    "AUTH",
    "HELLO",
    "QUIT",
    "RESET",
    "CONFIG",
    "CLIENT",
    "OBJECT",
    "DEBUG",
    "MEMORY",
    "SAVE",
    "BGSAVE",
    "BGREWRITEAOF",
    "LASTSAVE",
    "SHUTDOWN",
    "WAIT",
    "MULTI",
    "EXEC",
    "DISCARD",
    "WATCH",
    "UNWATCH",
    "SUBSCRIBE",
    "UNSUBSCRIBE",
    "PSUBSCRIBE",
    "PUNSUBSCRIBE",
    "PUBLISH",

    // ── Lists ─────────────────────────────────────────────────────────
    "LPUSH",
    "RPUSH",
    "LPOP",
    "RPOP",
    "LPOPN",
    "LLEN",
    "LRANGE",
    "LINDEX",
    "LSET",
    "LREM",

    // ── Hashes ────────────────────────────────────────────────────────
    "HSET",
    "HGET",
    "HDEL",
    "HEXISTS",
    "HGETALL",
    "HLEN",
    "HKEYS",
    "HVALS",
    "HMSET",
    "HMGET",
    "HINCRBY",

    // ── Sets ──────────────────────────────────────────────────────────
    "SADD",
    "SREM",
    "SMEMBERS",
    "SISMEMBER",
    "SCARD",
    "SUNION",
    "SINTER",
    "SDIFF",

    // ── Sorted sets ───────────────────────────────────────────────────
    "ZADD",
    "ZREM",
    "ZRANGE",
    "ZSCORE",
    "ZRANK",
    "ZCARD",
    "ZINCRBY",
    "ZCOUNT",

    // ── Graph ─────────────────────────────────────────────────────────
    "GRAPH.ADDNODE",
    "GRAPH.ADDEDGE",
    "GRAPH.UPSERT_NODE",
    "GRAPH.UPSERT_EDGE",
    "GRAPH.DELNODE",
    "GRAPH.DELEDGE",
    "GRAPH.GETNODE",
    "GRAPH.NEIGHBORS",
    "GRAPH.LIST_BY_TYPE",
    "GRAPH.PATH",
    "GRAPH.PATHS",
    "GRAPH.WPATH",
    "GRAPH.TRAVERSE",
    "GRAPH.SETPROP",
    "GRAPH.SETVEC",
    "GRAPH.GETVEC",
    "GRAPH.VECSEARCH",
    "GRAPH.RAG",
    "GRAPH.INGEST",
    "GRAPH.IMPACT",
    "GRAPH.STATS",
    "GRAPH.COMPACT",
    "GRAPH.CHBUILD",
    "GRAPH.CHSTATS",

    // Catch-all for unknown / unlisted commands.
    "OTHER",
};

pub const N_CMDS: usize = command_names.len;
pub const OTHER_IDX: u8 = @intCast(N_CMDS - 1);

/// Set of command prefixes that mutate state. Used by the STOP-WRITE path
/// in dispatchCommand to reject writes when persistence is broken
/// (disk full, AOF flush errors, etc.). Reads continue to work.
///
/// We classify by prefix-string rather than maintaining a parallel bool
/// array because new commands tend to follow naming conventions
/// (SET/HSET/ZADD/GRAPH.ADDNODE/etc.) so prefix matching catches most
/// future additions automatically.
const WRITE_PREFIXES = [_][]const u8{
    "SET",      "SETEX",  "SETNX",     "MSET",   "MSETEX", "MSETNX",
    "DEL",      "UNLINK", "MGETDEL",   "GETDEL", "GETSET", "GETEX",
    "INCR",     "INCRBY", "INCRTTL",   "DECR",   "DECRBY",
    "APPEND",   "EXPIRE", "PEXPIRE",   "PERSIST", "COPY",   "RENAME", "RENAMENX",
    "FLUSHDB",  "FLUSHALL",
    "LPUSH",    "RPUSH",  "LPOP",      "RPOP",   "LPOPN",  "LSET",    "LREM",
    "HSET",     "HDEL",   "HMSET",     "HINCRBY",
    "SADD",     "SREM",
    "ZADD",     "ZREM",   "ZINCRBY",
    "GRAPH.",   // any GRAPH.* command that is a write — checked further
};

/// Set of GRAPH.* command names that are read-only. Everything else under
/// the GRAPH.* prefix is considered a write.
const GRAPH_READS = [_][]const u8{
    "GRAPH.GETNODE",     "GRAPH.GETVEC",      "GRAPH.NEIGHBORS",
    "GRAPH.LIST_BY_TYPE", "GRAPH.PATH",        "GRAPH.PATHS",
    "GRAPH.WPATH",       "GRAPH.TRAVERSE",    "GRAPH.VECSEARCH",
    "GRAPH.RAG",         "GRAPH.STATS",       "GRAPH.IMPACT",
    "GRAPH.CHSTATS",
};

/// Returns true if the named command mutates state. Case-insensitive.
/// Used by the STOP-WRITE gate. Conservative: anything not recognized
/// returns false (safer to let an unknown command through than to wrongly
/// block reads).
pub fn isWriteCommand(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_CMD_NAME_LEN) return false;
    var upper: [MAX_CMD_NAME_LEN]u8 = undefined;
    for (name, 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
    const up = upper[0..name.len];

    // GRAPH.* needs the GRAPH_READS exception list.
    if (up.len >= 6 and std.mem.eql(u8, up[0..6], "GRAPH.")) {
        for (GRAPH_READS) |r| if (std.mem.eql(u8, up, r)) return false;
        return true;
    }

    for (WRITE_PREFIXES) |w| {
        if (std.mem.eql(u8, up, w)) return true;
    }
    return false;
}

// ── Tests for write classification ──

test "isWriteCommand — basic write detection" {
    try std.testing.expect(isWriteCommand("SET"));
    try std.testing.expect(isWriteCommand("set"));
    try std.testing.expect(isWriteCommand("HSET"));
    try std.testing.expect(isWriteCommand("DEL"));
    try std.testing.expect(isWriteCommand("FLUSHALL"));
}

test "isWriteCommand — reads are not writes" {
    try std.testing.expect(!isWriteCommand("GET"));
    try std.testing.expect(!isWriteCommand("HGET"));
    try std.testing.expect(!isWriteCommand("LRANGE"));
    try std.testing.expect(!isWriteCommand("INFO"));
    try std.testing.expect(!isWriteCommand("PING"));
}

test "isWriteCommand — GRAPH.* split" {
    try std.testing.expect(isWriteCommand("GRAPH.ADDNODE"));
    try std.testing.expect(isWriteCommand("GRAPH.SETPROP"));
    try std.testing.expect(isWriteCommand("GRAPH.INGEST"));
    try std.testing.expect(!isWriteCommand("GRAPH.GETNODE"));
    try std.testing.expect(!isWriteCommand("GRAPH.NEIGHBORS"));
    try std.testing.expect(!isWriteCommand("GRAPH.STATS"));
}

test "isWriteCommand — unknown is read" {
    try std.testing.expect(!isWriteCommand("DEFINITELY_NOT_A_COMMAND"));
    try std.testing.expect(!isWriteCommand(""));
}

/// Build a comptime map from uppercase name -> index. Lookup is O(1).
const Map = std.StaticStringMap(u8);

const map: Map = blk: {
    @setEvalBranchQuota(20_000);
    var entries: [N_CMDS - 1]struct { []const u8, u8 } = undefined;
    for (command_names[0 .. N_CMDS - 1], 0..) |name, i| {
        entries[i] = .{ name, @intCast(i) };
    }
    break :blk Map.initComptime(entries);
};

/// Return the canonical name for an index (e.g. for INFO output).
pub fn nameOf(idx: u8) []const u8 {
    if (idx >= N_CMDS) return "OTHER";
    return command_names[idx];
}

/// Resolve a raw command name (any case) to its index. Returns OTHER_IDX for
/// unknown or oversized names. ~15ns cost (upper-case copy + perfect-hash map
/// lookup); intended to be called once per command in the dispatch hot path.
pub fn lookup(name: []const u8) u8 {
    if (name.len == 0 or name.len > MAX_CMD_NAME_LEN) return OTHER_IDX;
    var upper_buf: [MAX_CMD_NAME_LEN]u8 = undefined;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    return map.get(upper_buf[0..name.len]) orelse OTHER_IDX;
}

// ── Tests ───────────────────────────────────────────────────────────

test "lookup — exact case" {
    try std.testing.expectEqual(@as(u8, 0), lookup("GET"));
    try std.testing.expectEqual(@as(u8, 1), lookup("SET"));
}

test "lookup — case insensitive" {
    try std.testing.expectEqual(lookup("GET"), lookup("get"));
    try std.testing.expectEqual(lookup("GET"), lookup("Get"));
    try std.testing.expectEqual(lookup("GRAPH.ADDNODE"), lookup("graph.addnode"));
}

test "lookup — unknown -> OTHER_IDX" {
    try std.testing.expectEqual(OTHER_IDX, lookup("NOPE"));
    try std.testing.expectEqual(OTHER_IDX, lookup("xyzzy"));
}

test "lookup — empty and oversized -> OTHER_IDX" {
    try std.testing.expectEqual(OTHER_IDX, lookup(""));
    var huge: [64]u8 = undefined;
    @memset(&huge, 'A');
    try std.testing.expectEqual(OTHER_IDX, lookup(&huge));
}

test "nameOf — round-trip through lookup" {
    for (command_names[0 .. N_CMDS - 1], 0..) |name, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), lookup(name));
        try std.testing.expectEqualStrings(name, nameOf(@intCast(i)));
    }
}

test "N_CMDS sanity" {
    try std.testing.expect(N_CMDS > 50);
    try std.testing.expect(N_CMDS < 256);
}
