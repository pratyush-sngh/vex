// Migrated unit tests for src/engine/kv.zig.

const std = @import("std");
const kv_mod = @import("../../../src/engine/kv.zig");
const KVStore = kv_mod.KVStore;
const globMatch = kv_mod.globMatch;

test "kv basic set/get" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("name", "vex");
    const val = store.get("name");
    try std.testing.expectEqualStrings("vex", val.?);
}

test "kv delete is tombstone" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("key1", "val1");
    try std.testing.expectEqual(@as(u32, 1), store.live_count);

    try std.testing.expect(store.delete("key1"));
    try std.testing.expect(store.get("key1") == null);
    try std.testing.expectEqual(@as(u32, 0), store.live_count);
    try std.testing.expectEqual(@as(u32, 1), store.tombstone_count);

    // Key is still in the map (tombstoned)
    try std.testing.expect(store.map.contains("key1"));

    try std.testing.expect(!store.delete("nonexistent"));
}

test "kv set reuses tombstone" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("k", "v1");
    try std.testing.expect(store.delete("k"));
    try std.testing.expectEqual(@as(u32, 1), store.tombstone_count);

    try store.set("k", "v2");
    try std.testing.expectEqual(@as(u32, 0), store.tombstone_count);
    try std.testing.expectEqual(@as(u32, 1), store.live_count);
    try std.testing.expectEqualStrings("v2", store.get("k").?);
}

test "kv overwrite" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("k", "v1");
    try store.set("k", "v2");
    try std.testing.expectEqualStrings("v2", store.get("k").?);
    try std.testing.expectEqual(@as(u32, 1), store.live_count);
}

test "kv exists" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("present", "yes");
    try std.testing.expect(store.exists("present"));
    try std.testing.expect(!store.exists("absent"));
}

test "kv dbsize counts live only" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");
    try std.testing.expectEqual(@as(usize, 3), store.dbsize());

    _ = store.delete("b");
    try std.testing.expectEqual(@as(usize, 2), store.dbsize());
}

test "kv compact tombstones" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");
    _ = store.delete("a");
    _ = store.delete("b");

    try std.testing.expectEqual(@as(u32, 2), store.tombstone_count);
    try std.testing.expect(store.needsCompaction());

    store.compactTombstones();

    try std.testing.expectEqual(@as(u32, 0), store.tombstone_count);
    try std.testing.expectEqual(@as(u32, 1), store.live_count);
    try std.testing.expect(!store.map.contains("a"));
    try std.testing.expect(!store.map.contains("b"));
    try std.testing.expectEqualStrings("3", store.get("c").?);
}

test "kv ttl_count tracking" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("noexpiry", "val");
    try std.testing.expectEqual(@as(u32, 0), store.ttl_count);

    try store.setEx("withexpiry", "val", 3600);
    try std.testing.expectEqual(@as(u32, 1), store.ttl_count);

    try store.set("withexpiry", "newval");
    try std.testing.expectEqual(@as(u32, 0), store.ttl_count);
}

test "kv keys skips tombstones" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");
    _ = store.delete("b");

    const result = try store.keys(std.testing.allocator, "*");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "kv flushdb resets counters" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("a", "1");
    try store.setEx("b", "2", 100);
    _ = store.delete("a");
    store.flushdb();

    try std.testing.expectEqual(@as(u32, 0), store.ttl_count);
    try std.testing.expectEqual(@as(u32, 0), store.tombstone_count);
    try std.testing.expectEqual(@as(u32, 0), store.live_count);
}

test "kv memoryUsage" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.memoryUsage());

    try store.set("key1", "value1");
    const usage1 = store.memoryUsage();
    try std.testing.expect(usage1 > 0);

    try store.set("key2", "value2");
    const usage2 = store.memoryUsage();
    try std.testing.expect(usage2 > usage1);

    _ = store.delete("key1");
    const usage3 = store.memoryUsage();
    try std.testing.expect(usage3 < usage2);
}

test "kv LRU eviction" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    store.eviction_policy = .allkeys_lru;
    store.maxmemory = 1;

    try store.set("first", "val");
    try store.set("second", "val");

    try std.testing.expect(store.live_count >= 1);
}

test "kv noeviction returns error" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    store.eviction_policy = .noeviction;
    store.maxmemory = 1;

    try store.set("first", "val");

    try std.testing.expectError(error.OutOfMemory, store.set("second", "val"));
}

test "kv last_access updated on GET" {
    var store = KVStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();

    try store.set("mykey", "myvalue");
    const entry1 = store.map.getPtr("mykey").?;
    const access1 = entry1.last_access;

    store.cached_now_ms += 1000;
    _ = store.get("mykey");

    const entry2 = store.map.getPtr("mykey").?;
    try std.testing.expect(entry2.last_access > access1);
}

test "glob matcher" {
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("hello*", "helloworld"));
    try std.testing.expect(globMatch("h?llo", "hello"));
    try std.testing.expect(!globMatch("h?llo", "hllo"));
    try std.testing.expect(globMatch("user:*:name", "user:42:name"));
}
