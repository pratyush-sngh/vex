// Migrated unit tests for src/engine/string_intern.zig.

const std = @import("std");
const si_mod = @import("../../../src/engine/string_intern.zig");
const StringIntern = si_mod.StringIntern;
const TypeMask = si_mod.TypeMask;

test "intern and resolve" {
    var si = StringIntern.init(std.testing.allocator);
    defer si.deinit();

    const id0 = try si.intern("service");
    const id1 = try si.intern("database");
    const id2 = try si.intern("service"); // duplicate

    try std.testing.expectEqual(@as(u16, 0), id0);
    try std.testing.expectEqual(@as(u16, 1), id1);
    try std.testing.expectEqual(id0, id2); // same ID for duplicate

    try std.testing.expectEqualStrings("service", si.resolve(0));
    try std.testing.expectEqualStrings("database", si.resolve(1));
    try std.testing.expectEqual(@as(u16, 2), si.count());
}

test "find returns null for unknown" {
    var si = StringIntern.init(std.testing.allocator);
    defer si.deinit();

    _ = try si.intern("known");
    try std.testing.expect(si.find("known") != null);
    try std.testing.expect(si.find("unknown") == null);
}

test "mask bit positions" {
    try std.testing.expectEqual(@as(TypeMask, 1), StringIntern.mask(0));
    try std.testing.expectEqual(@as(TypeMask, 2), StringIntern.mask(1));
    try std.testing.expectEqual(@as(TypeMask, 1 << 63), StringIntern.mask(63));
}

test "max interned limit" {
    var si = StringIntern.init(std.testing.allocator);
    defer si.deinit();

    var buf: [8]u8 = undefined;
    for (0..64) |i| {
        const s = std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable;
        _ = try si.intern(s);
    }
    try std.testing.expectEqual(@as(u16, 64), si.count());

    const result = si.intern("one_too_many");
    try std.testing.expect(result == error.TooManyInternedStrings);
}
