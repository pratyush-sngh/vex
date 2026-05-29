const std = @import("std");

// Canonical version: build.zig.zon's `.version` field. The build option
// below propagates it to every Zig target that needs to report it
// (vex binary, persistence_bench, etc.), so a release bump touches a
// single line.
const vex_version: []const u8 = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sanitizer / safety profiles. The defaults match the prior build
    // behavior; the chaos suite (tests/chaos/) exercises them via
    // dedicated Makefile targets (test-tsan, test-release-safe).
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer (-fsanitize-thread)") orelse false;
    const sanitize_c = b.option(bool, "sanitize-c", "Enable UBSan / -fsanitize-c=full") orelse false;

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", vex_version);
    const build_opts_mod = build_opts.createModule();

    // Vendored from https://github.com/ThobiasKnudsen/verztable v0.1.0 (Zig module only; upstream build pulls C++ benches).
    const verztable_mod = b.createModule(.{
        .root_source_file = b.path("vendor/verztable/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "vex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = if (sanitize_thread) true else null,
            .sanitize_c = if (sanitize_c) .full else null,
            .imports = &.{
                .{ .name = "build_options", .module = build_opts_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run vex server");
    run_step.dependOn(&run_cmd.step);

    // vex-sentinel: failover orchestrator. Lives in sentinel/ and reuses a
    // handful of vex modules via build.zig module imports — no premature
    // common/ extraction.
    const vex_log_mod = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const vex_atomic_io_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/atomic_io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // vex_resp: not consumed by sentinel today. Kept wired so the upcoming
    // health.tickOnce() PR — which parses RESP replies from PING and
    // VEX.STATUS — can import it without touching build.zig again. Drop if
    // that PR slips past one release cycle.
    const vex_resp_mod = b.createModule(.{
        .root_source_file = b.path("src/server/resp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const vex_cluster_config_mod = b.createModule(.{
        .root_source_file = b.path("src/cluster/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const sentinel_imports = [_]std.Build.Module.Import{
        .{ .name = "vex_log", .module = vex_log_mod },
        .{ .name = "vex_atomic_io", .module = vex_atomic_io_mod },
        .{ .name = "vex_resp", .module = vex_resp_mod },
        .{ .name = "vex_cluster_config", .module = vex_cluster_config_mod },
    };

    const sentinel_exe = b.addExecutable(.{
        .name = "sentinel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sentinel/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &sentinel_imports,
        }),
    });
    b.installArtifact(sentinel_exe);

    const run_sentinel_cmd = b.addRunArtifact(sentinel_exe);
    run_sentinel_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_sentinel_cmd.addArgs(args);
    const run_sentinel_step = b.step("run-sentinel", "Run vex-sentinel");
    run_sentinel_step.dependOn(&run_sentinel_cmd.step);

    const sentinel_test_step = b.step("test-sentinel", "Run vex-sentinel unit tests");
    const sentinel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("sentinel/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &sentinel_imports,
        }),
    });
    sentinel_test_step.dependOn(&b.addRunArtifact(sentinel_tests).step);

    // Single test root: main.zig's test block imports all modules (Zig 0.16 module paths).
    const test_step = b.step("test", "Run all unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = if (sanitize_thread) true else null,
            .sanitize_c = if (sanitize_c) .full else null,
            .imports = &.{
                .{ .name = "build_options", .module = build_opts_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const hashmap_bench = b.addExecutable(.{
        .name = "hashmap_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/hashmap_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verztable", .module = verztable_mod },
            },
        }),
    });
    const run_hashmap_bench = b.addRunArtifact(hashmap_bench);
    if (b.args) |args| run_hashmap_bench.addArgs(args);
    const bench_hashmap_step = b.step("bench-hashmap", "Benchmark std vs verztable string maps");
    bench_hashmap_step.dependOn(&run_hashmap_bench.step);

    // KV engine benchmark. Routes through the `app` module (rooted at
    // src/root.zig) so the bench can reach engine code whose internal
    // imports cross src/engine/ -> src/observability/, etc. Without
    // this indirection, modules rooted at src/engine/* can't escape
    // the engine/ subtree and the build fails with "import of file
    // outside module path".
    const kv_bench = b.addExecutable(.{
        .name = "kv_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/kv_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "app", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "build_options", .module = build_opts_mod },
                    },
                }) },
            },
        }),
    });
    const run_kv_bench = b.addRunArtifact(kv_bench);
    if (b.args) |args| run_kv_bench.addArgs(args);
    const bench_kv_step = b.step("bench-kv", "Benchmark KV engine (SET/GET/DEL)");
    bench_kv_step.dependOn(&run_kv_bench.step);

    // Data structure benchmark (lists, hashes, sets, sorted sets)
    const ds_bench = b.addExecutable(.{
        .name = "ds_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/ds_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_ds_bench = b.addRunArtifact(ds_bench);
    if (b.args) |args| run_ds_bench.addArgs(args);
    const bench_ds_step = b.step("bench-ds", "Benchmark data structures (list/hash/set/zset)");
    bench_ds_step.dependOn(&run_ds_bench.step);

    // Graph engine benchmark. Same `app` module routing as kv_bench
    // (graph.zig transitively imports vector_store.zig and hnsw.zig,
    // both of which reach into src/storage/ and src/log.zig).
    const graph_bench = b.addExecutable(.{
        .name = "graph_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/graph_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "app", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "build_options", .module = build_opts_mod },
                    },
                }) },
            },
        }),
    });
    const run_graph_bench = b.addRunArtifact(graph_bench);
    if (b.args) |args| run_graph_bench.addArgs(args);
    const bench_graph_step = b.step("bench-graph", "Benchmark graph engine (nodes/edges/traversal/path)");
    bench_graph_step.dependOn(&run_graph_bench.step);

    const persistence_bench = b.addExecutable(.{
        .name = "persistence_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/persistence_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "build_options", .module = build_opts_mod },
                    },
                }) },
            },
        }),
    });
    const run_persistence_bench = b.addRunArtifact(persistence_bench);
    if (b.args) |args| run_persistence_bench.addArgs(args);
    const bench_persistence_step = b.step("bench-persistence", "Benchmark snapshot and AOF persistence paths");
    bench_persistence_step.dependOn(&run_persistence_bench.step);

    // ── DPDK targets ────────────────────────────────────────────────
    // Opt-in (`-Ddpdk=true`); Linux x86_64 only. Requires libdpdk-dev
    // and libmd-dev on the build host (system libraries; zig calls
    // pkg-config to discover them). See tools/dpdk/Dockerfile.dpdk for
    // a reference install line and docs/dpdk.md for the bigger
    // picture. When this option is on we build the two probes from
    // tools/dpdk/ as part of `zig build`, gated by:
    //
    //   * platform check below (early panic on macOS / arm64),
    //   * pkg-config resolution of libdpdk (zig will fail fast if
    //     headers/libs aren't installed),
    //   * a one-line dpdk_shim.c we compile alongside each probe.
    //
    // CI uses this to gate every PR: even though it can't actually
    // *run* the probes without a bound NIC, "does the DPDK build
    // path still link?" catches the breakage class the io_uring race
    // belonged to.
    const dpdk_enabled = b.option(bool, "dpdk", "Build DPDK probes from tools/dpdk/ (Linux x86_64 only; requires libdpdk-dev + libmd-dev)") orelse false;
    if (dpdk_enabled) {
        if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) {
            std.debug.panic(
                "-Ddpdk=true requires linux/x86_64; got {s}/{s}. " ++
                    "Use the tools/dpdk/Dockerfile.dpdk image (--platform=linux/amd64) " ++
                    "to build DPDK probes from a non-Linux host.",
                .{ @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) },
            );
        }

        const dpdk_probes = [_]struct { name: []const u8, src: []const u8 }{
            .{ .name = "hello_lcore", .src = "tools/dpdk/hello_lcore.zig" },
            .{ .name = "port_probe", .src = "tools/dpdk/port_probe.zig" },
        };

        const dpdk_step = b.step("dpdk", "Build the DPDK probes (requires -Ddpdk=true; Linux x86_64 only)");

        for (dpdk_probes) |probe| {
            const exe_probe = b.addExecutable(.{
                .name = probe.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(probe.src),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            // dpdk_shim.c wraps the DPDK symbols that live as
            // static-inline in headers (rte_lcore_id, rte_eth_rx_burst,
            // ...). See tools/dpdk/dpdk_shim.c for the rationale.
            exe_probe.root_module.addCSourceFile(.{
                .file = b.path("tools/dpdk/dpdk_shim.c"),
                .flags = &.{ "-O2", "-Wall", "-Wextra" },
            });
            // Let Zig discover libdpdk + transitive deps (libmd via
            // libbsd, libnuma, libpcap, ...) via pkg-config. `.weak`
            // would suppress the link-time failure; we want the loud
            // version so a misconfigured build host fails fast.
            exe_probe.root_module.linkSystemLibrary("dpdk", .{ .use_pkg_config = .force });
            exe_probe.root_module.linkSystemLibrary("md", .{});
            b.installArtifact(exe_probe);
            dpdk_step.dependOn(&exe_probe.step);
        }
    }
}
