//! Multi-sentinel quorum: only act on a failover decision if a strict
//! majority of sentinel peers agree the current leader is dead.
//!
//! v1 of vex-sentinel is single-instance — `peer_count == 0` means
//! quorum is trivially satisfied. Multi-sentinel agreement is v2 (a
//! separate gossip/voting protocol lands in its own PR).
//!
//! This module is intentionally tiny in v1: it exists so call sites
//! that should consult quorum already do, and the upgrade to real
//! voting is a body change instead of a structural one.

const std = @import("std");

pub const Quorum = struct {
    /// Number of other sentinel instances in the deployment.
    peer_count: usize = 0,

    /// Returns true when we have permission to act.
    /// v1: always true (no peers, we are the sole authority).
    /// v2: tallies peer votes via a side channel and returns true when
    ///     more than peer_count/2 peers concur.
    pub fn canAct(self: Quorum, agreeing_peers: usize) bool {
        if (self.peer_count == 0) return true;
        return agreeing_peers * 2 > self.peer_count;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "v1 single sentinel always passes" {
    const q = Quorum{ .peer_count = 0 };
    try std.testing.expect(q.canAct(0));
}

test "v2 majority rule" {
    const q = Quorum{ .peer_count = 3 };
    try std.testing.expect(!q.canAct(1));
    try std.testing.expect(q.canAct(2));
    try std.testing.expect(q.canAct(3));
}
