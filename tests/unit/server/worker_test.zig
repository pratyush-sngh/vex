// Migrated unit tests for src/server/worker.zig (PubSubRegistry tests only).

const std = @import("std");
const worker_mod = @import("../../../src/server/worker.zig");
const PubSubRegistry = worker_mod.PubSubRegistry;
const Subscriber = worker_mod.Subscriber;
const Worker = worker_mod.Worker;

// Tests pass a dummy *Worker. The registry stores the pointer but never
// dereferences it; routing in handlePublish does the deref, and these
// tests cover the registry's fd-tracking only. Real storage so the
// pointer satisfies @alignOf(Worker).
var test_worker_storage: [@sizeOf(Worker)]u8 align(@alignOf(Worker)) = undefined;
const test_worker_stub: *Worker = @ptrCast(@alignCast(&test_worker_storage));

test "PubSubRegistry subscribe and getSubscribers" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("news", 10, test_worker_stub);
    try ps.subscribe("news", 20, test_worker_stub);
    try ps.subscribe("sports", 30, test_worker_stub);

    var subs = std.array_list.Managed(Subscriber).init(std.testing.allocator);
    defer subs.deinit();

    ps.getSubscribers("news", &subs);
    try std.testing.expectEqual(@as(usize, 2), subs.items.len);

    subs.clearRetainingCapacity();
    ps.getSubscribers("sports", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    try std.testing.expectEqual(@as(i32, 30), subs.items[0].fd);

    subs.clearRetainingCapacity();
    ps.getSubscribers("nonexistent", &subs);
    try std.testing.expectEqual(@as(usize, 0), subs.items.len);
}

test "PubSubRegistry unsubscribe" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("ch", 10, test_worker_stub);
    try ps.subscribe("ch", 20, test_worker_stub);

    ps.unsubscribe("ch", 10);

    var subs = std.array_list.Managed(Subscriber).init(std.testing.allocator);
    defer subs.deinit();
    ps.getSubscribers("ch", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    try std.testing.expectEqual(@as(i32, 20), subs.items[0].fd);
}

test "PubSubRegistry unsubscribeAll" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("a", 10, test_worker_stub);
    try ps.subscribe("b", 10, test_worker_stub);
    try ps.subscribe("a", 20, test_worker_stub);

    ps.unsubscribeAll(10);

    var subs = std.array_list.Managed(Subscriber).init(std.testing.allocator);
    defer subs.deinit();

    ps.getSubscribers("a", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    try std.testing.expectEqual(@as(i32, 20), subs.items[0].fd);

    subs.clearRetainingCapacity();
    ps.getSubscribers("b", &subs);
    try std.testing.expectEqual(@as(usize, 0), subs.items.len);
}

test "PubSubRegistry duplicate subscribe ignored" {
    var ps = PubSubRegistry.init(std.testing.allocator);
    defer ps.deinit();

    try ps.subscribe("ch", 10, test_worker_stub);
    try ps.subscribe("ch", 10, test_worker_stub); // duplicate

    var subs = std.array_list.Managed(Subscriber).init(std.testing.allocator);
    defer subs.deinit();
    ps.getSubscribers("ch", &subs);
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
}
