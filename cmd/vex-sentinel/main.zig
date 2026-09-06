//! vex-sentinel: failover orchestrator for a vex cluster.
//!
//! v1 responsibility per the stability plan:
//!   1. Poll every vex node in the cluster config (PING + VEX.STATUS).
//!   2. Detect dead leader (N consecutive missed polls).
//!   3. Elect the highest-priority alive follower.
//!   4. Increment the cluster epoch and call VEX.PROMOTE <epoch> on it.
//!   5. Persist (leader_node_id, epoch) atomically.
//!   6. Serve GET /leader so clients discover the current leader.
//!
//! This file wires the scaffold together: parse args, open the logger,
//! load cluster + state, spawn the poller and the HTTP server, then sit
//! in the main thread waiting for SIGINT/SIGTERM. The control loop that
//! ties polls → election → VEX.PROMOTE → state.save is a TODO body.

const std = @import("std");
const vex_log = @import("vex_log");
const cluster_config = @import("vex_cluster_config");

const health_mod = @import("health.zig");
const http_mod = @import("http.zig");
const state_mod = @import("state.zig");
const quorum_mod = @import("quorum.zig");
const election_mod = @import("election.zig");

const Args = struct {
    cluster_config_path: []const u8 = "sentinel-cluster.conf",
    state_path: []const u8 = "sentinel.state",
    http_port: u16 = 26380,
    log_level: vex_log.Level = .info,
};

fn parseArgs(init: std.process.Init) Args {
    var out = Args{};
    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    _ = it.skip();
    while (it.next()) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.eql(u8, arg, "--cluster")) {
            if (it.next()) |v| out.cluster_config_path = std.mem.sliceTo(v, 0);
        } else if (std.mem.eql(u8, arg, "--state")) {
            if (it.next()) |v| out.state_path = std.mem.sliceTo(v, 0);
        } else if (std.mem.eql(u8, arg, "--http-port")) {
            if (it.next()) |v| {
                out.http_port = std.fmt.parseInt(u16, std.mem.sliceTo(v, 0), 10) catch out.http_port;
            }
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            if (it.next()) |v| out.log_level = vex_log.Level.parse(std.mem.sliceTo(v, 0));
        }
    }
    return out;
}

var g_stop = std.atomic.Value(bool).init(false);

fn installSignalHandlers() void {
    const c = std.c;
    var sa: c.Sigaction = undefined;
    @memset(@as([*]u8, @ptrCast(&sa))[0..@sizeOf(c.Sigaction)], 0);
    sa.handler = .{ .handler = @ptrCast(&struct {
        fn handler(_: c_int) callconv(.c) void {
            g_stop.store(true, .release);
        }
    }.handler) };
    _ = c.sigaction(c.SIG.INT, &sa, null);
    _ = c.sigaction(c.SIG.TERM, &sa, null);
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&ts, &rem);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = parseArgs(init);

    vex_log.global = vex_log.Logger.initStderr(args.log_level, .text);
    vex_log.info("vex-sentinel starting (cluster={s}, state={s}, http=:{d})", .{
        args.cluster_config_path, args.state_path, args.http_port,
    });

    // Cluster config — reused from src/cluster/config.zig.
    var cluster = cluster_config.parse(allocator, io, args.cluster_config_path) catch |err| {
        vex_log.err("failed to load cluster config '{s}': {s}", .{ args.cluster_config_path, @errorName(err) });
        return err;
    };
    defer cluster.deinit();
    vex_log.info("loaded cluster: {d} nodes", .{cluster.nodes.len});

    // Persisted state.
    var state = state_mod.Store.init(allocator, args.state_path);
    state.load() catch |err| {
        vex_log.warn("state load failed ({s}); starting fresh", .{@errorName(err)});
    };
    vex_log.info("state: leader_id={d}, epoch={d}", .{ state.current.leader_node_id, state.current.epoch });

    // Health poller.
    var poller = try health_mod.Poller.init(allocator, &cluster, .{});
    defer poller.deinit();
    try poller.start();

    // HTTP server.
    var http = http_mod.Server.init(allocator, args.http_port);
    defer http.deinit();
    try http.start();

    // Seed the HTTP server with the persisted leader so /leader returns
    // a useful answer immediately on restart (no startup blackout window).
    if (state.current.leader_node_id != 0) {
        for (cluster.nodes) |n| {
            if (n.id == state.current.leader_node_id) {
                http.setLeader(.{
                    .node_id = n.id,
                    .host = n.host,
                    .port = n.port,
                    .epoch = state.current.epoch,
                });
                break;
            }
        }
    }

    // Install signal handlers so Ctrl-C shuts us down cleanly.
    installSignalHandlers();

    // Main loop. Tomorrow's controller goes here: snapshot poller.health,
    // detect a dead leader, run quorum + election, send VEX.PROMOTE, save
    // state, update http.setLeader.
    const q = quorum_mod.Quorum{ .peer_count = 0 };
    while (!g_stop.load(.acquire)) {
        sleepMs(1000);
        // TODO: control loop. Sketch:
        //   if (poller.currentLeader() == null and q.canAct(0)) {
        //       const pick = election_mod.pickLeader(&cluster, poller.health) orelse continue;
        //       const new_epoch = state.current.epoch + 1;
        //       sendPromote(cluster, pick.node_id, new_epoch) catch continue;
        //       try state.save(.{ .leader_node_id = pick.node_id, .epoch = new_epoch, ... });
        //       http.setLeader(...);
        //   }
        _ = q;
        _ = election_mod;
    }

    vex_log.info("vex-sentinel shutting down", .{});
}
