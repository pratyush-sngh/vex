// Migrated unit tests for src/cluster/replication.zig.

const std = @import("std");
const replication = @import("../../../src/cluster/replication.zig");
const config_mod = @import("../../../src/cluster/config.zig");

const ReplicationFollower = replication.ReplicationFollower;
const probeForLeader = replication.probeForLeader;
const isWriteCommand = replication.isWriteCommand;

test "follower promoted flag blocks forwarding" {
    const config_data =
        \\node 1 leader 10.0.0.1:6380
        \\node 2 follower 10.0.0.2:6380 priority=1
        \\self 2
        \\
    ;
    var cc = try config_mod.parseString(std.testing.allocator, config_data);
    defer cc.deinit();

    var follower = ReplicationFollower.init(std.testing.allocator, &cc, 6380);
    defer follower.deinit();

    // Not promoted — forwardWrite should fail with NotConnected (no fd)
    const result1 = follower.forwardWrite(&[_][]const u8{ "SET", "foo", "bar" });
    try std.testing.expectError(error.NotConnected, result1);

    // Set promoted — forwardWrite should fail with Promoted
    follower.promoted.store(true, .release);
    const result2 = follower.forwardWrite(&[_][]const u8{ "SET", "foo", "bar" });
    try std.testing.expectError(error.Promoted, result2);

    // getPromotedLeader returns null when not set
    try std.testing.expect(follower.getPromotedLeader() == null);
}

test "probeForLeader returns null when no nodes listening" {
    const config_data =
        \\node 1 leader 127.0.0.1:19999
        \\node 2 follower 127.0.0.1:19998
        \\self 2
        \\
    ;
    var cc = try config_mod.parseString(std.testing.allocator, config_data);
    defer cc.deinit();

    // No node is listening on port 29999 — should return null
    const result = probeForLeader(std.testing.allocator, &cc);
    try std.testing.expect(result == null);
}

test "isWriteCommand" {
    try std.testing.expect(isWriteCommand(&[_][]const u8{"SET"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"DEL"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"MSET"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"INCR"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"EXPIRE"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"FLUSHDB"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"GRAPH.ADDNODE"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"GRAPH.ADDEDGE"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"GRAPH.DELNODE"}));

    try std.testing.expect(!isWriteCommand(&[_][]const u8{"GET"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"EXISTS"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"KEYS"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"PING"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"INFO"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"GRAPH.TRAVERSE"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"GRAPH.PATH"}));
}
