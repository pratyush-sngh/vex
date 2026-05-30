const std = @import("std");

// Canonical version: build.zig.zon's `.version` field. The build option
// below propagates it to every Zig target that needs to report it (vex
// binary, persistence_bench, etc.), so a release bump touches one line.
const vex_version: []const u8 = @import("build.zig.zon").version;

const BenchSpec = struct {
    name: []const u8,
    source: []const u8,
    step: []const u8,
    desc: []const u8,
    link_libc: bool = true,
    imports: []const std.Build.Module.Import = &.{},
};

fn addBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spec: BenchSpec,
) void {
    const exe = b.addExecutable(.{
        .name = spec.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(spec.source),
            .target = target,
            .optimize = optimize,
            .link_libc = if (spec.link_libc) true else null,
            .imports = spec.imports,
        }),
    });
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step(spec.step, spec.desc).dependOn(&run.step);
}

fn simpleModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sanitizer profiles. The chaos suite (tests/chaos/) exercises these via
    // dedicated Makefile targets (test-tsan, test-release-safe).
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    const sanitize_c = b.option(bool, "sanitize-c", "Enable UBSan / -fsanitize-c=full") orelse false;

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", vex_version);
    const build_opts_mod = build_opts.createModule();

    // ── vex binary ────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "vex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = if (sanitize_thread) true else null,
            .sanitize_c = if (sanitize_c) .full else null,
            .imports = &.{.{ .name = "build_options", .module = build_opts_mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run vex server").dependOn(&run_cmd.step);

    // ── vex-sentinel: failover orchestrator ───────────────────────────
    // Reuses a handful of vex modules via build.zig imports — no premature
    // common/ extraction. vex_resp isn't consumed yet but is kept wired for
    // the upcoming health.tickOnce() PR (RESP parsing of PING / VEX.STATUS
    // replies). Drop if that PR slips past one release cycle.
    const sentinel_imports = [_]std.Build.Module.Import{
        .{ .name = "vex_log", .module = simpleModule(b, target, optimize, "src/log.zig") },
        .{ .name = "vex_atomic_io", .module = simpleModule(b, target, optimize, "src/storage/atomic_io.zig") },
        .{ .name = "vex_resp", .module = simpleModule(b, target, optimize, "src/server/resp.zig") },
        .{ .name = "vex_cluster_config", .module = simpleModule(b, target, optimize, "src/cluster/config.zig") },
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

    const run_sentinel = b.addRunArtifact(sentinel_exe);
    run_sentinel.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_sentinel.addArgs(args);
    b.step("run-sentinel", "Run vex-sentinel").dependOn(&run_sentinel.step);

    const sentinel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("sentinel/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &sentinel_imports,
        }),
    });
    b.step("test-sentinel", "Run vex-sentinel unit tests").dependOn(&b.addRunArtifact(sentinel_tests).step);

    // ── Test root ─────────────────────────────────────────────────────
    // test_main.zig sits at the repo root so Zig 0.17's module-path check
    // allows @imports into both src/ and tests/unit/ from a single entry.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = if (sanitize_thread) true else null,
            .sanitize_c = if (sanitize_c) .full else null,
            .imports = &.{.{ .name = "build_options", .module = build_opts_mod }},
        }),
    });
    b.step("test", "Run all unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    // ── Benchmarks ────────────────────────────────────────────────────
    const verztable_mod = b.createModule(.{
        .root_source_file = b.path("vendor/verztable/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_opts_mod }},
    });

    addBench(b, target, optimize, .{
        .name = "hashmap_bench",
        .source = "bench/hashmap_bench.zig",
        .step = "bench-hashmap",
        .desc = "Benchmark std vs verztable string maps",
        .link_libc = false,
        .imports = &.{.{ .name = "verztable", .module = verztable_mod }},
    });
    // bench-kv and bench-graph route through the `app` module (rooted at
    // src/root.zig) so they can reach engine code whose internal imports
    // cross src/engine/ → src/observability/, etc. Without this indirection
    // a module rooted at src/engine/* can't escape the engine/ subtree and
    // the build fails with "import of file outside module path". The bench
    // sources live in src/bench/ to match.
    addBench(b, target, optimize, .{
        .name = "kv_bench",
        .source = "src/bench/kv_bench.zig",
        .step = "bench-kv",
        .desc = "Benchmark KV engine (SET/GET/DEL)",
        .imports = &.{.{ .name = "app", .module = app_mod }},
    });
    addBench(b, target, optimize, .{
        .name = "ds_bench",
        .source = "src/engine/ds_bench.zig",
        .step = "bench-ds",
        .desc = "Benchmark data structures (list/hash/set/zset)",
    });
    addBench(b, target, optimize, .{
        .name = "graph_bench",
        .source = "src/bench/graph_bench.zig",
        .step = "bench-graph",
        .desc = "Benchmark graph engine (nodes/edges/traversal/path)",
        .imports = &.{.{ .name = "app", .module = app_mod }},
    });
    addBench(b, target, optimize, .{
        .name = "persistence_bench",
        .source = "src/bench/persistence_bench.zig",
        .step = "bench-persistence",
        .desc = "Benchmark snapshot and AOF persistence paths",
        .imports = &.{.{ .name = "app", .module = app_mod }},
    });
}
