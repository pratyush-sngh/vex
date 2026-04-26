const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Single test root: main.zig's test block imports all modules (Zig 0.16 module paths).
    const test_step = b.step("test", "Run all unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
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

    // KV engine benchmark
    const kv_bench = b.addExecutable(.{
        .name = "kv_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/kv_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
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
                }) },
            },
        }),
    });
    const run_persistence_bench = b.addRunArtifact(persistence_bench);
    if (b.args) |args| run_persistence_bench.addArgs(args);
    const bench_persistence_step = b.step("bench-persistence", "Benchmark snapshot and AOF persistence paths");
    bench_persistence_step.dependOn(&run_persistence_bench.step);
}
