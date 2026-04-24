const std = @import("std");
const Allocator = std.mem.Allocator;

/// Binary frame protocol for inter-node replication.
///
/// Frame format:
///   [2 bytes] magic: "VX"
///   [1 byte]  frame_type
///   [4 bytes] payload_len (u32, little-endian)
///   [N bytes] payload
///
/// Total header: 7 bytes. Compact for high-frequency replication traffic.

pub const MAGIC = [2]u8{ 'V', 'X' };
pub const HEADER_SIZE = 7;

pub const FrameType = enum(u8) {
    heartbeat = 0x01,
    repl_request = 0x02, // follower → leader: "send mutations since seq N"
    repl_data = 0x03, // leader → follower: batch of AOF records
    full_sync_request = 0x04,
    full_sync_data = 0x05, // leader → follower: snapshot bytes
    write_forward = 0x06, // follower → leader: forwarded write command
    write_forward_response = 0x07, // leader → follower: response to forward
};

pub const Frame = struct {
    frame_type: FrameType,
    payload: []const u8,
};

/// Write a frame to a file descriptor using libc write.
pub fn writeFrame(fd: i32, frame_type: FrameType, payload: []const u8) !void {
    var header: [HEADER_SIZE]u8 = undefined;
    header[0] = MAGIC[0];
    header[1] = MAGIC[1];
    header[2] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, header[3..7], @intCast(payload.len), .little);

    // Write header
    try writeAll(fd, &header);
    // Write payload
    if (payload.len > 0) {
        try writeAll(fd, payload);
    }
}

/// Read a frame from a file descriptor. Caller owns the returned payload.
pub fn readFrame(fd: i32, allocator: Allocator) !Frame {
    var header: [HEADER_SIZE]u8 = undefined;
    try readExact(fd, &header);

    if (header[0] != MAGIC[0] or header[1] != MAGIC[1]) {
        return error.InvalidMagic;
    }

    const frame_type: FrameType = @enumFromInt(header[2]);
    const payload_len = std.mem.readInt(u32, header[3..7], .little);

    if (payload_len > 64 * 1024 * 1024) { // 64MB max frame
        return error.FrameTooLarge;
    }

    if (payload_len == 0) {
        return .{ .frame_type = frame_type, .payload = &.{} };
    }

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try readExact(fd, payload);

    return .{ .frame_type = frame_type, .payload = payload };
}

/// Build a heartbeat payload: leader's current mutation_seq + timestamp.
pub fn encodeHeartbeat(mutation_seq: u64, timestamp_ms: i64) [16]u8 {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], mutation_seq, .little);
    std.mem.writeInt(i64, buf[8..16], timestamp_ms, .little);
    return buf;
}

/// Decode a heartbeat payload.
pub fn decodeHeartbeat(payload: []const u8) !struct { mutation_seq: u64, timestamp_ms: i64 } {
    if (payload.len < 16) return error.InvalidPayload;
    return .{
        .mutation_seq = std.mem.readInt(u64, payload[0..8], .little),
        .timestamp_ms = std.mem.readInt(i64, payload[8..16], .little),
    };
}

/// Build a repl_request payload: just a u64 sequence number.
pub fn encodeReplRequest(seq: u64) [8]u8 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, seq, .little);
    return buf;
}

/// Decode a repl_request payload.
pub fn decodeReplRequest(payload: []const u8) !u64 {
    if (payload.len < 8) return error.InvalidPayload;
    return std.mem.readInt(u64, payload[0..8], .little);
}

/// Build a write_forward payload: RESP-encoded command args.
/// Format: [2 bytes] argc + [4 bytes + data] per arg (same as AOF record without timestamp).
pub fn encodeWriteForward(allocator: Allocator, args: []const []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    var argc_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &argc_buf, @intCast(args.len), .little);
    try buf.appendSlice(&argc_buf);

    for (args) |arg| {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(arg.len), .little);
        try buf.appendSlice(&len_buf);
        try buf.appendSlice(arg);
    }

    return buf.toOwnedSlice();
}

/// Decode a write_forward payload back to args.
pub fn decodeWriteForward(allocator: Allocator, payload: []const u8) ![][]const u8 {
    if (payload.len < 2) return error.InvalidPayload;

    const argc = std.mem.readInt(u16, payload[0..2], .little);
    const args = try allocator.alloc([]const u8, argc);
    errdefer allocator.free(args);

    var pos: usize = 2;
    for (0..argc) |i| {
        if (pos + 4 > payload.len) return error.InvalidPayload;
        const arg_len = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        if (pos + arg_len > payload.len) return error.InvalidPayload;
        args[i] = payload[pos .. pos + arg_len];
        pos += arg_len;
    }

    return args;
}

// ─── I/O helpers ────────────────────────────────────────────────────

fn writeAll(fd: i32, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.c.write(fd, data[written..].ptr, data.len - written);
        if (rc < 0) return error.WriteFailed;
        if (rc == 0) return error.ConnectionClosed;
        written += @intCast(rc);
    }
}

fn readExact(fd: i32, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (rc < 0) return error.ReadFailed;
        if (rc == 0) return error.ConnectionClosed;
        total += @intCast(rc);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────

test "encode/decode repl_request" {
    const encoded = encodeReplRequest(42);
    const decoded = try decodeReplRequest(&encoded);
    try std.testing.expectEqual(@as(u64, 42), decoded);
}

test "encode/decode write_forward" {
    const args = [_][]const u8{ "SET", "key", "value" };
    const encoded = try encodeWriteForward(std.testing.allocator, &args);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeWriteForward(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    try std.testing.expectEqualStrings("SET", decoded[0]);
    try std.testing.expectEqualStrings("key", decoded[1]);
    try std.testing.expectEqualStrings("value", decoded[2]);
}

test "frame header size" {
    try std.testing.expectEqual(@as(usize, 7), HEADER_SIZE);
}
