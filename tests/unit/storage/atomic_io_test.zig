// Migrated unit tests for src/storage/atomic_io.zig.

const std = @import("std");
const c = std.c;
const atomic_io = @import("../../../src/storage/atomic_io.zig");

const atomicWrite = atomic_io.atomicWrite;
const fsyncDir = atomic_io.fsyncDir;

test "atomicWrite — round-trip" {
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_atomic_io_test.bin";
    defer _ = c.unlink(path);

    const payload = "hello atomic durability";
    try atomicWrite(allocator, path, payload);

    // Read back and verify.
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    var buf: [128]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings(payload, buf[0..@intCast(n)]);
}

test "atomicWrite — overwrite existing file" {
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_atomic_io_overwrite.bin";
    defer _ = c.unlink(path);

    try atomicWrite(allocator, path, "first");
    try atomicWrite(allocator, path, "second_longer_payload");

    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    var buf: [128]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    try std.testing.expectEqualStrings("second_longer_payload", buf[0..@intCast(n)]);
}

test "atomicWrite — no tmp file left behind on success" {
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_atomic_io_no_leftover.bin";
    defer _ = c.unlink(path);

    try atomicWrite(allocator, path, "ok");

    const pid = c.getpid();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, pid });
    defer allocator.free(tmp_path);
    const tmp_z = try allocator.dupeSentinel(u8, tmp_path, 0);
    defer allocator.free(tmp_z);
    // After successful rename, tmp must not exist.
    const fd = c.open(tmp_z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    try std.testing.expect(fd < 0);
}

test "fsyncDir — works on a regular directory" {
    const allocator = std.testing.allocator;
    try fsyncDir(allocator, "/tmp/some_file_in_tmp");
}
