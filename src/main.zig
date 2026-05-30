const std = @import("std");
const KVStore = @import("engine/kv.zig").KVStore;
const GraphEngine = @import("engine/graph.zig").GraphEngine;
const Server = @import("server/tcp.zig").Server;
const ScaleMode = @import("server/tcp.zig").ScaleMode;
const TlsContext = @import("server/tls.zig").TlsContext;
const CommandHandler = @import("command/handler.zig").CommandHandler;
const KeysMode = @import("command/handler.zig").KeysMode;
const snapshot = @import("storage/snapshot.zig");
const aof_mod = @import("storage/aof.zig");
const AOF = aof_mod.AOF;
const span = @import("perf/span.zig");
const vex_log = @import("log.zig");

// Global state for replication callbacks
// Globals exist for replication callbacks invoked from non-main threads
// (the leader's follower drain threads, the follower's receiver thread).
// Each one is the single thing its callback needs that can't easily be
// passed through the callback signature; all are written once at startup
// and read-only thereafter.
//
// g_kv / g_graph: read by getSnapshot + loadSnapshot
// g_io: read by getSnapshot + loadSnapshot
// g_aof: read by loadSnapshot (truncate-before-full-sync)
// g_data_dir: read by loadSnapshot (atomic-install path for vex.zdb)
// g_local_port: read by executeForwardedWrite (loopback target)
var g_kv: ?*KVStore = null;
var g_graph: ?*GraphEngine = null;
var g_io: ?std.Io = null;
var g_aof: ?*AOF = null;
var g_data_dir: ?[]const u8 = null;

/// Execute a forwarded write by sending it to the local RESP port as a client.
/// This ensures it goes through the worker → ConcurrentKV path (not plain KVStore).
fn executeForwardedWrite(allocator: std.mem.Allocator, args: []const []const u8) ?[]u8 {
    // Connect to ourselves on the RESP port
    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return null;
    defer _ = std.c.close(sock);

    var addr: std.c.sockaddr.in = .{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, g_local_port),
        .addr = 0x0100007f, // 127.0.0.1
    };
    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) < 0) return null;

    // Build RESP command
    var cmd_buf = std.array_list.Managed(u8).init(allocator);
    defer cmd_buf.deinit();
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "*{d}\r\n", .{args.len}) catch return null;
    cmd_buf.appendSlice(h) catch return null;
    for (args) |arg| {
        const ah = std.fmt.bufPrint(&hdr, "${d}\r\n", .{arg.len}) catch return null;
        cmd_buf.appendSlice(ah) catch return null;
        cmd_buf.appendSlice(arg) catch return null;
        cmd_buf.appendSlice("\r\n") catch return null;
    }

    // Send command
    var sent: usize = 0;
    while (sent < cmd_buf.items.len) {
        const rc = std.c.write(sock, cmd_buf.items[sent..].ptr, cmd_buf.items.len - sent);
        if (rc <= 0) return null;
        sent += @intCast(rc);
    }

    // Read response (up to 64KB)
    var resp_buf: [65536]u8 = undefined;
    const rc = std.c.read(sock, &resp_buf, resp_buf.len);
    if (rc <= 0) return null;
    const n: usize = @intCast(rc);

    return allocator.dupe(u8, resp_buf[0..n]) catch null;
}

var g_local_port: u16 = 6380;

/// Get a binary snapshot of KV + Graph for full sync to followers.
fn getSnapshot(allocator: std.mem.Allocator) ?[]u8 {
    const kv_ptr = g_kv orelse return null;
    const graph_ptr = g_graph orelse return null;
    const io = g_io orelse return null;

    // Build snapshot in memory using snapshot module
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    // Use snapshot.save to a temp path, then read the file
    const tmp_path = "/tmp/vex_repl_sync.zdb";
    const kv_snap = kv_ptr.snapshot(allocator) catch return null;
    defer KVStore.freeSnapshot(kv_snap, allocator);
    snapshot.save(io, allocator, kv_snap, graph_ptr, tmp_path) catch return null;

    // Read the snapshot file
    const file = std.Io.Dir.cwd().openFile(io, tmp_path, .{}) catch return null;
    defer file.close(io);
    const len = file.length(io) catch return null;
    const data = allocator.alloc(u8, @intCast(len)) catch return null;
    const n = file.readPositionalAll(io, data, 0) catch {
        allocator.free(data);
        return null;
    };
    if (n != @as(usize, @intCast(len))) {
        allocator.free(data);
        return null;
    }
    return data;
}

/// Load a binary snapshot on the follower.
/// Apply a full-sync snapshot from the leader. The sequence is ordered
/// so a crash at any point leaves vex in a consistent state on restart:
///
///   1. Truncate the local AOF first. If we crash here, restart sees an
///      empty AOF and the old vex.zdb — we lose the brief delta between
///      truncate and snapshot install but won't replay stale records on
///      top of new state.
///   2. Atomically write the new snapshot bytes to <data_dir>/vex.zdb via
///      atomic_io.atomicWrite. After this rename, vex.zdb either has the
///      old content or the new — never partial.
///   3. Load the snapshot into the in-memory KV + Graph.
///
/// On crash between step 2 and 3, restart reads the new vex.zdb correctly.
fn loadSnapshot(data: []const u8) bool {
    const kv_ptr = g_kv orelse return false;
    const graph_ptr = g_graph orelse return false;
    const io = g_io orelse return false;
    const allocator = kv_ptr.allocator;

    // Step 1: truncate the local AOF first so stale records don't replay
    // over the about-to-be-applied snapshot if we crash mid-install.
    if (g_aof) |a| {
        a.truncate() catch |err| {
            vex_log.warn("repl-follower: AOF truncate before full-sync failed: {s}", .{@errorName(err)});
        };
    }

    // Step 2: atomically install the snapshot into the canonical vex.zdb.
    // Without this, full-sync wrote to a temp file that never made it into
    // the data dir — restart would load stale state.
    const dd = g_data_dir orelse {
        vex_log.warn("repl-follower: full-sync requires data-dir", .{});
        return false;
    };
    const final_path = std.fmt.allocPrint(allocator, "{s}/vex.zdb", .{dd}) catch return false;
    defer allocator.free(final_path);
    @import("storage/atomic_io.zig").atomicWrite(allocator, final_path, data) catch |err| {
        vex_log.err("repl-follower: full-sync atomicWrite failed: {s}", .{@errorName(err)});
        return false;
    };

    // Step 3: load the new state into the in-memory engine.
    snapshot.load(io, allocator, kv_ptr, graph_ptr, final_path) catch |err| {
        vex_log.err("repl-follower: full-sync snapshot.load failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

const DEFAULT_HOST = "0.0.0.0";
const DEFAULT_PORT: u16 = 6380;
const DEFAULT_DATA_DIR = "data";

/// Global shutdown flag set by signal handler.
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn installSignalHandlers() void {
    const c = std.c;
    var sa: c.Sigaction = undefined;
    @memset(@as([*]u8, @ptrCast(&sa))[0..@sizeOf(c.Sigaction)], 0);
    sa.handler = .{ .handler = @ptrCast(&struct {
        fn handler(_: c_int) callconv(.c) void {
            shutdown_requested.store(true, .release);
        }
    }.handler) };
    _ = c.sigaction(c.SIG.INT, &sa, null);
    _ = c.sigaction(c.SIG.TERM, &sa, null);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    installSignalHandlers();
    const config = parseArgs(init);
    initGlobalLogger(allocator, config.log_file, config.log_level, config.log_format);
    defer vex_log.global.deinit();
    @import("observability/stats.zig").start_time_ms = nowMillis();
    @import("observability/event_stats.zig").threshold_us.store(config.latency_threshold_us, .monotonic);
    // Cluster epoch — load from `<data_dir>/vex.epoch` if present.
    // Promotion paths persist a new epoch before declaring leadership.
    if (!config.no_persistence) {
        @import("cluster/replication.zig").loadEpoch(allocator, config.data_dir);
        g_data_dir = config.data_dir;
    }
    var prof_state: span.Profile = undefined;
    var prof: ?*span.Profile = null;
    if (config.profile) {
        prof_state = span.Profile.init(io, config.profile_every);
        prof = &prof_state;
    }

    var kv = KVStore.init(allocator, io);
    kv.maxmemory = config.maxmemory;
    kv.eviction_policy = config.maxmemory_policy;
    defer kv.deinit();

    var graph = GraphEngine.init(allocator);
    defer graph.deinit();

    // ── Persistence setup ────────────────────────────────────────────
    if (!config.no_persistence) {
        std.Io.Dir.cwd().createDirPath(io, config.data_dir) catch |err| {
            log("fatal: cannot create data directory '{s}': {s}", .{ config.data_dir, @errorName(err) });
            return;
        };
    }

    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/vex.zdb", .{config.data_dir});
    defer allocator.free(snapshot_path);
    const aof_path = try std.fmt.allocPrint(allocator, "{s}/vex.aof", .{config.data_dir});
    defer allocator.free(aof_path);

    var aof_instance: ?AOF = null;
    defer if (aof_instance) |*a| a.deinit();
    var replayed: u64 = 0;
    if (!config.no_persistence) {
        snapshot.load(io, allocator, &kv, &graph, snapshot_path) catch |err| {
            log("warning: snapshot load failed: {s}", .{@errorName(err)});
        };

        var aof_tmp = AOF.init(io, aof_path, snapshot_path) catch |err| {
            log("fatal: cannot open AOF '{s}': {s}", .{ aof_path, @errorName(err) });
            return;
        };
        aof_tmp.prof = prof;
        aof_tmp.initGroupBuf(allocator);
        aof_instance = aof_tmp;
        if (aof_instance) |*a| {
            a.setFsyncMode(allocator, config.appendfsync);
            g_aof = a;
        }
        vex_log.info("aof: appendfsync={s}", .{config.appendfsync.label()});

        var replay_db = std.atomic.Value(u8).init(0);
        var replay_handler = CommandHandler.init(allocator, io, &kv, &graph, null, &replay_db, config.keys_mode);
        replayed = aof_mod.replayFile(io, allocator, aof_path, &replay_handler) catch |err| blk: {
            log("warning: AOF replay failed: {s}", .{@errorName(err)});
            break :blk @as(u64, 0);
        };
        // Replay shard AOFs — used by both scaled mode and reactor per-worker shards
        const shard_count: usize = if (config.scale_mode == .scaled and config.engine_threads > 1)
            config.engine_threads
        else if (config.reactor and config.workers > 1)
            config.workers
        else
            1;
        if (shard_count > 1) {
            var i: usize = 1;
            while (i < shard_count) : (i += 1) {
                const shard_aof_path = try std.fmt.allocPrint(allocator, "{s}.shard{d}", .{ aof_path, i });
                defer allocator.free(shard_aof_path);
                const n = aof_mod.replayFile(io, allocator, shard_aof_path, &replay_handler) catch 0;
                replayed += n;
            }
        }
    }

    // ── TLS setup ────────────────────────────────────────────────────
    var tls_ctx: ?TlsContext = null;
    if (config.tls_cert) |cert| {
        if (config.tls_key) |key| {
            const cert_z = try allocator.dupeSentinel(u8, cert, 0);
            defer allocator.free(cert_z);
            const key_z = try allocator.dupeSentinel(u8, key, 0);
            defer allocator.free(key_z);
            tls_ctx = TlsContext.init(cert_z, key_z) catch |err| blk: {
                log("warning: TLS init failed: {s} (running without TLS)", .{@errorName(err)});
                break :blk null;
            };
        } else {
            log("warning: --tls-cert requires --tls-key (running without TLS)", .{});
        }
    }
    defer if (tls_ctx) |*t| t.deinit();

    // ── Cluster setup ─────────────────────────────────────────────────
    const cluster_config_mod = @import("cluster/config.zig");
    const ReplMod = @import("cluster/replication.zig");

    var cluster_conf: ?cluster_config_mod.ClusterConfig = null;
    defer if (cluster_conf) |*cc| cc.deinit();

    var repl_leader: ?ReplMod.ReplicationLeader = null;
    defer if (repl_leader) |*rl| rl.deinit();
    var repl_follower: ?ReplMod.ReplicationFollower = null;
    defer if (repl_follower) |*rf| rf.deinit();

    if (config.cluster_config) |cc_path| {
        cluster_conf = cluster_config_mod.parse(allocator, io, cc_path) catch |err| blk: {
            log("warning: cluster config parse failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        if (cluster_conf) |*cc| {
            // Set globals for replication callbacks
            g_kv = &kv;
            g_graph = &graph;
            g_io = io;
            g_local_port = config.port;

            // Determine effective role: config says leader, but probe first
            // to check if another node already claimed leadership (old leader rejoining).
            var start_as_leader = cc.isLeader();
            if (start_as_leader) {
                if (ReplMod.probeForLeader(allocator, cc)) |existing| {
                    log("cluster: config says leader, but node {d} is already leader — starting as FOLLOWER", .{existing.id});
                    start_as_leader = false;
                }
            }

            if (start_as_leader) {
                log("cluster mode: LEADER (node {d})", .{cc.self_id});

                repl_leader = ReplMod.ReplicationLeader.init(allocator, cc, config.port);
                repl_leader.?.execute_fn = executeForwardedWrite;
                repl_leader.?.snapshot_fn = getSnapshot;
                repl_leader.?.start() catch |err| {
                    log("warning: replication listener failed: {s}", .{@errorName(err)});
                };
                ReplMod.current_leader_ptr.store(&repl_leader.?, .release);
            } else {
                log("cluster mode: FOLLOWER (node {d})", .{cc.self_id});
                repl_follower = ReplMod.ReplicationFollower.init(allocator, cc, config.port);
                repl_follower.?.load_snapshot_fn = loadSnapshot;
                repl_follower.?.connectToLeader() catch |err| {
                    log("warning: cannot connect to leader: {s}", .{@errorName(err)});
                };
                repl_follower.?.start() catch |err| {
                    log("warning: replication receiver failed: {s}", .{@errorName(err)});
                };
                ReplMod.current_follower_ptr.store(&repl_follower.?, .release);
            }
        }
    }

    // ── Load vector files (mmap'd .vvf) — parallel with AOF replay when possible ──
    // Vector load already overlapped: if called after AOF replay, it benefits from
    // parallel HNSW index rebuild within loadVectors(). On large datasets with many
    // vector fields, this saves significant startup time.
    if (!config.no_persistence) {
        graph.loadVectors(config.data_dir) catch |err| {
            log("warning: vector load failed: {s}", .{@errorName(err)});
        };
    }

    printBanner(config.port, kv.dbsize(), graph.nodeCount(), replayed);
    vex_log.info(
        "vex v{s} ready: port={d} kv_keys={d} graph_nodes={d} aof_replayed={d}",
        .{ @import("root.zig").VERSION, config.port, kv.dbsize(), graph.nodeCount(), replayed },
    );

    var server = try Server.init(
        allocator,
        io,
        &kv,
        &graph,
        if (aof_instance) |*a| a else null,
        config.host,
        config.port,
        config.keys_mode,
        prof,
        config.scale_mode,
        config.engine_threads,
        config.cluster_config,
        config.requirepass,
        config.maxclients,
        config.max_client_buffer,
        if (tls_ctx) |*t| t else null,
        if (repl_follower) |*rf| rf else null,
        if (repl_leader) |*rl| rl else null,
        config.unixsocket,
        if (config.no_persistence) null else config.data_dir,
        config.enable_timings,
        config.slowlog_threshold_us,
    );
    if (config.reactor) {
        server.runReactor(config.workers, &shutdown_requested) catch |err| {
            log("server error: {s}", .{@errorName(err)});
        };
    } else {
        server.run() catch |err| {
            log("server error: {s}", .{@errorName(err)});
        };
    }

    // Graceful shutdown: save state before exit
    log("shutting down...", .{});
    if (!config.no_persistence) {
        if (aof_instance) |*a| {
            if (kv.snapshot(allocator)) |kv_snap| {
                defer KVStore.freeSnapshot(kv_snap, allocator);
                snapshot.save(io, allocator, kv_snap, &graph, a.snapshot_path) catch |err| {
                    log("shutdown snapshot failed: {s}", .{@errorName(err)});
                };
            } else |err| {
                log("shutdown kv snapshot failed: {s}", .{@errorName(err)});
            }
            a.truncate() catch {};
            graph.saveVectors(config.data_dir) catch |err| {
                log("shutdown vector save failed: {s}", .{@errorName(err)});
            };
            log("state saved", .{});
        }
    }
}

const Config = struct {
    host: []const u8,
    port: u16,
    data_dir: []const u8,
    keys_mode: KeysMode,
    profile: bool,
    profile_every: u64,
    scale_mode: ScaleMode,
    engine_threads: usize,
    cluster_config: ?[]const u8,
    unixsocket: ?[]const u8,
    no_persistence: bool,
    reactor: bool,
    workers: usize,
    requirepass: ?[]const u8,
    maxclients: u32,
    max_client_buffer: usize,
    tls_cert: ?[]const u8,
    tls_key: ?[]const u8,
    maxmemory: usize,
    maxmemory_policy: @import("engine/kv.zig").EvictionPolicy,
    log_level: vex_log.Level,
    log_file: ?[]const u8,
    log_format: vex_log.Format,
    enable_timings: bool,
    slowlog_threshold_us: u64,
    latency_threshold_us: u64,
    appendfsync: aof_mod.FsyncMode,
};

fn parseArgs(init: std.process.Init) Config {
    var host: []const u8 = DEFAULT_HOST;
    var port: u16 = DEFAULT_PORT;
    var data_dir: []const u8 = DEFAULT_DATA_DIR;
    var keys_mode: KeysMode = .strict;
    var profile = false;
    var profile_every: u64 = 100_000;
    var scale_mode: ScaleMode = .scaled;
    var engine_threads: usize = 1;
    var cluster_config: ?[]const u8 = null;
    var unixsocket: ?[]const u8 = null;
    var no_persistence = false;
    var reactor = false;
    var workers: usize = @min(std.Thread.getCpuCount() catch 4, 8);
    var requirepass: ?[]const u8 = null;
    var maxclients: u32 = 10000;
    var max_client_buffer: usize = 1024 * 1024; // 1MB
    var tls_cert: ?[]const u8 = null;
    var tls_key: ?[]const u8 = null;
    var maxmemory: usize = 0;
    var maxmemory_policy: @import("engine/kv.zig").EvictionPolicy = .noeviction;
    var log_level: vex_log.Level = .info;
    var log_file: ?[]const u8 = null;
    var log_format: vex_log.Format = .text;
    var enable_timings: bool = false;
    var slowlog_threshold_us: u64 = 10_000; // 10ms — Redis default
    var latency_threshold_us: u64 = 100_000; // 100ms — Redis default
    var appendfsync: aof_mod.FsyncMode = .everysec; // Redis default

    // ── Config file loading (order: default vex.conf → VEX_CONFIG env → --config flag)
    // Each source overrides the previous; CLI args override everything.
    {
        // 1. Try default config file: ./vex.conf
        applyConfigFile(init.io, "vex.conf", &host, &port, &data_dir, &requirepass,
            &maxclients, &max_client_buffer, &maxmemory, &maxmemory_policy,
            &reactor, &workers, &log_level, &tls_cert, &tls_key, &log_file, &log_format,
            &enable_timings, &slowlog_threshold_us, &latency_threshold_us, &appendfsync);

        // 2. Try VEX_CONFIG environment variable
        const env_config = std.c.getenv("VEX_CONFIG");
        if (env_config) |env_path| {
            const path = std.mem.span(env_path);
            if (path.len > 0) {
                applyConfigFile(init.io, path, &host, &port, &data_dir, &requirepass,
                    &maxclients, &max_client_buffer, &maxmemory, &maxmemory_policy,
                    &reactor, &workers, &log_level, &tls_cert, &tls_key, &log_file, &log_format,
            &enable_timings, &slowlog_threshold_us, &latency_threshold_us, &appendfsync);
            }
        }

        // 3. Explicit --config flag (highest priority among config files)
        var pre_it = std.process.Args.Iterator.init(init.minimal.args);
        defer pre_it.deinit();
        _ = pre_it.skip();
        while (pre_it.next()) |pre_arg_z| {
            const pre_arg = std.mem.sliceTo(pre_arg_z, 0);
            if (std.mem.eql(u8, pre_arg, "--config")) {
                if (pre_it.next()) |cfg_path_z| {
                    const cfg_path = std.mem.sliceTo(cfg_path_z, 0);
                    applyConfigFile(init.io, cfg_path, &host, &port, &data_dir, &requirepass,
                        &maxclients, &max_client_buffer, &maxmemory, &maxmemory_policy,
                        &reactor, &workers, &log_level, &tls_cert, &tls_key, &log_file, &log_format,
            &enable_timings, &slowlog_threshold_us, &latency_threshold_us, &appendfsync);
                }
                break;
            }
        }
    }

    // ── Second pass: CLI args override config file ───────────────────
    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    _ = it.skip();

    while (it.next()) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (it.next()) |p| {
                port = std.fmt.parseInt(u16, std.mem.sliceTo(p, 0), 10) catch DEFAULT_PORT;
            }
        } else if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-h")) {
            if (it.next()) |h| {
                host = std.mem.sliceTo(h, 0);
            }
        } else if (std.mem.eql(u8, arg, "--data-dir") or std.mem.eql(u8, arg, "-d")) {
            if (it.next()) |d| {
                data_dir = std.mem.sliceTo(d, 0);
            }
        } else if (std.mem.eql(u8, arg, "--keys-mode")) {
            if (it.next()) |m| {
                const mode = std.mem.sliceTo(m, 0);
                if (std.mem.eql(u8, mode, "autoscan")) {
                    keys_mode = .autoscan;
                } else {
                    keys_mode = .strict;
                }
            }
        } else if (std.mem.eql(u8, arg, "--profile")) {
            profile = true;
        } else if (std.mem.eql(u8, arg, "--profile-every")) {
            if (it.next()) |n| {
                profile_every = std.fmt.parseInt(u64, std.mem.sliceTo(n, 0), 10) catch profile_every;
            }
        } else if (std.mem.eql(u8, arg, "--mode")) {
            if (it.next()) |m| {
                const mode = std.mem.sliceTo(m, 0);
                if (std.mem.eql(u8, mode, "cluster")) {
                    scale_mode = .cluster;
                } else {
                    scale_mode = .scaled;
                }
            }
        } else if (std.mem.eql(u8, arg, "--engine-threads")) {
            if (it.next()) |n| {
                engine_threads = std.fmt.parseInt(usize, std.mem.sliceTo(n, 0), 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--cluster-config")) {
            if (it.next()) |p| {
                cluster_config = std.mem.sliceTo(p, 0);
            }
        } else if (std.mem.eql(u8, arg, "--unixsocket")) {
            if (it.next()) |p| {
                unixsocket = std.mem.sliceTo(p, 0);
            }
        } else if (std.mem.eql(u8, arg, "--no-persistence")) {
            no_persistence = true;
        } else if (std.mem.eql(u8, arg, "--reactor")) {
            reactor = true;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            if (it.next()) |n| {
                workers = std.fmt.parseInt(usize, std.mem.sliceTo(n, 0), 10) catch 4;
            }
        } else if (std.mem.eql(u8, arg, "--requirepass")) {
            if (it.next()) |p| {
                requirepass = std.mem.sliceTo(p, 0);
            }
        } else if (std.mem.eql(u8, arg, "--maxclients")) {
            if (it.next()) |n| {
                maxclients = std.fmt.parseInt(u32, std.mem.sliceTo(n, 0), 10) catch 10000;
            }
        } else if (std.mem.eql(u8, arg, "--max-client-buffer")) {
            if (it.next()) |n| {
                max_client_buffer = std.fmt.parseInt(usize, std.mem.sliceTo(n, 0), 10) catch 1024 * 1024;
            }
        } else if (std.mem.eql(u8, arg, "--tls-cert")) {
            if (it.next()) |p| {
                tls_cert = std.mem.sliceTo(p, 0);
            }
        } else if (std.mem.eql(u8, arg, "--tls-key")) {
            if (it.next()) |p| {
                tls_key = std.mem.sliceTo(p, 0);
            }
        } else if (std.mem.eql(u8, arg, "--config")) {
            // Already handled in first pass, skip the value
            _ = it.next();
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            if (it.next()) |l| {
                log_level = vex_log.Level.parse(std.mem.sliceTo(l, 0));
            }
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            if (it.next()) |p| {
                const s = std.mem.sliceTo(p, 0);
                log_file = if (std.mem.eql(u8, s, "-")) null else s;
            }
        } else if (std.mem.eql(u8, arg, "--log-format")) {
            if (it.next()) |f| {
                log_format = vex_log.Format.parse(std.mem.sliceTo(f, 0));
            }
        } else if (std.mem.eql(u8, arg, "--enable-timings")) {
            enable_timings = true;
        } else if (std.mem.eql(u8, arg, "--slowlog-log-slower-than")) {
            if (it.next()) |n| {
                slowlog_threshold_us = std.fmt.parseInt(u64, std.mem.sliceTo(n, 0), 10) catch slowlog_threshold_us;
            }
        } else if (std.mem.eql(u8, arg, "--latency-monitor-threshold")) {
            if (it.next()) |n| {
                latency_threshold_us = std.fmt.parseInt(u64, std.mem.sliceTo(n, 0), 10) catch latency_threshold_us;
            }
        } else if (std.mem.eql(u8, arg, "--appendfsync")) {
            if (it.next()) |v| appendfsync = aof_mod.FsyncMode.parse(std.mem.sliceTo(v, 0));
        } else if (std.mem.eql(u8, arg, "--maxmemory")) {
            if (it.next()) |n| {
                maxmemory = std.fmt.parseInt(usize, std.mem.sliceTo(n, 0), 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--maxmemory-policy")) {
            if (it.next()) |p| {
                const pol = std.mem.sliceTo(p, 0);
                if (std.mem.eql(u8, pol, "allkeys-lru")) {
                    maxmemory_policy = .allkeys_lru;
                } else {
                    maxmemory_policy = .noeviction;
                }
            }
        }
    }

    return .{
        .host = host,
        .port = port,
        .data_dir = data_dir,
        .keys_mode = keys_mode,
        .profile = profile,
        .profile_every = profile_every,
        .scale_mode = scale_mode,
        .engine_threads = engine_threads,
        .cluster_config = cluster_config,
        .unixsocket = unixsocket,
        .no_persistence = no_persistence,
        .reactor = reactor,
        .workers = workers,
        .requirepass = requirepass,
        .maxclients = maxclients,
        .max_client_buffer = max_client_buffer,
        .tls_cert = tls_cert,
        .tls_key = tls_key,
        .maxmemory = maxmemory,
        .maxmemory_policy = maxmemory_policy,
        .log_level = log_level,
        .log_file = log_file,
        .log_format = log_format,
        .enable_timings = enable_timings,
        .slowlog_threshold_us = slowlog_threshold_us,
        .latency_threshold_us = latency_threshold_us,
        .appendfsync = appendfsync,
    };
}

fn printBanner(port: u16, kv_keys: usize, graph_nodes: usize, aof_replayed: u64) void {
    const banner =
        \\
        \\ __     __ _____  __  __
        \\ \ \   / /| ____| \ \/ /
        \\  \ \ / / |  _|    \  /
        \\   \ V /  | |___   /  \
        \\    \_/   |_____| /_/\_\
        \\
        \\   KV + Graph Database
    ;
    std.debug.print("{s}\n", .{banner});
    std.debug.print("   Redis Protocol Compatible | v{s}\n", .{@import("root.zig").VERSION});
    std.debug.print("   Listening on port {d}\n", .{port});
    std.debug.print("   Connect with: redis-cli -p {d}\n", .{port});

    if (kv_keys > 0 or graph_nodes > 0 or aof_replayed > 0) {
        std.debug.print("   Restored {d} keys, {d} nodes", .{ kv_keys, graph_nodes });
        if (aof_replayed > 0) {
            std.debug.print(" (+{d} AOF commands)", .{aof_replayed});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}

fn applyConfigFile(
    io: std.Io,
    cfg_path: []const u8,
    host: *[]const u8,
    port: *u16,
    data_dir: *[]const u8,
    requirepass: *?[]const u8,
    maxclients: *u32,
    max_client_buffer: *usize,
    maxmemory: *usize,
    maxmemory_policy: *@import("engine/kv.zig").EvictionPolicy,
    reactor: *bool,
    workers: *usize,
    log_level: *vex_log.Level,
    tls_cert: *?[]const u8,
    tls_key: *?[]const u8,
    log_file: *?[]const u8,
    log_format: *vex_log.Format,
    enable_timings: *bool,
    slowlog_threshold_us: *u64,
    latency_threshold_us: *u64,
    appendfsync: *aof_mod.FsyncMode,
) void {
    const config_mod = @import("config.zig");
    // Use a page allocator since we can't access the gpa in parseArgs easily.
    // Config values are string slices that live for the process lifetime.
    var cfg = config_mod.ConfigFile.loadFile(std.heap.page_allocator, io, cfg_path) catch |err| {
        // Silently skip file-not-found (for default vex.conf / optional env var)
        if (err != error.FileNotFound) {
            vex_log.warn("cannot load config file '{s}': {s}", .{ cfg_path, @errorName(err) });
        }
        return;
    };
    // Note: we intentionally don't deinit cfg — the strings are used by the Config struct
    // for the process lifetime. In a short-lived server this is fine.

    if (cfg.get("port")) |v| port.* = std.fmt.parseInt(u16, v, 10) catch port.*;
    if (cfg.get("host") orelse cfg.get("bind")) |v| host.* = v;
    if (cfg.get("data-dir") orelse cfg.get("dir")) |v| data_dir.* = v;
    if (cfg.get("requirepass")) |v| requirepass.* = v;
    if (cfg.get("maxclients")) |v| maxclients.* = std.fmt.parseInt(u32, v, 10) catch maxclients.*;
    if (cfg.get("max-client-buffer")) |v| max_client_buffer.* = std.fmt.parseInt(usize, v, 10) catch max_client_buffer.*;
    if (cfg.get("maxmemory")) |v| maxmemory.* = parseMemorySize(v);
    if (cfg.get("maxmemory-policy")) |v| {
        if (std.mem.eql(u8, v, "allkeys-lru")) maxmemory_policy.* = .allkeys_lru;
    }
    if (cfg.get("reactor")) |_| reactor.* = true;
    if (cfg.get("workers")) |v| workers.* = std.fmt.parseInt(usize, v, 10) catch workers.*;
    if (cfg.get("log-level") orelse cfg.get("loglevel")) |v| log_level.* = vex_log.Level.parse(v);
    if (cfg.get("log-file") orelse cfg.get("logfile")) |v| {
        log_file.* = if (std.mem.eql(u8, v, "-") or v.len == 0) null else v;
    }
    if (cfg.get("log-format") orelse cfg.get("logformat")) |v| log_format.* = vex_log.Format.parse(v);
    if (cfg.get("enable-timings")) |v| {
        enable_timings.* = !(std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no"));
    }
    if (cfg.get("slowlog-log-slower-than")) |v| {
        slowlog_threshold_us.* = std.fmt.parseInt(u64, v, 10) catch slowlog_threshold_us.*;
    }
    if (cfg.get("latency-monitor-threshold")) |v| {
        latency_threshold_us.* = std.fmt.parseInt(u64, v, 10) catch latency_threshold_us.*;
    }
    if (cfg.get("appendfsync")) |v| appendfsync.* = aof_mod.FsyncMode.parse(v);
    if (cfg.get("tls-cert")) |v| tls_cert.* = v;
    if (cfg.get("tls-key")) |v| tls_key.* = v;
}

/// Parse memory size with optional suffix: "256mb", "1gb", "1024" (bytes)
pub fn parseMemorySize(s: []const u8) usize {
    if (s.len == 0) return 0;
    var end = s.len;
    var multiplier: usize = 1;
    if (s.len >= 2) {
        const last2 = s[s.len - 2 ..];
        if (std.ascii.eqlIgnoreCase(last2, "mb")) {
            multiplier = 1024 * 1024;
            end = s.len - 2;
        } else if (std.ascii.eqlIgnoreCase(last2, "gb")) {
            multiplier = 1024 * 1024 * 1024;
            end = s.len - 2;
        } else if (std.ascii.eqlIgnoreCase(last2, "kb")) {
            multiplier = 1024;
            end = s.len - 2;
        }
    }
    const n = std.fmt.parseInt(usize, s[0..end], 10) catch return 0;
    return n * multiplier;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    vex_log.info(fmt, args);
}

fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn initGlobalLogger(
    allocator: std.mem.Allocator,
    log_file: ?[]const u8,
    level: vex_log.Level,
    format: vex_log.Format,
) void {
    const path = log_file orelse {
        vex_log.global = vex_log.Logger.initStderr(level, format);
        return;
    };
    const path_z = allocator.dupeSentinel(u8, path, 0) catch {
        vex_log.global = vex_log.Logger.initStderr(level, format);
        vex_log.warn("cannot allocate log-file path; logs going to stderr", .{});
        return;
    };
    defer allocator.free(path_z);
    vex_log.global = vex_log.Logger.initFile(path_z, level, format) catch |err| {
        vex_log.global = vex_log.Logger.initStderr(level, format);
        vex_log.warn("cannot open log-file '{s}': {s}; logs going to stderr", .{ path, @errorName(err) });
        return;
    };
}
