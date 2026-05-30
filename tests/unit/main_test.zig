// Migrated unit tests for src/main.zig.

const std = @import("std");
const main = @import("../../src/main.zig");

test "parseMemorySize" {
    try std.testing.expectEqual(@as(usize, 1024), main.parseMemorySize("1024"));
    try std.testing.expectEqual(@as(usize, 256 * 1024 * 1024), main.parseMemorySize("256mb"));
    try std.testing.expectEqual(@as(usize, 256 * 1024 * 1024), main.parseMemorySize("256MB"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), main.parseMemorySize("1gb"));
    try std.testing.expectEqual(@as(usize, 64 * 1024), main.parseMemorySize("64kb"));
    try std.testing.expectEqual(@as(usize, 0), main.parseMemorySize(""));
    try std.testing.expectEqual(@as(usize, 0), main.parseMemorySize("abc"));
}
