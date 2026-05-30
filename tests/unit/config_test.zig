// Migrated unit tests for src/config.zig.

const std = @import("std");
const ConfigFile = @import("../../src/config.zig").ConfigFile;

test "parse config file" {
    const allocator = std.testing.allocator;
    const data =
        \\# Vex configuration
        \\port 6380
        \\requirepass secret
        \\maxmemory 256mb
        \\
        \\# Empty lines and comments ignored
        \\reactor
        \\maxclients 5000
    ;

    var cfg = try ConfigFile.parse(allocator, data);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("6380", cfg.get("port").?);
    try std.testing.expectEqualStrings("secret", cfg.get("requirepass").?);
    try std.testing.expectEqualStrings("256mb", cfg.get("maxmemory").?);
    try std.testing.expectEqualStrings("5000", cfg.get("maxclients").?);
    try std.testing.expectEqualStrings("", cfg.get("reactor").?); // boolean flag
    try std.testing.expect(cfg.get("nonexistent") == null);
}

test "parse empty config" {
    const allocator = std.testing.allocator;
    var cfg = try ConfigFile.parse(allocator, "");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.entries.count());
}

test "parse config with comments only" {
    const allocator = std.testing.allocator;
    const data = "# just a comment\n# another\n";
    var cfg = try ConfigFile.parse(allocator, data);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.entries.count());
}
