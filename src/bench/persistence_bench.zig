const std = @import("std");
const app = @import("app");
const KVStore = app.kv.KVStore;
const GraphEngine = app.graph.GraphEngine;
const snapshot = app.snapshot;
const aof_mod = app.aof;

const BenchCfg = struct {
    warmup: usize = 1,
    timed: usize = 5,
};

const DatasetCfg = struct {
    kv_count: usize = 50_000,
    node_count: usize = 10_000,
    edge_count: usize = 20_000,
    aof_ops: usize = 50_000,
};

const Stats = struct {
    min_ms: f64,
    p50_ms: f64,
    p95_ms: f64,
    max_ms: f64,
    mean_ms: f64,
};

fn nsToMs(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn monotonicNs(t0: std.Io.Clock.Timestamp, t1: std.Io.Clock.Timestamp) i64 {
    return @intCast(t0.durationTo(t1).raw.toNanoseconds());
}

fn buildStats(samples: []const i64, scratch: []i64) Stats {
    @memcpy(scratch[0..samples.len], samples);
    std.sort.pdq(i64, scratch[0..samples.len], {}, std.sort.asc(i64));
    const n = samples.len;
    const min_v = scratch[0];
    const max_v = scratch[n - 1];
    const p50_v = scratch[@min(n - 1, n / 2)];
    const p95_idx = @min(n - 1, @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(n)) * 0.95))) - 1);
    const p95_v = scratch[p95_idx];

    var sum: i128 = 0;
    for (samples) |s| sum += s;
    const mean_v = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));

    return .{
        .min_ms = nsToMs(min_v),
        .p50_ms = nsToMs(p50_v),
        .p95_ms = nsToMs(p95_v),
        .max_ms = nsToMs(max_v),
        .mean_ms = mean_v / 1_000_000.0,
    };
}

fn printStats(label: []const u8, cfg: BenchCfg, stats: Stats, units: usize) void {
    const denom = @as(f64, @floatFromInt(units));
    std.debug.print(
        "{s} (warmup={d}, timed={d})\n  ms: min={d:.2} p50={d:.2} p95={d:.2} mean={d:.2} max={d:.2}\n  us/op (mean): {d:.2}\n",
        .{ label, cfg.warmup, cfg.timed, stats.min_ms, stats.p50_ms, stats.p95_ms, stats.mean_ms, stats.max_ms, (stats.mean_ms * 1000.0) / denom },
    );
}

fn populateDataset(
    allocator: std.mem.Allocator,
    io: std.Io,
    kv: *KVStore,
    graph: *GraphEngine,
    data: DatasetCfg,
) !void {
    for (0..data.kv_count) |i| {
        const key = try std.fmt.allocPrint(allocator, "k:{d}", .{i});
        defer allocator.free(key);
        const val = try std.fmt.allocPrint(allocator, "value:{d}", .{i});
        defer allocator.free(val);
        try kv.set(key, val);
    }
    _ = io;

    for (0..data.node_count) |i| {
        const key = try std.fmt.allocPrint(allocator, "n:{d}", .{i});
        defer allocator.free(key);
        _ = try graph.addNode(key, "svc");
    }

    for (0..data.edge_count) |i| {
        const from = i % data.node_count;
        const to = (i + 1) % data.node_count;
        const from_key = try std.fmt.allocPrint(allocator, "n:{d}", .{from});
        defer allocator.free(from_key);
        const to_key = try std.fmt.allocPrint(allocator, "n:{d}", .{to});
        defer allocator.free(to_key);
        _ = try graph.addEdge(from_key, to_key, "calls", 1.0);
    }
}

fn benchSnapshotSave(io: std.Io, allocator: std.mem.Allocator, kv: *KVStore, graph: *GraphEngine, path: []const u8) !i64 {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    try snapshot.save(io, allocator, kv, graph, path);
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    return monotonicNs(t0, t1);
}

fn benchSnapshotLoad(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !i64 {
    var kv = KVStore.init(allocator, io);
    defer kv.deinit();
    var graph = GraphEngine.init(allocator);
    defer graph.deinit();
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    try snapshot.load(io, allocator, &kv, &graph, path);
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    return monotonicNs(t0, t1);
}

const ReplayCounter = struct {
    count: u64 = 0,
    pub fn execute(self: *ReplayCounter, _: []const []const u8, _: *std.Io.Writer) std.Io.Writer.Error!void {
        self.count += 1;
    }
};

fn benchAofAppend(io: std.Io, path: []const u8, keys: []const []const u8, vals: []const []const u8) !i64 {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var aof = try aof_mod.AOF.init(io, path, "/tmp/vex_dummy.zdb");
    defer aof.deinit();
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    for (keys, vals) |k, v| {
        const args = [_][]const u8{ "SET", k, v };
        aof.logCommand(&args);
    }
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    return monotonicNs(t0, t1);
}

fn benchAofReplay(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !i64 {
    var handler = ReplayCounter{};
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    _ = try aof_mod.replayFile(io, allocator, path, &handler);
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    return monotonicNs(t0, t1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cfg = BenchCfg{};
    const data = DatasetCfg{};

    var kv = KVStore.init(allocator, io);
    defer kv.deinit();
    var graph = GraphEngine.init(allocator);
    defer graph.deinit();

    std.debug.print("Preparing dataset: kv={d}, nodes={d}, edges={d}\n", .{ data.kv_count, data.node_count, data.edge_count });
    try populateDataset(allocator, io, &kv, &graph, data);

    const snapshot_path = "/tmp/vex_persistence_bench.zdb";
    const aof_path = "/tmp/vex_persistence_bench.aof";
    defer std.Io.Dir.cwd().deleteFile(io, snapshot_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, aof_path) catch {};

    const aof_keys = try allocator.alloc([]const u8, data.aof_ops);
    defer {
        for (aof_keys) |k| allocator.free(k);
        allocator.free(aof_keys);
    }
    const aof_vals = try allocator.alloc([]const u8, data.aof_ops);
    defer {
        for (aof_vals) |v| allocator.free(v);
        allocator.free(aof_vals);
    }
    for (0..data.aof_ops) |i| {
        aof_keys[i] = try std.fmt.allocPrint(allocator, "ak:{d}", .{i});
        aof_vals[i] = try std.fmt.allocPrint(allocator, "av:{d}", .{i});
    }

    const samples = try allocator.alloc(i64, cfg.timed);
    defer allocator.free(samples);
    const scratch = try allocator.alloc(i64, cfg.timed);
    defer allocator.free(scratch);

    std.debug.print("\n=== Persistence benchmark ===\n\n", .{});

    for (0..cfg.warmup) |_| _ = try benchSnapshotSave(io, allocator, &kv, &graph, snapshot_path);
    for (0..cfg.timed) |i| samples[i] = try benchSnapshotSave(io, allocator, &kv, &graph, snapshot_path);
    printStats("snapshot.save", cfg, buildStats(samples, scratch), data.kv_count + data.node_count + data.edge_count);

    for (0..cfg.warmup) |_| _ = try benchSnapshotLoad(io, allocator, snapshot_path);
    for (0..cfg.timed) |i| samples[i] = try benchSnapshotLoad(io, allocator, snapshot_path);
    printStats("snapshot.load", cfg, buildStats(samples, scratch), data.kv_count + data.node_count + data.edge_count);

    for (0..cfg.warmup) |_| _ = try benchAofAppend(io, aof_path, aof_keys, aof_vals);
    for (0..cfg.timed) |i| samples[i] = try benchAofAppend(io, aof_path, aof_keys, aof_vals);
    printStats("aof.append(SET)", cfg, buildStats(samples, scratch), data.aof_ops);

    for (0..cfg.warmup) |_| _ = try benchAofReplay(io, allocator, aof_path);
    for (0..cfg.timed) |i| samples[i] = try benchAofReplay(io, allocator, aof_path);
    printStats("aof.replay", cfg, buildStats(samples, scratch), data.aof_ops);

    std.debug.print("\nDone.\n", .{});
}
