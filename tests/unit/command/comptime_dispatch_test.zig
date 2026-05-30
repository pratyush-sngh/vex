// Migrated unit tests for src/command/comptime_dispatch.zig.

const std = @import("std");
const cd = @import("../../../src/command/comptime_dispatch.zig");

const hot_commands = cd.hot_commands;
const dispatchKey = cd.dispatchKey;
const runtimeDispatchKey = cd.runtimeDispatchKey;
const findCommand = cd.findCommand;
const RespInts = cd.RespInts;

test "dispatch keys are unique" {
    for (hot_commands, 0..) |a, i| {
        for (hot_commands[i + 1 ..]) |b| {
            try std.testing.expect(runtimeDispatchKey(a.name) != runtimeDispatchKey(b.name));
        }
    }
}

test "dispatch key computation" {
    try std.testing.expectEqual(dispatchKey("GET"), (3 << 8) | 'G');
    try std.testing.expectEqual(dispatchKey("SET"), (3 << 8) | 'S');
    try std.testing.expectEqual(dispatchKey("DEL"), (3 << 8) | 'D');
    try std.testing.expectEqual(dispatchKey("PING"), (4 << 8) | 'P');
    try std.testing.expectEqual(dispatchKey("EXISTS"), (6 << 8) | 'E');
}

test "resp integer literals" {
    try std.testing.expectEqualStrings(":0\r\n", RespInts.@"0");
    try std.testing.expectEqualStrings(":1\r\n", RespInts.@"1");
    try std.testing.expectEqualStrings(":-1\r\n", RespInts.@"-1");
    try std.testing.expectEqualStrings(":-2\r\n", RespInts.@"-2");
}

test "findCommand" {
    const get_cmd = comptime findCommand(&hot_commands, "GET");
    try std.testing.expect(get_cmd != null);
    try std.testing.expect(!get_cmd.?.flags.is_write);
    try std.testing.expectEqual(@as(u4, 2), get_cmd.?.flags.min_args);

    const set_cmd = comptime findCommand(&hot_commands, "SET");
    try std.testing.expect(set_cmd != null);
    try std.testing.expect(set_cmd.?.flags.is_write);

    const missing = comptime findCommand(&hot_commands, "UNKNOWN");
    try std.testing.expect(missing == null);
}
