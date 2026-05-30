// Migrated unit tests for src/observability/cmd_table.zig.

const std = @import("std");
const cmd_table = @import("../../../src/observability/cmd_table.zig");

const isWriteCommand = cmd_table.isWriteCommand;
const lookup = cmd_table.lookup;
const nameOf = cmd_table.nameOf;
const OTHER_IDX = cmd_table.OTHER_IDX;
const N_CMDS = cmd_table.N_CMDS;
const command_names = cmd_table.command_names;

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
