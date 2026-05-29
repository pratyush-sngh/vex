const std = @import("std");
const c = std.c;
const app = @import("app");
const GraphEngine = app.graph.GraphEngine;
const query = app.query;

const NODES = 50_000;
const EDGES_PER_NODE = 10;
const PROPS_PER_NODE = 5;

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

    // ─── 50K Graph Benchmark (scoped — freed before CH test) ─────
    {
        std.debug.print("\n=== Vex Graph Benchmark ({d} nodes, {d} edges/node, {d} props/node) ===\n", .{ NODES, EDGES_PER_NODE, PROPS_PER_NODE });

        var g = GraphEngine.init(allocator);
        defer g.deinit();

        const keys = try allocator.alloc([]const u8, NODES);
        defer {
            for (keys) |k| allocator.free(k);
            allocator.free(keys);
        }
        for (0..NODES) |i| {
            keys[i] = try std.fmt.allocPrint(allocator, "node:{d:0>6}", .{i});
        }

        const prop_keys = [_][]const u8{ "name", "kind", "language", "path", "service" };
        const prop_vals = [_][]const u8{ "test-node", "method", "java", "/src/main", "core-api" };

        std.debug.print("\n--- Node Operations ---\n", .{});
        {
            const t0 = nowNs();
            for (keys) |key| {
                _ = g.addNode(key, "service") catch continue;
            }
            const ns = nowNs() - t0;
            std.debug.print("  ADDNODE:      {d:.1} ns/op  ({d} nodes)\n", .{ nsPerOp(ns, NODES), NODES });
        }
        {
            const ops = NODES * PROPS_PER_NODE;
            const t0 = nowNs();
            for (keys) |key| {
                for (0..PROPS_PER_NODE) |pi| {
                    g.setNodeProperty(key, prop_keys[pi], prop_vals[pi]) catch continue;
                }
            }
            const ns = nowNs() - t0;
            std.debug.print("  SETPROP:      {d:.1} ns/op  ({d} ops = {d} nodes x {d} props)\n", .{ nsPerOp(ns, ops), ops, NODES, PROPS_PER_NODE });
        }
        {
            const OPS = 10_000;
            const t0 = nowNs();
            var checksum: usize = 0;
            for (0..OPS) |i| {
                const node = g.getNode(keys[i]) orelse continue;
                _ = node;
                const count = g.node_props.countProps(@intCast(i));
                checksum += count;
                const pairs = g.node_props.collectAll(@intCast(i), allocator) catch continue;
                checksum += pairs.len;
                allocator.free(pairs);
            }
            const ns = nowNs() - t0;
            std.debug.print("  GETNODE:      {d:.1} ns/op  ({d} ops, checksum={d})\n", .{ nsPerOp(ns, OPS), OPS, checksum });
        }
        {
            const total_edges = NODES * EDGES_PER_NODE;
            const t0 = nowNs();
            var added: usize = 0;
            for (0..NODES) |i| {
                for (0..EDGES_PER_NODE) |j| {
                    const target = (i + j * 7 + 1) % NODES;
                    _ = g.addEdge(keys[i], keys[target], "calls", 1.0) catch continue;
                    added += 1;
                }
            }
            const ns = nowNs() - t0;
            std.debug.print("  ADDEDGE:      {d:.1} ns/op  ({d} edges)\n", .{ nsPerOp(ns, total_edges), added });
        }
        {
            const t0 = nowNs();
            g.compact() catch {};
            const ns = nowNs() - t0;
            std.debug.print("  COMPACT:      {d:.2} ms\n", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
        }

        std.debug.print("\n--- Query Operations (post-compact) ---\n", .{});
        {
            const OPS = 10_000;
            const t0 = nowNs();
            var total_neighbors: usize = 0;
            for (0..OPS) |i| {
                const ids = query.neighbors(&g, allocator, keys[i], .outgoing) catch continue;
                total_neighbors += ids.len;
                allocator.free(ids);
            }
            const ns = nowNs() - t0;
            std.debug.print("  NEIGHBORS:    {d:.1} ns/op  ({d} ops, avg_degree={d:.1})\n", .{ nsPerOp(ns, OPS), OPS, @as(f64, @floatFromInt(total_neighbors)) / @as(f64, OPS) });
        }
        {
            const OPS = 200;
            const t0 = nowNs();
            var total_visited: usize = 0;
            for (0..OPS) |i| {
                const ids = query.traverse(&g, allocator, keys[i * 50], .{ .max_depth = 4 }) catch continue;
                total_visited += ids.len;
                allocator.free(ids);
            }
            const ns = nowNs() - t0;
            std.debug.print("  TRAVERSE(d4): {d:.1} us/op  ({d} ops, avg_visited={d:.0})\n", .{ usPerOp(ns, OPS), OPS, @as(f64, @floatFromInt(total_visited)) / @as(f64, OPS) });
        }
        {
            const OPS = 200;
            const t0 = nowNs();
            var found: usize = 0;
            for (0..OPS) |i| {
                const from = keys[i * 100];
                const to = keys[(i * 100 + 1000) % NODES];
                var result = query.shortestPath(&g, allocator, from, to, 20) catch continue;
                if (result.nodes.len > 0) found += 1;
                result.deinit(allocator);
            }
            const ns = nowNs() - t0;
            std.debug.print("  PATH:         {d:.1} us/op  ({d} ops, found={d})\n", .{ usPerOp(ns, OPS), OPS, found });
        }
        {
            const OPS = 200;
            const t0 = nowNs();
            var found: usize = 0;
            for (0..OPS) |i| {
                const from = keys[i * 100];
                const to = keys[(i * 100 + 1000) % NODES];
                var result = query.weightedShortestPath(&g, allocator, from, to) catch continue;
                if (result.nodes.len > 0) found += 1;
                result.deinit(allocator);
            }
            const ns = nowNs() - t0;
            std.debug.print("  WPATH:        {d:.1} us/op  ({d} ops, found={d})\n", .{ usPerOp(ns, OPS), OPS, found });
        }
    } // 50K graph freed here

    // ─── CH Test: 1000 nodes, random sparse graph ────────────────
    std.debug.print("\n--- CH Test (100 nodes, 3 edges/node, random) ---\n", .{});
    {
        const ch_mod = app.ch;
        const CH_N = 100;
        var g2 = GraphEngine.init(allocator);
        defer g2.deinit();
        const ch_keys = try allocator.alloc([]const u8, CH_N);
        defer {
            for (ch_keys) |k| allocator.free(k);
            allocator.free(ch_keys);
        }
        for (0..CH_N) |i| {
            ch_keys[i] = std.fmt.allocPrint(allocator, "ch:{d:0>5}", .{i}) catch continue;
            _ = g2.addNode(ch_keys[i], "t") catch continue;
        }
        for (0..CH_N) |i| {
            for (0..3) |j| {
                const target = (i + j * 31 + 1) % CH_N;
                const w: f64 = @as(f64, @floatFromInt((i * 3 + j * 5) % 10 + 1));
                _ = g2.addEdge(ch_keys[i], ch_keys[target], "e", w) catch continue;
            }
        }
        try g2.compact();

        const t_build = nowNs();
        var ch = ch_mod.build(&g2, allocator) catch {
            std.debug.print("  CH build failed\n", .{});
            std.debug.print("\n=== Done ===\n\n", .{});
            return;
        };
        defer ch.deinit();
        const build_ms = @as(f64, @floatFromInt(nowNs() - t_build)) / 1_000_000.0;
        std.debug.print("  CH build:     {d:.1} ms\n", .{build_ms});

        const Q = 200;
        {
            const t0 = nowNs();
            var found: usize = 0;
            for (0..Q) |i| {
                const s = ch_keys[(i * 7) % CH_N];
                const t = ch_keys[(i * 13 + 500) % CH_N];
                var r = query.weightedShortestPath(&g2, allocator, s, t) catch continue;
                found += 1;
                r.deinit(allocator);
            }
            const ns = nowNs() - t0;
            std.debug.print("  Dijkstra:     {d:.1} us/op  ({d} queries, found={d})\n", .{ usPerOp(ns, Q), Q, found });
        }
        {
            var qe = ch_mod.CHQueryEngine.init(allocator, &ch) catch {
                std.debug.print("  CH query engine init failed\n", .{});
                std.debug.print("\n=== Done ===\n\n", .{});
                return;
            };
            defer qe.deinit();

            const t0 = nowNs();
            var found: usize = 0;
            for (0..Q) |i| {
                const s: u32 = @intCast((i * 7) % CH_N);
                const t: u32 = @intCast((i * 13 + 500) % CH_N);
                const r = qe.query(&ch, s, t) catch continue;
                found += 1;
                allocator.free(r.nodes);
            }
            const ns = nowNs() - t0;
            std.debug.print("  CH query:     {d:.1} us/op  ({d} queries, found={d})\n", .{ usPerOp(ns, Q), Q, found });
        }
    }

    std.debug.print("\n=== Done ===\n\n", .{});
}
