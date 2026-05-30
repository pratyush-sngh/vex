// Migrated unit tests for src/cluster/config.zig.

const std = @import("std");
const config = @import("../../../src/cluster/config.zig");
const parseString = config.parseString;
const NodeRole = config.NodeRole;

test "parse cluster config" {
    const data =
        \\# Vex cluster config
        \\node 1 leader 10.0.0.1:6380
        \\node 2 follower 10.0.0.2:6380
        \\node 3 follower 10.0.0.3:6380
        \\self 1
        \\
    ;
    var cfg = try parseString(std.testing.allocator, data);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 1), cfg.self_id);
    try std.testing.expectEqual(@as(usize, 3), cfg.nodes.len);
    try std.testing.expect(cfg.isLeader());

    const leader = cfg.getLeader().?;
    try std.testing.expectEqualStrings("10.0.0.1", leader.host);
    try std.testing.expectEqual(@as(u16, 6380), leader.port);

    try std.testing.expectEqual(@as(usize, 2), cfg.followerCount());
}

test "parse follower config" {
    const data =
        \\node 1 leader 10.0.0.1:6380
        \\node 2 follower 10.0.0.2:6380
        \\self 2
        \\
    ;
    var cfg = try parseString(std.testing.allocator, data);
    defer cfg.deinit();

    try std.testing.expect(!cfg.isLeader());
    try std.testing.expectEqual(@as(u16, 2), cfg.self_id);

    const self_node = cfg.selfNode().?;
    try std.testing.expectEqual(NodeRole.follower, self_node.role);
}

test "invalid config missing self" {
    const data = "node 1 leader 10.0.0.1:6380\n";
    const result = parseString(std.testing.allocator, data);
    try std.testing.expect(result == error.InvalidConfig);
}
