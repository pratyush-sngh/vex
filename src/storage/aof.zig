const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const span = @import("../perf/span.zig");

/// Append-Only File for write-ahead logging.
pub const AOF = struct {
    io: std.Io,
    path: []const u8,
    file: std.Io.File,
    write_buf: [4096]u8 = undefined,
    snapshot_path: []const u8,
    last_save_time: i64,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    prof: ?*span.Profile = null,

    pub fn init(io: std.Io, path: []const u8, snapshot_path: []const u8) !AOF {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .read = true,
        });
        errdefer file.close(io);
        return .{
            .io = io,
            .path = path,
            .file = file,
            .snapshot_path = snapshot_path,
            .last_save_time = 0,
        };
    }

    pub fn deinit(self: *AOF) void {
        self.file.close(self.io);
    }

    pub fn logCommand(self: *AOF, args: []const []const u8) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.writeRecord(args) catch {};
    }

    fn writeRecord(self: *AOF, args: []const []const u8) !void {
        const t0 = std.Io.Clock.Timestamp.now(self.io, .awake);
        var fw = std.Io.File.writer(self.file, self.io, &self.write_buf);
        try fw.seekTo(try self.file.length(self.io));
        const w = &fw.interface;

        var ts_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &ts_buf, std.Io.Timestamp.now(self.io, .real).toMilliseconds(), .little);
        try w.writeAll(&ts_buf);

        var ac_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &ac_buf, @intCast(args.len), .little);
        try w.writeAll(&ac_buf);

        for (args) |arg| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(arg.len), .little);
            try w.writeAll(&len_buf);
            try w.writeAll(arg);
        }
        try w.flush();
        const t1 = std.Io.Clock.Timestamp.now(self.io, .awake);
        if (self.prof) |p| p.recordAofWrite(span.monotonicNs(t0, t1));
    }

    pub fn truncate(self: *AOF) !void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        try self.file.setLength(self.io, 0);
    }
};

fn readFileAll(file: std.Io.File, io: std.Io, allocator: Allocator, max_len: usize) ![]u8 {
    const len64 = try file.length(io);
    const len: usize = @intCast(len64);
    if (len > max_len) return error.StreamTooLong;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != len) return error.UnexpectedEof;
    return buf;
}

/// Replay an AOF file through any object with `execute(args, *std.Io.Writer)`.
pub fn replayFile(io: std.Io, allocator: Allocator, path: []const u8, handler: anytype) !u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer file.close(io);

    const data = try readFileAll(file, io, allocator, 1 << 30);
    defer allocator.free(data);

    if (data.len == 0) return 0;

    var discard_list: std.ArrayList(u8) = .empty;
    defer discard_list.deinit(allocator);
    var discard_aw = std.Io.Writer.Allocating.fromArrayList(allocator, &discard_list);
    defer discard_aw.deinit();

    var count: u64 = 0;
    var pos: usize = 0;

    while (pos + 10 <= data.len) {
        pos += 8; // skip timestamp

        const arg_count = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        const args = allocator.alloc([]const u8, arg_count) catch break;
        defer allocator.free(args);

        var valid = true;
        for (0..arg_count) |i| {
            if (pos + 4 > data.len) {
                valid = false;
                break;
            }
            const arg_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (pos + arg_len > data.len) {
                valid = false;
                break;
            }
            args[i] = data[pos .. pos + arg_len];
            pos += arg_len;
        }

        if (!valid) break;

        discard_aw.clearRetainingCapacity();
        handler.execute(args, &discard_aw.writer) catch {};
        count += 1;
    }

    return count;
}

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

const MockHandler = struct {
    count: *u64,

    pub fn execute(self: *MockHandler, _: []const []const u8, _: *std.Io.Writer) std.Io.Writer.Error!void {
        self.count.* += 1;
    }
};
