const std = @import("std");
const c = std.c;
const GraphEngine = @import("graph.zig").GraphEngine;
const query = @import("query.zig");

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

    std.debug.print("\n=== Vex Graph Benchmark ({d} nodes, {d} edges/node, {d} props/node) ===\n", .{ NODES, EDGES_PER_NODE, PROPS_PER_NODE });

    var g = GraphEngine.init(allocator);
    defer g.deinit();

    // Pre-generate keys
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

    // ─── ADDNODE ────────────────────────────────────────────────
    std.debug.print("\n--- Node Operations ---\n", .{});
    {
        const t0 = nowNs();
        for (keys) |key| {
            _ = g.addNode(key, "service") catch continue;
        }
        const ns = nowNs() - t0;
        std.debug.print("  ADDNODE:      {d:.1} ns/op  ({d} nodes)\n", .{ nsPerOp(ns, NODES), NODES });
    }

    // ─── SETPROP (5 props per node) ────────────────────────────
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

    // ─── GETNODE (includes countProps + collectAll) ─────────────
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

    // ─── ADDEDGE ───────────────────────────────────────────────
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

    // ─── COMPACT ───────────────────────────────────────────────
    {
        const t0 = nowNs();
        g.compact() catch {};
        const ns = nowNs() - t0;
        std.debug.print("  COMPACT:      {d:.2} ms\n", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    }

    // ─── NEIGHBORS ─────────────────────────────────────────────
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

    // ─── TRAVERSE depth=4 ──────────────────────────────────────
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

    // ─── SHORTEST PATH ────────────────────────────────────────
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

    // ─── WEIGHTED PATH ─────────────────────────────────────────
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

    // ─── CH Test: 50x50 grid graph (road-network-like structure) ───
    std.debug.print("\n--- CH Test (2500 nodes, 50x50 grid, 4 edges/node) ---\n", .{});
    {
        const ch_mod = @import("ch.zig");
        const GRID = 50; // 50x50 = 2500 nodes
        const CH_N = GRID * GRID;
        var g2 = GraphEngine.init(allocator);
        defer g2.deinit();
        const ch_keys = try allocator.alloc([]const u8, CH_N);
        defer {
            for (ch_keys) |k| allocator.free(k);
            allocator.free(ch_keys);
        }
        for (0..CH_N) |i| {
            ch_keys[i] = std.fmt.allocPrint(allocator, "g:{d:0>5}", .{i}) catch continue;
            _ = g2.addNode(ch_keys[i], "t") catch continue;
        }
        // Grid edges: connect (r,c) to (r+1,c) and (r,c+1) with varied weights
        for (0..GRID) |r| {
            for (0..GRID) |c_idx| {
                const id = r * GRID + c_idx;
                if (r + 1 < GRID) {
                    const down = (r + 1) * GRID + c_idx;
                    const w: f64 = @as(f64, @floatFromInt((id * 3 + 1) % 5 + 1));
                    _ = g2.addEdge(ch_keys[id], ch_keys[down], "e", w) catch continue;
                    _ = g2.addEdge(ch_keys[down], ch_keys[id], "e", w) catch continue;
                }
                if (c_idx + 1 < GRID) {
                    const right = r * GRID + c_idx + 1;
                    const w: f64 = @as(f64, @floatFromInt((id * 7 + 3) % 5 + 1));
                    _ = g2.addEdge(ch_keys[id], ch_keys[right], "e", w) catch continue;
                    _ = g2.addEdge(ch_keys[right], ch_keys[id], "e", w) catch continue;
                }
            }
        }
        try g2.compact();

        // Build CH
        const t_build = nowNs();
        var ch = ch_mod.build(&g2, allocator) catch {
            std.debug.print("  CH build failed\n", .{});
            std.debug.print("\n=== Done ===\n\n", .{});
            return;
        };
        defer ch.deinit();
        const build_ms = @as(f64, @floatFromInt(nowNs() - t_build)) / 1_000_000.0;
        std.debug.print("  CH build:     {d:.1} ms\n", .{build_ms});

        // Dijkstra baseline — query distant node pairs (corners, etc.)
        const Q = 200;
        {
            const t0 = nowNs();
            var found: usize = 0;
            for (0..Q) |i| {
                // Pick pairs that are far apart on the grid
                const sr: usize = (i * 3) % GRID;
                const sc: usize = (i * 7) % GRID;
                const tr: usize = (GRID - 1) - (i * 5) % GRID;
                const tc: usize = (GRID - 1) - (i * 11) % GRID;
                const s = ch_keys[sr * GRID + sc];
                const t = ch_keys[tr * GRID + tc];
                var r = query.weightedShortestPath(&g2, allocator, s, t) catch continue;
                found += 1;
                r.deinit(allocator);
            }
            const ns = nowNs() - t0;
            std.debug.print("  Dijkstra:     {d:.1} us/op  ({d} queries, found={d})\n", .{ usPerOp(ns, Q), Q, found });
        }

        // CH queries (reusable engine — amortized alloc, touched-list reset)
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
                const sr: usize = (i * 3) % GRID;
                const sc: usize = (i * 7) % GRID;
                const tr: usize = (GRID - 1) - (i * 5) % GRID;
                const tc: usize = (GRID - 1) - (i * 11) % GRID;
                const s: u32 = @intCast(sr * GRID + sc);
                const t: u32 = @intCast(tr * GRID + tc);
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
