const std = @import("std");

/// Command flags describe properties used for dispatch routing.
pub const CmdFlags = packed struct {
    is_write: bool = false, // mutates state (needs AOF log)
    is_graph: bool = false, // requires graph mutex
    needs_key: bool = true, // requires namespaced key arg
    min_args: u4 = 2, // minimum argc including command name
    _padding: u1 = 0,
};

/// Comptime command table entry.
pub const CmdEntry = struct {
    name: []const u8,
    flags: CmdFlags,
};

/// The hot-path command table. New commands are added here — the dispatch
/// switch is generated at comptime from this table.
pub const hot_commands = [_]CmdEntry{
    .{ .name = "GET", .flags = .{ .min_args = 2 } },
    .{ .name = "SET", .flags = .{ .is_write = true, .min_args = 3 } },
    .{ .name = "DEL", .flags = .{ .is_write = true, .min_args = 2 } },
    .{ .name = "TTL", .flags = .{ .min_args = 2 } },
    .{ .name = "EXISTS", .flags = .{ .min_args = 2 } },
    .{ .name = "PING", .flags = .{ .needs_key = false, .min_args = 1 } },
    .{ .name = "COMMAND", .flags = .{ .needs_key = false, .min_args = 1 } },
    .{ .name = "FLUSHDB", .flags = .{ .is_write = true, .needs_key = false, .min_args = 1 } },
    .{ .name = "DBSIZE", .flags = .{ .needs_key = false, .min_args = 1 } },
};

/// Comptime: compute the dispatch key for a command name.
/// Key = (name.len << 8) | toUpper(name[0])
/// This gives a unique u16 for each (length, first-char) pair.
pub fn dispatchKey(comptime name: []const u8) u16 {
    return (@as(u16, @intCast(name.len)) << 8) | @as(u16, std.ascii.toUpper(name[0]));
}

/// Comptime: verify the command table has no dispatch key collisions.
/// Called at comptime — build fails if two commands would collide.
pub fn validateTable(comptime table: []const CmdEntry) void {
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            if (dispatchKey(a.name) == dispatchKey(b.name)) {
                @compileError("Command dispatch collision: '" ++ a.name ++ "' and '" ++ b.name ++ "' have the same (len, first_byte) key");
            }
        }
    }
}

/// Comptime: look up a command entry by name.
pub fn findCommand(comptime table: []const CmdEntry, comptime name: []const u8) ?CmdEntry {
    for (table) |entry| {
        if (comptime std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Pre-computed RESP integer responses for common values.
/// Avoids runtime std.fmt.bufPrint for ":N\r\n" on every command.
pub const RespInts = struct {
    /// Comptime: generate ":N\r\n" string for an integer.
    pub fn literal(comptime n: i64) []const u8 {
        return std.fmt.comptimePrint(":{d}\r\n", .{n});
    }

    // Pre-built responses for the most common integer values
    pub const @"0" = literal(0);
    pub const @"1" = literal(1);
    pub const @"-1" = literal(-1);
    pub const @"-2" = literal(-2);
};

/// Pre-computed RESP bulk string for null: "$-1\r\n"
pub const resp_null = "$-1\r\n";
pub const resp_ok = "+OK\r\n";
pub const resp_pong = "+PONG\r\n";

// ── Comptime validation ─────────────────────────────────────────────

comptime {
    validateTable(&hot_commands);
}

// ── Tests ───────────────────────────────────────────────────────────

fn runtimeDispatchKey(name: []const u8) u16 {
    return (@as(u16, @intCast(name.len)) << 8) | @as(u16, std.ascii.toUpper(name[0]));
}

test "dispatch keys are unique" {
    // Comptime validation already runs above; this tests the runtime path
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
