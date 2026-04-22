const std = @import("std");
const Allocator = std.mem.Allocator;
const KVStore = @import("kv.zig").KVStore;
const c = std.c;

const WARMUP = 1000;
const OPS = 100_000;

fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn nsPerOp(total_ns: u64, ops: u64) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(ops));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var kv = KVStore.init(allocator, io);
    defer kv.deinit();

    std.debug.print("\n=== Vex KV Benchmark ({d} ops) ===\n\n", .{OPS});

    // Pre-generate keys and values
    const keys = try allocator.alloc([]const u8, OPS);
    defer allocator.free(keys);
    const values = try allocator.alloc([]const u8, OPS);
    defer allocator.free(values);

    for (0..OPS) |i| {
        keys[i] = try std.fmt.allocPrint(allocator, "key:{d:0>8}", .{i});
        values[i] = try std.fmt.allocPrint(allocator, "value-{d:0>16}", .{i});
    }
    defer {
        for (0..OPS) |i| {
            allocator.free(keys[i]);
            allocator.free(values[i]);
        }
    }

    // ─── SET benchmark (insert) ───
    {
        kv.updateClock();
        // Warmup
        for (0..WARMUP) |i| {
            try kv.set(keys[i], values[i]);
        }
        // Clear for real run
        kv.flushdb();

        kv.updateClock();
        const t0 = nowNs();
        for (0..OPS) |i| {
            try kv.set(keys[i], values[i]);
        }
        const set_insert_ns = nowNs() - t0;
        std.debug.print("  SET (insert):     {d:.1} ns/op\n", .{nsPerOp(set_insert_ns, OPS)});
    }

    // ─── SET benchmark (update) ───
    {
        kv.updateClock();
        const t0 = nowNs();
        for (0..OPS) |i| {
            try kv.set(keys[i], values[OPS - 1 - i]); // overwrite with different values
        }
        const set_update_ns = nowNs() - t0;
        std.debug.print("  SET (update):     {d:.1} ns/op\n", .{nsPerOp(set_update_ns, OPS)});
    }

    // ─── GET benchmark (hit) ───
    {
        kv.updateClock();
        var sum: usize = 0;
        const t0 = nowNs();
        for (0..OPS) |i| {
            if (kv.get(keys[i])) |v| sum += v.len;
        }
        const get_hit_ns = nowNs() - t0;
        std.debug.print("  GET (hit):        {d:.1} ns/op  (checksum={d})\n", .{ nsPerOp(get_hit_ns, OPS), sum });
    }

    // ─── GET benchmark (miss) ───
    {
        kv.updateClock();
        var miss_count: usize = 0;
        const t0 = nowNs();
        for (0..OPS) |i| {
            _ = i;
            if (kv.get("nonexistent:key:that:does:not:exist") == null) miss_count += 1;
        }
        const get_miss_ns = nowNs() - t0;
        std.debug.print("  GET (miss):       {d:.1} ns/op  (misses={d})\n", .{ nsPerOp(get_miss_ns, OPS), miss_count });
    }

    // ─── EXISTS benchmark ───
    {
        kv.updateClock();
        var exist_count: usize = 0;
        const t0 = nowNs();
        for (0..OPS) |i| {
            if (kv.exists(keys[i])) exist_count += 1;
        }
        const exists_ns = nowNs() - t0;
        std.debug.print("  EXISTS:           {d:.1} ns/op  (found={d})\n", .{ nsPerOp(exists_ns, OPS), exist_count });
    }

    // ─── DEL benchmark (tombstone) ───
    {
        kv.updateClock();
        const t0 = nowNs();
        for (0..OPS) |i| {
            _ = kv.delete(keys[i]);
        }
        const del_ns = nowNs() - t0;
        std.debug.print("  DEL (tombstone):  {d:.1} ns/op  (tombstones={d})\n", .{ nsPerOp(del_ns, OPS), kv.tombstone_count });
    }

    // ─── SET after DEL (tombstone reuse) ───
    {
        kv.updateClock();
        const t0 = nowNs();
        for (0..OPS) |i| {
            try kv.set(keys[i], values[i]);
        }
        const set_reuse_ns = nowNs() - t0;
        std.debug.print("  SET (reuse tomb): {d:.1} ns/op  (tombstones={d})\n", .{ nsPerOp(set_reuse_ns, OPS), kv.tombstone_count });
    }

    // ─── Compact tombstones benchmark ───
    {
        // Delete half the keys to create tombstones
        for (0..OPS / 2) |i| {
            _ = kv.delete(keys[i]);
        }
        std.debug.print("  Tombstones before compact: {d}\n", .{kv.tombstone_count});

        kv.updateClock();
        const t0 = nowNs();
        kv.compactTombstones();
        const compact_ns = nowNs() - t0;
        std.debug.print("  Compact:          {d:.2} ms ({d} entries removed)\n", .{
            @as(f64, @floatFromInt(compact_ns)) / 1_000_000.0,
            OPS / 2,
        });
    }

    std.debug.print("\n  Live keys: {d}, Tombstones: {d}, TTL keys: {d}\n", .{
        kv.live_count, kv.tombstone_count, kv.ttl_count,
    });
    std.debug.print("\n=== Done ===\n", .{});
}
