// Migrated unit tests for src/storage/aof.zig.

const std = @import("std");
const aof_mod = @import("../../../src/storage/aof.zig");

const AOF = aof_mod.AOF;
const replayFile = aof_mod.replayFile;

const MockHandler = struct {
    count: *u64,

    pub fn execute(self: *MockHandler, _: []const []const u8, _: *std.Io.Writer) std.Io.Writer.Error!void {
        self.count.* += 1;
    }
};

test "aof write and replay" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_test.aof";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var a = try AOF.init(io, path, "/tmp/dummy.zdb");
        defer a.deinit();
        const set_args = [_][]const u8{ "SET", "key", "val" };
        a.logCommand(&set_args);
        const del_args = [_][]const u8{ "DEL", "key" };
        a.logCommand(&del_args);
    }

    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, path, &mock);
    try std.testing.expectEqual(@as(u64, 2), replayed);
    try std.testing.expectEqual(@as(u64, 2), exec_count);
}

test "aof truncate" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_trunc_test.aof";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var a = try AOF.init(io, path, "/tmp/dummy.zdb");
    defer a.deinit();

    const args = [_][]const u8{ "SET", "x", "y" };
    a.logCommand(&args);

    try a.truncate();

    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, path, &mock);
    try std.testing.expectEqual(@as(u64, 0), replayed);
}

test "aof replay missing file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, "/tmp/nonexistent_vex.aof", &mock);
    try std.testing.expectEqual(@as(u64, 0), replayed);
}

test "aof group commit buffer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "/tmp/vex_group_test.aof";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var a = try AOF.init(io, path, "/tmp/dummy.zdb");
        defer a.deinit();
        a.initGroupBuf(allocator);

        // logCommand should buffer, not write to file
        const set1 = [_][]const u8{ "SET", "k1", "v1" };
        a.logCommand(&set1);
        const set2 = [_][]const u8{ "SET", "k2", "v2" };
        a.logCommand(&set2);

        // Buffer should have data, file should be empty (or just have old data)
        try std.testing.expect(a.group_buf.items.len > 0);

        // flush() should write everything to file
        a.flush();
        try std.testing.expectEqual(@as(usize, 0), a.group_buf.items.len);
    }

    // Replay should find both commands
    var exec_count: u64 = 0;
    var mock = MockHandler{ .count = &exec_count };
    const replayed = try replayFile(io, allocator, path, &mock);
    try std.testing.expectEqual(@as(u64, 2), replayed);
}
