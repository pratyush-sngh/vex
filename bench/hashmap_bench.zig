//! Micro-benchmarks: std.StringHashMap vs verztable.HashMap (string keys, []const u8 values).
//!
//! Each scenario: `warmup` full runs (not recorded), then `timed` runs with stats over total ns
//! and per-unit ns (min / median / mean / max).
//!
//! Tune `BenchCfg` in `main` (e.g. `.warmup = 0, .timed = 1`) for a quick smoke run.
//!
//! Run: zig build bench-hashmap -Doptimize=ReleaseFast

const std = @import("std");
const VerzMap = @import("verztable").HashMap;

const BenchCfg = struct {
    warmup: usize,
    timed: usize,
};

fn monotonicNs(t0: std.Io.Clock.Timestamp, t1: std.Io.Clock.Timestamp) i64 {
    return @intCast(t0.durationTo(t1).raw.toNanoseconds());
}

fn printTimingLine(
    comptime label: []const u8,
    scenario: []const u8,
    cfg: BenchCfg,
    samples: []const i64,
    scratch: []i64,
    denom: usize,
    unit: []const u8,
) void {
    std.debug.assert(samples.len == cfg.timed);
    std.debug.assert(scratch.len >= samples.len);

    @memcpy(scratch[0..samples.len], samples);
    std.sort.pdq(i64, scratch[0..samples.len], {}, std.sort.asc(i64));

    const n = samples.len;
    const min_ns = scratch[0];
    const max_ns = scratch[n - 1];
    const med_ns: i64 = if (n & 1 == 1)
        scratch[n / 2]
    else
        @divTrunc(scratch[n / 2 - 1] + scratch[n / 2], 2);

    var sum: i128 = 0;
    for (samples) |s| sum += s;
    const mean_ns = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));

    const df = @as(f64, @floatFromInt(denom));
    std.debug.print("{s}: {s} (warmup={d} timed={d})\n", .{ label, scenario, cfg.warmup, cfg.timed });
    std.debug.print("  total ns  min={d} med={d} mean={d:.0} max={d}\n", .{ min_ns, med_ns, mean_ns, max_ns });
    std.debug.print("  ns/{s} min={d:.1} med={d:.1} mean={d:.1} max={d:.1}\n", .{
        unit,
        @as(f64, @floatFromInt(min_ns)) / df,
        @as(f64, @floatFromInt(med_ns)) / df,
        mean_ns / df,
        @as(f64, @floatFromInt(max_ns)) / df,
    });
}

fn insertColdTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    use_verz: bool,
) !i64 {
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
    }
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    return monotonicNs(t0, t1);
}

fn insertReservedTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    use_verz: bool,
) !i64 {
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        try m.reserve(keys.len);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys) |k| try m.put(k, val);
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        try m.ensureTotalCapacity(@intCast(keys.len));
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys) |k| try m.put(k, val);
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    }
}

fn lookupSeqTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    use_verz: bool,
) !i64 {
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys) |k| _ = m.get(k).?;
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys) |k| _ = m.get(k).?;
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    }
}

fn lookupPermutedTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    perm: []const usize,
    use_verz: bool,
) !i64 {
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (perm) |pi| _ = m.get(keys[pi]).?;
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (perm) |pi| _ = m.get(keys[pi]).?;
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    }
}

fn hitMissTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    miss_keys: []const []const u8,
    val: []const u8,
    use_verz: bool,
) !i64 {
    std.debug.assert(keys.len == miss_keys.len);
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys, miss_keys) |k, mk| {
            _ = m.get(k).?;
            std.debug.assert(m.get(mk) == null);
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys, miss_keys) |k, mk| {
            _ = m.get(k).?;
            std.debug.assert(m.get(mk) == null);
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    }
}

fn getOrPutTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    perm: []const usize,
    rounds: usize,
    use_verz: bool,
) !i64 {
    if (use_verz) {
        var m = VerzMap([]const u8, u32).init(allocator);
        defer m.deinit();
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..rounds) |r| {
            const k = keys[perm[r % keys.len]];
            const g = try m.getOrPut(k);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap(u32).init(allocator);
        defer m.deinit();
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..rounds) |r| {
            const k = keys[perm[r % keys.len]];
            const g = try m.getOrPut(k);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    }
}

fn mixedGetPutTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    alt_val: []const u8,
    ops: usize,
    use_verz: bool,
) !i64 {
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..ops) |i| {
            const k = keys[(i *% 1103515245 +% 12345) % keys.len];
            if (i % 7 == 0) {
                try m.put(k, alt_val);
            } else {
                _ = m.get(k);
            }
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..ops) |i| {
            const k = keys[(i *% 1103515245 +% 12345) % keys.len];
            if (i % 7 == 0) {
                try m.put(k, alt_val);
            } else {
                _ = m.get(k);
            }
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    }
}

fn iterateTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    use_verz: bool,
) !i64 {
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        var sum: usize = 0;
        var it = m.iterator();
        while (it.next()) |b| sum +%= b.key.len;
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        std.debug.assert(sum > 0);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        var sum: usize = 0;
        var it = m.iterator();
        while (it.next()) |e| sum +%= e.key_ptr.len;
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        std.debug.assert(sum > 0);
        return monotonicNs(t0, t1);
    }
}

fn deleteHalfTimedNs(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    use_verz: bool,
) !i64 {
    if (use_verz) {
        var m = VerzMap([]const u8, []const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys, 0..) |k, i| {
            if (i & 1 == 0) _ = m.remove(k);
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    } else {
        var m = std.StringHashMap([]const u8).init(allocator);
        defer m.deinit();
        for (keys) |k| try m.put(k, val);
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        for (keys, 0..) |k, i| {
            if (i & 1 == 0) _ = m.remove(k);
        }
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        return monotonicNs(t0, t1);
    }
}

const Scenario = enum {
    insert_cold,
    insert_reserved,
    lookup_seq,
    lookup_permuted,
    hit_miss,
    get_or_put,
    mixed,
    iterate,
    delete_half,
};

const BenchState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    perm: []const usize,
    miss_keys: []const []const u8,
    alt_val: []const u8,
    get_or_put_rounds: usize,
    mixed_ops: usize,
    scenario: Scenario,
    use_verz: bool,
};

fn benchRunOnce(s: BenchState) !i64 {
    return switch (s.scenario) {
        .insert_cold => insertColdTimedNs(s.allocator, s.io, s.keys, s.val, s.use_verz),
        .insert_reserved => insertReservedTimedNs(s.allocator, s.io, s.keys, s.val, s.use_verz),
        .lookup_seq => lookupSeqTimedNs(s.allocator, s.io, s.keys, s.val, s.use_verz),
        .lookup_permuted => lookupPermutedTimedNs(s.allocator, s.io, s.keys, s.val, s.perm, s.use_verz),
        .hit_miss => hitMissTimedNs(s.allocator, s.io, s.keys, s.miss_keys, s.val, s.use_verz),
        .get_or_put => getOrPutTimedNs(s.allocator, s.io, s.keys, s.perm, s.get_or_put_rounds, s.use_verz),
        .mixed => mixedGetPutTimedNs(s.allocator, s.io, s.keys, s.val, s.alt_val, s.mixed_ops, s.use_verz),
        .iterate => iterateTimedNs(s.allocator, s.io, s.keys, s.val, s.use_verz),
        .delete_half => deleteHalfTimedNs(s.allocator, s.io, s.keys, s.val, s.use_verz),
    };
}

fn benchState(
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: []const []const u8,
    val: []const u8,
    perm: []const usize,
    miss_keys: []const []const u8,
    alt_val: []const u8,
    get_or_put_rounds: usize,
    mixed_ops: usize,
    scenario: Scenario,
    use_verz: bool,
) BenchState {
    return .{
        .allocator = allocator,
        .io = io,
        .keys = keys,
        .val = val,
        .perm = perm,
        .miss_keys = miss_keys,
        .alt_val = alt_val,
        .get_or_put_rounds = get_or_put_rounds,
        .mixed_ops = mixed_ops,
        .scenario = scenario,
        .use_verz = use_verz,
    };
}

fn sampleBench(cfg: BenchCfg, samples: []i64, state: BenchState) !void {
    var w: usize = 0;
    while (w < cfg.warmup) : (w += 1) {
        _ = try benchRunOnce(state);
    }
    var t: usize = 0;
    while (t < cfg.timed) : (t += 1) {
        samples[t] = try benchRunOnce(state);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Default: one warmup discard + seven timed samples (edit for faster local iteration).
    const cfg = BenchCfg{ .warmup = 1, .timed = 7 };

    const n: usize = 200_000;
    const val = "payload";

    var keys = try allocator.alloc([]const u8, n);
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }

    for (0..n) |i| {
        keys[i] = try std.fmt.allocPrint(allocator, "key:{d}", .{i});
    }

    var perm = try allocator.alloc(usize, n);
    defer allocator.free(perm);
    for (0..n) |i| perm[i] = i;
    var prng = std.Random.Xoshiro256.init(0xB3A9_D854_2E11_4D71);
    prng.random().shuffle(usize, perm);

    var miss_keys = try allocator.alloc([]const u8, n);
    defer {
        for (miss_keys) |mk| allocator.free(mk);
        allocator.free(miss_keys);
    }
    for (0..n) |i| {
        miss_keys[i] = try std.fmt.allocPrint(allocator, "miss:{d}", .{i});
    }

    const alt_val = "alt_payload";
    const get_or_put_rounds: usize = n * 2;
    const mixed_ops: usize = 1_000_000;
    const hit_miss_total = n * 2;
    const delete_n = n / 2;

    const samples = try allocator.alloc(i64, cfg.timed);
    defer allocator.free(samples);
    const scratch = try allocator.alloc(i64, cfg.timed);
    defer allocator.free(scratch);

    std.debug.print("\n=== Hash map micro-benchmark (n={d}, warmup={d}, timed={d}) ===\n\n", .{
        n, cfg.warmup, cfg.timed,
    });

    std.debug.print("--- insert (cold, no reserve) ---\n", .{});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .insert_cold, false));
    printTimingLine("std.StringHashMap", "insert cold", cfg, samples, scratch, n, "key");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .insert_cold, true));
    printTimingLine("verztable.HashMap", "insert cold", cfg, samples, scratch, n, "key");

    std.debug.print("\n--- insert after reserve (timed: puts only) ---\n", .{});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .insert_reserved, false));
    printTimingLine("std.StringHashMap", "insert after reserve", cfg, samples, scratch, n, "key");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .insert_reserved, true));
    printTimingLine("verztable.HashMap", "insert after reserve", cfg, samples, scratch, n, "key");

    std.debug.print("\n--- successful get (sequential order) ---\n", .{});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .lookup_seq, false));
    printTimingLine("std.StringHashMap", "lookup sequential", cfg, samples, scratch, n, "key");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .lookup_seq, true));
    printTimingLine("verztable.HashMap", "lookup sequential", cfg, samples, scratch, n, "key");

    std.debug.print("\n--- successful get (permuted order) ---\n", .{});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .lookup_permuted, false));
    printTimingLine("std.StringHashMap", "lookup permuted", cfg, samples, scratch, n, "key");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .lookup_permuted, true));
    printTimingLine("verztable.HashMap", "lookup permuted", cfg, samples, scratch, n, "key");

    std.debug.print("\n--- hit + miss interleaved ---\n", .{});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .hit_miss, false));
    printTimingLine("std.StringHashMap", "hit+miss interleaved", cfg, samples, scratch, hit_miss_total, "lookup");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .hit_miss, true));
    printTimingLine("verztable.HashMap", "hit+miss interleaved", cfg, samples, scratch, hit_miss_total, "lookup");

    std.debug.print("\n--- getOrPut accumulate u32 ({d} ops) ---\n", .{get_or_put_rounds});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .get_or_put, false));
    printTimingLine("std.StringHashMap", "getOrPut(u32)", cfg, samples, scratch, get_or_put_rounds, "op");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .get_or_put, true));
    printTimingLine("verztable.HashMap", "getOrPut(u32)", cfg, samples, scratch, get_or_put_rounds, "op");

    std.debug.print("\n--- mixed get / put ({d} ops, ~14% puts) ---\n", .{mixed_ops});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .mixed, false));
    printTimingLine("std.StringHashMap", "mixed get/put", cfg, samples, scratch, mixed_ops, "op");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .mixed, true));
    printTimingLine("verztable.HashMap", "mixed get/put", cfg, samples, scratch, mixed_ops, "op");

    std.debug.print("\n--- full iteration (sum key lengths) ---\n", .{});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .iterate, false));
    printTimingLine("std.StringHashMap", "iterate all", cfg, samples, scratch, n, "entry");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .iterate, true));
    printTimingLine("verztable.HashMap", "iterate all", cfg, samples, scratch, n, "entry");

    std.debug.print("\n--- delete every other key (churn) ---\n", .{});
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .delete_half, false));
    printTimingLine("std.StringHashMap", "delete half", cfg, samples, scratch, delete_n, "delete");
    try sampleBench(cfg, samples, benchState(allocator, io, keys, val, perm, miss_keys, alt_val, get_or_put_rounds, mixed_ops, .delete_half, true));
    printTimingLine("verztable.HashMap", "delete half", cfg, samples, scratch, delete_n, "delete");

    std.debug.print("\nDone.\n", .{});
}
