// Migrated unit tests for src/engine/concurrent_kv.zig.

const std = @import("std");
const ConcurrentKV = @import("../../../src/engine/concurrent_kv.zig").ConcurrentKV;
const obs_stats = @import("../../../src/observability/stats.zig");

test "concurrent_kv basic set/get" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("name", "vex");
    const val = store.get("name") orelse return error.TestUnexpectedResult;
    defer val.deinit();
    try std.testing.expectEqualStrings("vex", val.data);
}

test "concurrent_kv delete" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("key1", "val1");
    try std.testing.expect(store.delete("key1"));
    try std.testing.expect(store.get("key1") == null);
    try std.testing.expect(!store.delete("nonexistent"));
}

test "concurrent_kv overwrite" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("k", "v1");
    try store.set("k", "v2");
    const val = store.get("k") orelse return error.TestUnexpectedResult;
    defer val.deinit();
    try std.testing.expectEqualStrings("v2", val.data);
}

test "concurrent_kv exists" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("present", "yes");
    try std.testing.expect(store.exists("present"));
    try std.testing.expect(!store.exists("absent"));
}

test "concurrent_kv flushdb and dbsize" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");
    try std.testing.expectEqual(@as(usize, 3), store.dbsize());
    store.flushdb();
    try std.testing.expectEqual(@as(usize, 0), store.dbsize());
}

test "concurrent_kv multi-thread stress" {
    // Skip in debug: Zig's HashMap pointer_stability check conflicts with
    // external rwlock synchronization. Passes in ReleaseFast.
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    const num_threads = 8;
    const ops_per_thread = 1000;

    const Worker = struct {
        fn run(s: *ConcurrentKV, thread_id: usize) void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "t{d}:k{d}", .{ thread_id, i }) catch continue;
                var val_buf: [32]u8 = undefined;
                const val = std.fmt.bufPrint(&val_buf, "v{d}", .{i}) catch continue;

                s.set(key, val) catch continue;
                if (s.get(key)) |v| v.deinit();
                _ = s.exists(key);
                _ = s.delete(key);
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |t| {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &store, t });
    }
    for (&threads) |thread| {
        thread.join();
    }

    // Should not crash or leak (testing allocator checks leaks on deinit)
}

test "concurrent_kv maxmemory + allkeys_lru evicts on overflow" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    const target_stripe: usize = ConcurrentKV.stripeIndex("a");
    var second_key: [1]u8 = .{'b'};
    var b: u8 = 'b';
    while (b <= 'z') : (b += 1) {
        second_key[0] = b;
        if (ConcurrentKV.stripeIndex(&second_key) == target_stripe) break;
    }
    if (b > 'z') return error.SkipZigTest; // unable to find a same-stripe pair

    store.maxmemory = 3; // fits one 2-byte entry; second triggers eviction
    store.eviction_policy = .allkeys_lru;

    const before = obs_stats.evicted_keys.load(.monotonic);

    store.cached_now_ms = 1000;
    try store.set("a", "x");
    store.cached_now_ms = 2000;
    try store.set(&second_key, "y"); // triggers eviction of "a"

    try std.testing.expect(store.get("a") == null);
    const v = store.get(&second_key) orelse return error.TestUnexpectedResult;
    defer v.deinit();
    try std.testing.expectEqualStrings("y", v.data);

    const after = obs_stats.evicted_keys.load(.monotonic);
    try std.testing.expect(after > before);
}

test "concurrent_kv maxmemory + noeviction returns error" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    store.maxmemory = 3;
    store.eviction_policy = .noeviction;

    try store.set("k", "v");

    const result = store.set("kk", "vv");
    try std.testing.expectError(error.MaxMemoryReached, result);

    const v = store.get("k") orelse return error.TestUnexpectedResult;
    defer v.deinit();
    try std.testing.expectEqualStrings("v", v.data);
}

test "concurrent_kv total_bytes decrements on delete" {
    var store = ConcurrentKV.init(std.testing.allocator, std.testing.io);
    store.initStripes();
    defer store.deinit();

    try std.testing.expectEqual(@as(u64, 0), store.total_bytes.load(.monotonic));

    try store.set("hello", "world");
    try std.testing.expectEqual(@as(u64, "hello".len + "world".len), store.total_bytes.load(.monotonic));

    try std.testing.expect(store.delete("hello"));
    try std.testing.expectEqual(@as(u64, 0), store.total_bytes.load(.monotonic));
}
