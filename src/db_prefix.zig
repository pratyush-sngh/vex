const std = @import("std");

pub const MAX_DATABASES: u8 = 16;

/// Precomputed "db:N:" prefixes. Avoids runtime fmt per command.
pub const DB_PREFIXES = blk: {
    var prefixes: [MAX_DATABASES][]const u8 = undefined;
    for (0..MAX_DATABASES) |i| {
        prefixes[i] = std.fmt.comptimePrint("db:{d}:", .{i});
    }
    break :blk prefixes;
};

pub const GRAPH_DB_PREFIXES = blk: {
    var prefixes: [MAX_DATABASES][]const u8 = undefined;
    for (0..MAX_DATABASES) |i| {
        prefixes[i] = std.fmt.comptimePrint("gdb:{d}:", .{i});
    }
    break :blk prefixes;
};
