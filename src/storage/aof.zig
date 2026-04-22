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

    /// Rewrite the AOF by serializing current KV + Graph state as commands.
    /// Writes to a temp file, then atomically renames over the current AOF.
    /// This compacts the AOF (removes redundant ops) and bounds its size.
    pub fn rewriteFromState(
        self: *AOF,
        allocator: Allocator,
        kv: *@import("../engine/kv.zig").KVStore,
        graph: *@import("../engine/graph.zig").GraphEngine,
    ) !void {
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.rewrite.tmp", .{self.path});
        defer allocator.free(tmp_path);

        // Write all current state as AOF records to temp file
        const tmp_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{});
        defer tmp_file.close(self.io);

        var tmp_aof = AOF{
            .io = self.io,
            .path = tmp_path,
            .file = tmp_file,
            .snapshot_path = self.snapshot_path,
            .last_save_time = self.last_save_time,
        };

        // KV entries
        var kv_iter = kv.map.iterator();
        while (kv_iter.next()) |entry| {
            if (entry.value_ptr.flags.deleted) continue;
            if (entry.value_ptr.flags.has_ttl) {
                var ttl_buf: [32]u8 = undefined;
                const remaining_ms = entry.value_ptr.expires_at - kv.cached_now_ms;
                if (remaining_ms <= 0) continue; // already expired
                const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{@divTrunc(remaining_ms, 1000)}) catch continue;
                const args = [_][]const u8{ "SET", entry.key_ptr.*, entry.value_ptr.value, "EX", ttl_str };
                tmp_aof.logCommand(&args);
            } else {
                const args = [_][]const u8{ "SET", entry.key_ptr.*, entry.value_ptr.value };
                tmp_aof.logCommand(&args);
            }
        }

        // Graph nodes
        for (0..graph.node_keys.items.len) |i| {
            if (!graph.node_alive.isSet(i)) continue;
            const key = graph.node_keys.items[i];
            const type_str = graph.type_intern.resolve(graph.node_type_id.items[i]);
            const args = [_][]const u8{ "GRAPH.ADDNODE", key, type_str };
            tmp_aof.logCommand(&args);

            // Node properties
            const pairs = graph.node_props.collectAll(@intCast(i), allocator) catch continue;
            defer allocator.free(pairs);
            for (pairs) |pair| {
                const prop_args = [_][]const u8{ "GRAPH.SETPROP", key, pair.key, pair.value };
                tmp_aof.logCommand(&prop_args);
            }
        }

        // Graph edges
        for (0..graph.edge_from.items.len) |i| {
            if (!graph.edge_alive.isSet(i)) continue;
            const from_id = graph.edge_from.items[i];
            const to_id = graph.edge_to.items[i];
            if (from_id >= graph.node_keys.items.len or to_id >= graph.node_keys.items.len) continue;
            const from_key = graph.node_keys.items[from_id];
            const to_key = graph.node_keys.items[to_id];
            const type_str = graph.type_intern.resolve(graph.edge_type_id.items[i]);
            var weight_buf: [32]u8 = undefined;
            const weight_str = std.fmt.bufPrint(&weight_buf, "{d:.6}", .{graph.edge_weight.items[i]}) catch continue;
            const args = [_][]const u8{ "GRAPH.ADDEDGE", from_key, to_key, type_str, weight_str };
            tmp_aof.logCommand(&args);
        }

        // Atomic rename: replace old AOF with rewritten one
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        // Close current file, rename tmp over it, reopen
        self.file.close(self.io);
        const old_path_z = allocator.dupeZ(u8, self.path) catch return;
        defer allocator.free(old_path_z);
        const tmp_path_z = allocator.dupeZ(u8, tmp_path) catch return;
        defer allocator.free(tmp_path_z);
        _ = c.rename(tmp_path_z, old_path_z);

        self.file = std.Io.Dir.cwd().createFile(self.io, self.path, .{
            .truncate = false,
            .read = true,
        }) catch return;
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
