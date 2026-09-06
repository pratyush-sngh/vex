//! Per-node health tracking. Polls each vex node every `interval_ms` with
//! PING + VEX.STATUS and updates the alive-set.
//!
//! Scaffold: type surface + a no-op tick() that just rolls a counter.
//! The real RESP client + parse path lands in a follow-up PR.

const std = @import("std");
const vex_log = @import("vex_log");
const cluster_config = @import("vex_cluster_config");
const Allocator = std.mem.Allocator;

/// What we know about a single vex node from its last poll.
pub const NodeHealth = struct {
    node_id: u16,
    alive: bool = false,
    /// Number of consecutive failed polls. Once this reaches `dead_after`,
    /// `alive` flips to false.
    consecutive_failures: u32 = 0,
    /// Last successful poll, monotonic ms. Zero = never seen alive.
    last_seen_monotonic_ms: i64 = 0,
    /// Last-known role from VEX.STATUS reply.
    role: Role = .unknown,
    /// Last-known epoch from VEX.STATUS reply.
    epoch: u64 = 0,
    /// Replication offset reported by the node.
    repl_offset: u64 = 0,
    /// Applied seq reported by the node (followers).
    applied_offset: u64 = 0,

    pub const Role = enum { unknown, leader, follower };
};

pub const Options = struct {
    /// Poll interval. 1s in the plan.
    interval_ms: u64 = 1000,
    /// Mark dead after this many consecutive failures. 3 in the plan = 15s
    /// at the default poll interval — but interval is 1s so this is ~3s.
    /// Tune in real config.
    dead_after: u32 = 3,
    /// Per-poll TCP connect + read timeout.
    poll_timeout_ms: u64 = 500,
};

pub const Poller = struct {
    allocator: Allocator,
    cfg: *const cluster_config.ClusterConfig,
    opts: Options,
    /// One NodeHealth per cluster node, indexed the same as `cfg.nodes`.
    health: []NodeHealth,
    /// Stop flag for the background thread. Polled at the top of each tick.
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: Allocator, cfg: *const cluster_config.ClusterConfig, opts: Options) !Poller {
        const health = try allocator.alloc(NodeHealth, cfg.nodes.len);
        for (cfg.nodes, 0..) |n, i| {
            health[i] = .{ .node_id = n.id };
        }
        return .{ .allocator = allocator, .cfg = cfg, .opts = opts, .health = health };
    }

    pub fn deinit(self: *Poller) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.allocator.free(self.health);
    }

    /// Start the background poll thread. Cheap — one OS thread.
    pub fn start(self: *Poller) !void {
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    fn runLoop(self: *Poller) void {
        while (!self.stop.load(.acquire)) {
            self.tickOnce();
            sleepMs(self.opts.interval_ms);
        }
    }

    /// One poll round across every node. TODO: open TCP, send PING + VEX.STATUS,
    /// parse RESP reply via vex_resp, update NodeHealth.
    pub fn tickOnce(self: *Poller) void {
        _ = self;
        // Scaffold: real polling lives in a follow-up PR. See plan slice
        // "sentinel/ skeleton" — Batch D.
    }

    /// Snapshot the current alive set. Caller owns the returned slice.
    pub fn aliveNodeIds(self: *const Poller, out: []u16) usize {
        var n: usize = 0;
        for (self.health) |h| {
            if (h.alive and n < out.len) {
                out[n] = h.node_id;
                n += 1;
            }
        }
        return n;
    }

    /// Find the current believed-alive leader (highest epoch wins on ties).
    pub fn currentLeader(self: *const Poller) ?NodeHealth {
        var best: ?NodeHealth = null;
        for (self.health) |h| {
            if (!h.alive or h.role != .leader) continue;
            if (best == null or h.epoch > best.?.epoch) best = h;
        }
        return best;
    }
};

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&ts, &rem);
}

// ── Tests ───────────────────────────────────────────────────────────

test "Poller init allocates one NodeHealth per node" {
    const data =
        \\node 1 leader 127.0.0.1:6380
        \\node 2 follower 127.0.0.1:6381
        \\self 1
        \\
    ;
    var cfg = try cluster_config.parseString(std.testing.allocator, data);
    defer cfg.deinit();

    var poller = try Poller.init(std.testing.allocator, &cfg, .{});
    defer poller.deinit();

    try std.testing.expectEqual(@as(usize, 2), poller.health.len);
    try std.testing.expectEqual(@as(u16, 1), poller.health[0].node_id);
    try std.testing.expectEqual(@as(u16, 2), poller.health[1].node_id);
    try std.testing.expect(!poller.health[0].alive);
}

test "currentLeader picks alive leader with highest epoch" {
    const data =
        \\node 1 leader 127.0.0.1:6380
        \\node 2 follower 127.0.0.1:6381
        \\self 1
        \\
    ;
    var cfg = try cluster_config.parseString(std.testing.allocator, data);
    defer cfg.deinit();

    var poller = try Poller.init(std.testing.allocator, &cfg, .{});
    defer poller.deinit();

    try std.testing.expect(poller.currentLeader() == null);

    poller.health[0].alive = true;
    poller.health[0].role = .leader;
    poller.health[0].epoch = 5;
    const l = poller.currentLeader().?;
    try std.testing.expectEqual(@as(u16, 1), l.node_id);
    try std.testing.expectEqual(@as(u64, 5), l.epoch);
}
