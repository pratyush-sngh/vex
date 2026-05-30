// Unit test entry point. Lives at the repo root so that Zig 0.17's module
// path covers both src/ and tests/unit/ — imports across the two trees
// would be rejected if the root were inside either subdir. Build.zig points
// the `test` step at this file.
//
// During the migration, this file imports both migrated test files (in
// tests/unit/) and src/main.zig (which still has the legacy `test {}`
// block for not-yet-migrated source files). As tests move out of src/,
// the corresponding entry in src/main.zig's `test {}` block is removed.

const std = @import("std");

test {
    // Migrated test files. Sorted by path; one entry per source file that has tests.
    _ = @import("tests/unit/cluster/config_test.zig");
    _ = @import("tests/unit/cluster/protocol_test.zig");
    _ = @import("tests/unit/cluster/replication_test.zig");
    _ = @import("tests/unit/command/comptime_dispatch_test.zig");
    _ = @import("tests/unit/command/handler_test.zig");
    _ = @import("tests/unit/config_test.zig");
    _ = @import("tests/unit/engine/ch_test.zig");
    _ = @import("tests/unit/engine/concurrent_kv_test.zig");
    _ = @import("tests/unit/engine/graph_test.zig");
    _ = @import("tests/unit/engine/hash_test.zig");
    _ = @import("tests/unit/engine/hnsw_test.zig");
    _ = @import("tests/unit/engine/kv_test.zig");
    _ = @import("tests/unit/engine/list_test.zig");
    _ = @import("tests/unit/engine/query_test.zig");
    _ = @import("tests/unit/engine/rag_test.zig");
    _ = @import("tests/unit/engine/set_test.zig");
    _ = @import("tests/unit/engine/sorted_set_test.zig");
    _ = @import("tests/unit/engine/string_intern_test.zig");
    _ = @import("tests/unit/engine/vector_store_test.zig");
    _ = @import("tests/unit/log_test.zig");
    _ = @import("tests/unit/main_test.zig");
    _ = @import("tests/unit/observability/clients_test.zig");
    _ = @import("tests/unit/observability/cmd_table_test.zig");
    _ = @import("tests/unit/observability/event_stats_test.zig");
    _ = @import("tests/unit/observability/stats_test.zig");
    _ = @import("tests/unit/server/event_loop_test.zig");
    _ = @import("tests/unit/server/resp_test.zig");
    _ = @import("tests/unit/server/shard_router_test.zig");
    _ = @import("tests/unit/server/tls_test.zig");
    _ = @import("tests/unit/server/worker_test.zig");
    _ = @import("tests/unit/storage/aof_test.zig");
    _ = @import("tests/unit/storage/atomic_io_test.zig");
    _ = @import("tests/unit/storage/snapshot_test.zig");
}
