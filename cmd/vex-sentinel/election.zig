//! Pure leader-selection: given an alive set and the cluster config,
//! pick the node that should be the new leader.
//!
//! Policy: highest-priority (lowest priority number) alive follower,
//! tie-broken by highest applied_offset. Matches the plan: "pick
//! highest-priority alive node, increment epoch, send VEX.PROMOTE".

const std = @import("std");
const cluster_config = @import("vex_cluster_config");
const Health = @import("health.zig");

pub const Candidate = struct {
    node_id: u16,
    priority: u8,
    applied_offset: u64,
};

/// Pick the next leader from `health` snapshots. Returns null when no
/// follower is alive — caller should log and wait for the next tick.
pub fn pickLeader(
    cfg: *const cluster_config.ClusterConfig,
    health: []const Health.NodeHealth,
) ?Candidate {
    var best: ?Candidate = null;
    for (cfg.nodes) |node| {
        if (node.role != .follower) continue;

        const hp = healthFor(node.id, health) orelse continue;
        if (!hp.alive) continue;

        const c = Candidate{
            .node_id = node.id,
            .priority = node.priority,
            .applied_offset = hp.applied_offset,
        };
        if (best == null or wins(c, best.?)) best = c;
    }
    return best;
}

fn healthFor(node_id: u16, health: []const Health.NodeHealth) ?Health.NodeHealth {
    for (health) |h| {
        if (h.node_id == node_id) return h;
    }
    return null;
}

fn wins(a: Candidate, b: Candidate) bool {
    if (a.priority != b.priority) return a.priority < b.priority;
    return a.applied_offset > b.applied_offset;
}

// ── Tests ───────────────────────────────────────────────────────────

test "pickLeader returns null when no follower alive" {
    const data =
        \\node 1 leader 127.0.0.1:6380
        \\node 2 follower 127.0.0.1:6381 priority=1
        \\self 1
        \\
    ;
    var cfg = try cluster_config.parseString(std.testing.allocator, data);
    defer cfg.deinit();

    const health = [_]Health.NodeHealth{
        .{ .node_id = 1, .alive = true, .role = .leader },
        .{ .node_id = 2, .alive = false },
    };

    try std.testing.expect(pickLeader(&cfg, &health) == null);
}

test "pickLeader prefers lower priority number, then higher applied_offset" {
    const data =
        \\node 1 leader 127.0.0.1:6380
        \\node 2 follower 127.0.0.1:6381 priority=2
        \\node 3 follower 127.0.0.1:6382 priority=1
        \\node 4 follower 127.0.0.1:6383 priority=1
        \\self 1
        \\
    ;
    var cfg = try cluster_config.parseString(std.testing.allocator, data);
    defer cfg.deinit();

    const health = [_]Health.NodeHealth{
        .{ .node_id = 1, .alive = true, .role = .leader },
        .{ .node_id = 2, .alive = true, .role = .follower, .applied_offset = 999 },
        .{ .node_id = 3, .alive = true, .role = .follower, .applied_offset = 10 },
        .{ .node_id = 4, .alive = true, .role = .follower, .applied_offset = 50 },
    };

    const chosen = pickLeader(&cfg, &health).?;
    // Node 4 wins: priority=1 (beats node 2's priority=2) and applied=50 (beats node 3's 10).
    try std.testing.expectEqual(@as(u16, 4), chosen.node_id);
}
