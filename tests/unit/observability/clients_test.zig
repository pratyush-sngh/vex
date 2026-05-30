// Migrated unit tests for src/observability/clients.zig.

const std = @import("std");
const clients = @import("../../../src/observability/clients.zig");

const ClientView = clients.ClientView;
const MAX_NAME_LEN = clients.MAX_NAME_LEN;
const register = clients.register;
const unregister = clients.unregister;
const snapshot = clients.snapshot;
const count = clients.count;
const resetForTest = clients.resetForTest;

test "register and snapshot" {
    resetForTest();
    defer resetForTest();
    var v1 = ClientView{ .id = 1, .fd = 10 };
    var v2 = ClientView{ .id = 2, .fd = 11 };
    v1.setName("alice");
    v2.setAddr("127.0.0.1:6380");
    try std.testing.expect(register(&v1));
    try std.testing.expect(register(&v2));
    try std.testing.expectEqual(@as(usize, 2), count());

    const snap = try snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    var saw_alice = false;
    var saw_v2 = false;
    for (snap) |s| {
        if (s.id == 1) {
            saw_alice = true;
            try std.testing.expectEqualStrings("alice", s.nameSlice());
        }
        if (s.id == 2) {
            saw_v2 = true;
            try std.testing.expectEqualStrings("127.0.0.1:6380", s.addrSlice());
        }
    }
    try std.testing.expect(saw_alice and saw_v2);
}

test "unregister" {
    resetForTest();
    defer resetForTest();
    var v1 = ClientView{ .id = 1 };
    var v2 = ClientView{ .id = 2 };
    _ = register(&v1);
    _ = register(&v2);
    try std.testing.expectEqual(@as(usize, 2), count());
    unregister(&v1);
    try std.testing.expectEqual(@as(usize, 1), count());
    const snap = try snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqual(@as(u64, 2), snap[0].id);
}

test "register is idempotent" {
    resetForTest();
    defer resetForTest();
    var v = ClientView{ .id = 7 };
    try std.testing.expect(register(&v));
    try std.testing.expect(register(&v));
    try std.testing.expectEqual(@as(usize, 1), count());
}

test "setName truncates" {
    var v = ClientView{};
    var big: [128]u8 = undefined;
    @memset(&big, 'x');
    v.setName(&big);
    try std.testing.expectEqual(@as(usize, MAX_NAME_LEN), v.nameSlice().len);
}
