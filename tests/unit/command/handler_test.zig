// Migrated unit tests for src/command/handler.zig.
//
// These were inline `test` blocks at the bottom of handler.zig until the
// Phase 2 migration moved them here. The test code itself is verbatim; only
// the type references gained an explicit module prefix (since they're no
// longer in the same file scope).

const std = @import("std");
const Allocator = std.mem.Allocator;

// System under test + its dependencies. Paths go up three directories
// (tests/unit/command/ → repo root) before re-entering src/.
const handler_mod = @import("../../../src/command/handler.zig");
const CommandHandler = handler_mod.CommandHandler;

const KVStore = @import("../../../src/engine/kv.zig").KVStore;
const GraphEngine = @import("../../../src/engine/graph.zig").GraphEngine;
const ListStore = @import("../../../src/engine/list.zig").ListStore;
const HashStore = @import("../../../src/engine/hash.zig").HashStore;

// ─── Helper: execute one command, return the raw RESP response ─────────
fn testExec(handler: *CommandHandler, allocator: Allocator, args: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();
    try handler.execute(args, &aw.writer);
    return allocator.dupe(u8, aw.written());
}

// ─── Tests ──────────────────────────────────────────────────────────────

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
    try std.testing.expect(!handler_mod.bgsave_in_progress.load(.acquire));
    handler_mod.bgsave_in_progress.store(true, .release);
    try std.testing.expect(handler_mod.bgsave_in_progress.load(.acquire));
    handler_mod.bgsave_in_progress.store(false, .release);
    try std.testing.expect(!handler_mod.bgsave_in_progress.load(.acquire));
}

test "GRAPH.UPSERT_NODE stores all arbitrary JSON metadata keys" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // metric type: all 4 keys must be stored
    const r1 = try testExec(&handler, allocator, &[_][]const u8{
        "GRAPH.UPSERT_NODE", "metric:test", "metric",
        "{\"source\":\"obs\",\"metric_name\":\"rps\",\"value\":\"42\",\"unit\":\"req/s\"}",
    });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("+OK\r\n", r1);

    const g1 = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.GETNODE", "metric:test" });
    defer allocator.free(g1);
    try std.testing.expect(std.mem.indexOf(u8, g1, "source") != null);
    try std.testing.expect(std.mem.indexOf(u8, g1, "metric_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, g1, "value") != null);
    try std.testing.expect(std.mem.indexOf(u8, g1, "unit") != null);
    try std.testing.expect(std.mem.indexOf(u8, g1, ":4\r\n") != null); // 4 properties

    // trace type: all 5 keys must be stored
    const r2 = try testExec(&handler, allocator, &[_][]const u8{
        "GRAPH.UPSERT_NODE", "trace:test", "trace",
        "{\"source\":\"obs\",\"operation\":\"GET /foo\",\"p95_ms\":\"120\",\"p99_ms\":\"300\",\"count\":\"500\"}",
    });
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("+OK\r\n", r2);

    const g2 = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.GETNODE", "trace:test" });
    defer allocator.free(g2);
    try std.testing.expect(std.mem.indexOf(u8, g2, "source") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2, "operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2, "p95_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2, "p99_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2, "count") != null);
    try std.testing.expect(std.mem.indexOf(u8, g2, ":5\r\n") != null); // 5 properties

    // service type with many observability keys
    const r3 = try testExec(&handler, allocator, &[_][]const u8{
        "GRAPH.UPSERT_NODE", "svc:api", "service",
        "{\"service\":\"api\",\"status\":\"healthy\",\"rps\":\"1200\",\"error_rate\":\"0.02\",\"last_enriched_at\":\"2026-04-29\"}",
    });
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("+OK\r\n", r3);

    const g3 = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.GETNODE", "svc:api" });
    defer allocator.free(g3);
    try std.testing.expect(std.mem.indexOf(u8, g3, "service") != null);
    try std.testing.expect(std.mem.indexOf(u8, g3, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, g3, "rps") != null);
    try std.testing.expect(std.mem.indexOf(u8, g3, "error_rate") != null);
    try std.testing.expect(std.mem.indexOf(u8, g3, "last_enriched_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, g3, ":5\r\n") != null); // 5 properties
}

test "GRAPH.UPSERT_EDGE stores all arbitrary JSON metadata keys" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // Create edge with arbitrary metadata
    const r1 = try testExec(&handler, allocator, &[_][]const u8{
        "GRAPH.UPSERT_EDGE", "svc:a", "svc:b", "calls",
        "{\"latency\":\"50ms\",\"protocol\":\"grpc\",\"request_count\":\"10000\",\"first_called_at\":\"2026-04-01\"}",
    });
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("+OK\r\n", r1);

    // Verify via GRAPH.SETPROP / GETNODE — edges don't have a GETEDGE, verify via node props roundtrip
    // We can verify the edge metadata was stored by checking the graph engine directly
    // For now, verify the upsert succeeded and nodes were created
    const g1 = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.GETNODE", "svc:a" });
    defer allocator.free(g1);
    try std.testing.expect(std.mem.indexOf(u8, g1, "svc:a") != null);

    const g2 = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.GETNODE", "svc:b" });
    defer allocator.free(g2);
    try std.testing.expect(std.mem.indexOf(u8, g2, "svc:b") != null);
}

test "GRAPH.INGEST accepts snake_case field names (node_type/from_id/to_id/edge_type)" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    const payload =
        \\{"nodes":[
        \\  {"id":"test:n1","node_type":"test","metadata":{"k":"v1"}},
        \\  {"id":"test:n2","node_type":"test","metadata":{"k":"v2"}},
        \\  {"id":"test:n3","node_type":"test","metadata":{"k":"v3"}}
        \\],"edges":[
        \\  {"id":"test:e1","from_id":"test:n1","to_id":"test:n2","edge_type":"linked"},
        \\  {"id":"test:e2","from_id":"test:n2","to_id":"test:n3","edge_type":"linked"}
        \\]}
    ;

    const r = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.INGEST", payload });
    defer allocator.free(r);
    try std.testing.expectEqualStrings("+OK\r\n", r);

    // All three nodes must be retrievable
    inline for (.{ "test:n1", "test:n2", "test:n3" }) |id| {
        const got = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.GETNODE", id });
        defer allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, id) != null);
    }

    // LIST_BY_TYPE returns the three IDs
    const list = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.LIST_BY_TYPE", "test" });
    defer allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "test:n1") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "test:n2") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "test:n3") != null);

    // Edges must be traversable
    const neigh = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.NEIGHBORS", "test:n1" });
    defer allocator.free(neigh);
    try std.testing.expect(std.mem.indexOf(u8, neigh, "test:n2") != null);
}

test "GRAPH.INGEST still accepts legacy short field names (type/from/to)" {
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    const payload =
        \\{"nodes":[{"id":"legacy:a","type":"test"},{"id":"legacy:b","type":"test"}],
        \\ "edges":[{"from":"legacy:a","to":"legacy:b","type":"linked"}]}
    ;
    const r = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.INGEST", payload });
    defer allocator.free(r);
    try std.testing.expectEqualStrings("+OK\r\n", r);

    const got = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.GETNODE", "legacy:a" });
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "legacy:a") != null);
}

test "GRAPH.TRAVERSE response handles neighbor key larger than initial buf" {
    // Regression test for the response builder in cmdGraphTraverse. The original
    // code grew its scratch buffer via `realloc(buf, buf.len * 2)`, which is
    // insufficient when a single `user_key.len` exceeds what `buf.len * 2 - pos`
    // can hold — the next @memcpy then writes past the buffer. In ReleaseFast
    // builds the OOB is silent and glibc detects the corruption later as
    //   realloc(): invalid next size
    // In ReleaseSafe / test builds Zig's bounds check panics:
    //   thread N panic: index out of bounds: index 230, len 192
    //   /app/src/command/handler.zig:2673:28: cmdGraphTraverse
    // With the realloc growing to max(buf.len * 2, pos + user_key.len + 2)
    // (or an equivalent ArrayList-based response builder) this test passes.
    const allocator = std.testing.allocator;
    var kv = KVStore.init(allocator, std.testing.io);
    defer kv.deinit();
    var g = GraphEngine.init(allocator);
    defer g.deinit();
    var db = std.atomic.Value(u8).init(0);
    var handler = CommandHandler.init(allocator, std.testing.io, &kv, &g, null, &db, .strict);

    // 300-byte neighbor key — bigger than the buf size reached by a single
    // doubling from the initial est_size at low ids counts, which is what
    // makes the second realloc insufficient.
    var long_key_buf: [300]u8 = undefined;
    @memset(&long_key_buf, 'a');
    const long_key: []const u8 = &long_key_buf;

    {
        const r = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.UPSERT_NODE", "src", "component" });
        defer allocator.free(r);
    }
    {
        const r = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.UPSERT_NODE", long_key, "method" });
        defer allocator.free(r);
    }
    {
        const r = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.UPSERT_EDGE", "src", long_key, "invokes" });
        defer allocator.free(r);
    }

    // Without the fix this panics inside cmdGraphTraverse's response builder.
    const out = try testExec(&handler, allocator, &[_][]const u8{ "GRAPH.TRAVERSE", "src", "DIR", "out", "DEPTH", "1" });
    defer allocator.free(out);

    // Sanity: response is non-empty RESP and contains the long key intact.
    try std.testing.expect(out.len > long_key.len);
    try std.testing.expect(std.mem.indexOf(u8, out, long_key) != null);
}
