const std = @import("std");
const KVStore = @import("engine/kv.zig").KVStore;
const GraphEngine = @import("engine/graph.zig").GraphEngine;
const Server = @import("server/tcp.zig").Server;
const ScaleMode = @import("server/tcp.zig").ScaleMode;
const CommandHandler = @import("command/handler.zig").CommandHandler;
const KeysMode = @import("command/handler.zig").KeysMode;
const snapshot = @import("storage/snapshot.zig");
const aof_mod = @import("storage/aof.zig");
const AOF = aof_mod.AOF;
const span = @import("perf/span.zig");

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
    var prof_state: span.Profile = undefined;
    var prof: ?*span.Profile = null;
    if (config.profile) {
        prof_state = span.Profile.init(io, config.profile_every);
        prof = &prof_state;
    }

    var kv = KVStore.init(allocator, io);
    defer kv.deinit();

    var graph = GraphEngine.init(allocator);
    defer graph.deinit();

    // ── Persistence setup ────────────────────────────────────────────
    std.Io.Dir.cwd().createDirPath(io, config.data_dir) catch |err| {
        log("fatal: cannot create data directory '{s}': {s}", .{ config.data_dir, @errorName(err) });
        return;
    };

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
        aof_instance = aof_tmp;

        var replay_db = std.atomic.Value(u8).init(0);
        var replay_handler = CommandHandler.init(allocator, io, &kv, &graph, null, &replay_db, config.keys_mode);
        replayed = aof_mod.replayFile(io, allocator, aof_path, &replay_handler) catch |err| blk: {
            log("warning: AOF replay failed: {s}", .{@errorName(err)});
            break :blk @as(u64, 0);
        };
        if (config.scale_mode == .scaled and config.engine_threads > 1) {
            var i: usize = 1;
            while (i < config.engine_threads) : (i += 1) {
                const shard_aof_path = try std.fmt.allocPrint(allocator, "{s}.shard{d}", .{ aof_path, i });
                defer allocator.free(shard_aof_path);
                const n = aof_mod.replayFile(io, allocator, shard_aof_path, &replay_handler) catch 0;
                replayed += n;
            }
        }
    }

    printBanner(config.port, kv.dbsize(), graph.nodeCount(), replayed);

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
            snapshot.save(io, allocator, &kv, &graph, a.snapshot_path) catch |err| {
                log("shutdown snapshot failed: {s}", .{@errorName(err)});
            };
            a.truncate() catch {};
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
    no_persistence: bool,
    reactor: bool,
    workers: usize,
    requirepass: ?[]const u8,
    maxclients: u32,
    max_client_buffer: usize,
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
    var no_persistence = false;
    var reactor = false;
    var workers: usize = @min(std.Thread.getCpuCount() catch 4, 8);
    var requirepass: ?[]const u8 = null;
    var maxclients: u32 = 10000;
    var max_client_buffer: usize = 1024 * 1024; // 1MB

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
        .no_persistence = no_persistence,
        .reactor = reactor,
        .workers = workers,
        .requirepass = requirepass,
        .maxclients = maxclients,
        .max_client_buffer = max_client_buffer,
    };
}

fn printBanner(port: u16, kv_keys: usize, graph_nodes: usize, aof_replayed: u64) void {
    const banner =
        \\
        \\   __   __  _____ __  __
        \\   \ \ / / | ____|\ \/ /
        \\    \ V /  |  _|   \  /
        \\     | |   | |___  /  \
        \\     |_|   |_____|/_/\_\
        \\
        \\   KV + Graph Database
        \\   Redis Protocol Compatible | v0.1.0
        \\
    ;
    std.debug.print("{s}", .{banner});
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

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[vex] " ++ fmt ++ "\n", args);
}

test {
    _ = @import("server/resp.zig");
    _ = @import("engine/kv.zig");
    _ = @import("engine/concurrent_kv.zig");
    _ = @import("server/event_loop.zig");
    _ = @import("server/worker.zig");
    _ = @import("engine/graph.zig");
    _ = @import("engine/query.zig");
    _ = @import("command/handler.zig");
    _ = @import("storage/snapshot.zig");
    _ = @import("storage/aof.zig");
    _ = @import("perf/span.zig");
    _ = @import("engine/string_intern.zig");
    _ = @import("engine/pool_arena.zig");
    _ = @import("engine/property_store.zig");
    _ = @import("command/comptime_dispatch.zig");
}
