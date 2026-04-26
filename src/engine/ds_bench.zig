const std = @import("std");
const c = std.c;
const ListStore = @import("list.zig").ListStore;
const HashStore = @import("hash.zig").HashStore;
const SetStore = @import("set.zig").SetStore;
const SortedSetStore = @import("sorted_set.zig").SortedSetStore;

const OPS = 100_000;
const WARMUP = 1000;

fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn nsPerOp(total_ns: u64, ops: u64) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(ops));
}

fn usPerOp(total_ns: u64, ops: u64) f64 {
    return nsPerOp(total_ns, ops) / 1000.0;
}

pub fn main(_: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Pre-generate keys and values
    const members = try allocator.alloc([]const u8, OPS);
    defer allocator.free(members);
    const values = try allocator.alloc([]const u8, OPS);
    defer allocator.free(values);
    const scores = try allocator.alloc([]const u8, OPS);
    defer allocator.free(scores);

    for (0..OPS) |i| {
        members[i] = try std.fmt.allocPrint(allocator, "member:{d:0>8}", .{i});
        values[i] = try std.fmt.allocPrint(allocator, "value-{d:0>16}", .{i});
        scores[i] = try std.fmt.allocPrint(allocator, "{d}", .{i});
    }
    defer {
        for (0..OPS) |i| {
            allocator.free(members[i]);
            allocator.free(values[i]);
            allocator.free(scores[i]);
        }
    }

    std.debug.print("\n=== Vex Data Structure Benchmark ({d} ops, no network) ===\n", .{OPS});

    // ─── List benchmarks ────────────────────────────────────────────
    std.debug.print("\n--- Lists ---\n", .{});
    {
        var ls = ListStore.init(allocator);
        defer ls.deinit();

        // RPUSH: append N items to one list
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                _ = ls.rpush("bench:list", members[i .. i + 1]) catch continue;
            }
            const ns = nowNs() - t0;
            std.debug.print("  RPUSH:      {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }

        // LLEN
        {
            const t0 = nowNs();
            for (0..OPS) |_| {
                _ = ls.llen("bench:list");
            }
            const ns = nowNs() - t0;
            std.debug.print("  LLEN:       {d:.1} ns/op  (len={d})\n", .{ nsPerOp(ns, OPS), ls.llen("bench:list") });
        }

        // LINDEX (random access)
        {
            const t0 = nowNs();
            var checksum: usize = 0;
            for (0..OPS) |i| {
                if (ls.lindex("bench:list", @intCast(i))) |v| checksum += v.len;
            }
            const ns = nowNs() - t0;
            std.debug.print("  LINDEX:     {d:.1} ns/op  (checksum={d})\n", .{ nsPerOp(ns, OPS), checksum });
        }

        // LPOP: pop all from front (tests deque rebalance)
        {
            const t0 = nowNs();
            var popped: usize = 0;
            while (ls.lpop("bench:list")) |v| {
                allocator.free(v);
                popped += 1;
            }
            const ns = nowNs() - t0;
            std.debug.print("  LPOP:       {d:.1} ns/op  (popped={d})\n", .{ nsPerOp(ns, popped), popped });
        }

        // LPUSH: prepend N items
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                _ = ls.lpush("bench:list2", members[i .. i + 1]) catch continue;
            }
            const ns = nowNs() - t0;
            std.debug.print("  LPUSH:      {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }

        // RPOP: pop all from tail
        {
            const t0 = nowNs();
            var popped: usize = 0;
            while (ls.rpop("bench:list2")) |v| {
                allocator.free(v);
                popped += 1;
            }
            const ns = nowNs() - t0;
            std.debug.print("  RPOP:       {d:.1} ns/op  (popped={d})\n", .{ nsPerOp(ns, popped), popped });
        }
    }

    // ─── Hash benchmarks ────────────────────────────────────────────
    std.debug.print("\n--- Hashes ---\n", .{});
    {
        var hs = HashStore.init(allocator);
        defer hs.deinit();

        // HSET: add N fields to one hash
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                const fv = [2][]const u8{ members[i], values[i] };
                _ = hs.hset("bench:hash", &fv) catch continue;
            }
            const ns = nowNs() - t0;
            std.debug.print("  HSET:       {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }

        // HGET
        {
            var checksum: usize = 0;
            const t0 = nowNs();
            for (0..OPS) |i| {
                if (hs.hget("bench:hash", members[i])) |v| checksum += v.len;
            }
            const ns = nowNs() - t0;
            std.debug.print("  HGET:       {d:.1} ns/op  (checksum={d})\n", .{ nsPerOp(ns, OPS), checksum });
        }

        // HLEN
        {
            const t0 = nowNs();
            for (0..OPS) |_| {
                _ = hs.hlen("bench:hash");
            }
            const ns = nowNs() - t0;
            std.debug.print("  HLEN:       {d:.1} ns/op  (fields={d})\n", .{ nsPerOp(ns, OPS), hs.hlen("bench:hash") });
        }

        // HDEL
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                _ = hs.hdel("bench:hash", members[i .. i + 1]);
            }
            const ns = nowNs() - t0;
            std.debug.print("  HDEL:       {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }
    }

    // ─── Set benchmarks ─────────────────────────────────────────────
    std.debug.print("\n--- Sets ---\n", .{});
    {
        var ss = SetStore.init(allocator);
        defer ss.deinit();

        // SADD
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                _ = ss.sadd("bench:set", members[i .. i + 1]) catch continue;
            }
            const ns = nowNs() - t0;
            std.debug.print("  SADD:       {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }

        // SISMEMBER
        {
            var found: usize = 0;
            const t0 = nowNs();
            for (0..OPS) |i| {
                if (ss.sismember("bench:set", members[i])) found += 1;
            }
            const ns = nowNs() - t0;
            std.debug.print("  SISMEMBER:  {d:.1} ns/op  (found={d})\n", .{ nsPerOp(ns, OPS), found });
        }

        // SCARD
        {
            const t0 = nowNs();
            for (0..OPS) |_| {
                _ = ss.scard("bench:set");
            }
            const ns = nowNs() - t0;
            std.debug.print("  SCARD:      {d:.1} ns/op  (size={d})\n", .{ nsPerOp(ns, OPS), ss.scard("bench:set") });
        }

        // SREM
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                _ = ss.srem("bench:set", members[i .. i + 1]);
            }
            const ns = nowNs() - t0;
            std.debug.print("  SREM:       {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }
    }

    // ─── Sorted Set benchmarks ──────────────────────────────────────
    std.debug.print("\n--- Sorted Sets ---\n", .{});
    {
        var zs = SortedSetStore.init(allocator);
        defer zs.deinit();

        // ZADD
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                const sm = [2][]const u8{ scores[i], members[i] };
                _ = zs.zadd("bench:zset", &sm) catch continue;
            }
            const ns = nowNs() - t0;
            std.debug.print("  ZADD:       {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }

        // ZSCORE
        {
            var checksum: f64 = 0;
            const t0 = nowNs();
            for (0..OPS) |i| {
                if (zs.zscore("bench:zset", members[i])) |s| checksum += s;
            }
            const ns = nowNs() - t0;
            std.debug.print("  ZSCORE:     {d:.1} ns/op  (checksum={d:.0})\n", .{ nsPerOp(ns, OPS), checksum });
        }

        // ZCARD
        {
            const t0 = nowNs();
            for (0..OPS) |_| {
                _ = zs.zcard("bench:zset");
            }
            const ns = nowNs() - t0;
            std.debug.print("  ZCARD:      {d:.1} ns/op  (size={d})\n", .{ nsPerOp(ns, OPS), zs.zcard("bench:zset") });
        }

        // ZRANGE (top 10) — this is the expensive one (sorts all entries)
        {
            const RANGE_OPS = 1000; // fewer ops since ZRANGE is O(n log n)
            const t0 = nowNs();
            for (0..RANGE_OPS) |_| {
                const entries = zs.zrange("bench:zset", 0, 9, allocator) catch continue;
                if (entries.len > 0) allocator.free(entries);
            }
            const ns = nowNs() - t0;
            std.debug.print("  ZRANGE(10): {d:.1} us/op  ({d} ops, {d} members in set)\n", .{ usPerOp(ns, RANGE_OPS), RANGE_OPS, zs.zcard("bench:zset") });
        }

        // ZRANK
        {
            const RANK_OPS = 1000;
            const t0 = nowNs();
            for (0..RANK_OPS) |i| {
                _ = zs.zrank("bench:zset", members[i], allocator) catch continue;
            }
            const ns = nowNs() - t0;
            std.debug.print("  ZRANK:      {d:.1} us/op  ({d} ops)\n", .{ usPerOp(ns, RANK_OPS), RANK_OPS });
        }

        // ZREM
        {
            const t0 = nowNs();
            for (0..OPS) |i| {
                _ = zs.zrem("bench:zset", members[i .. i + 1]);
            }
            const ns = nowNs() - t0;
            std.debug.print("  ZREM:       {d:.1} ns/op\n", .{nsPerOp(ns, OPS)});
        }
    }

    std.debug.print("\n=== Done ===\n\n", .{});
}
