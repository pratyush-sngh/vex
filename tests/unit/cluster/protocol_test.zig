// Migrated unit tests for src/cluster/protocol.zig.

const std = @import("std");
const protocol = @import("../../../src/cluster/protocol.zig");

const HEADER_SIZE = protocol.HEADER_SIZE;
const encodeReplRequest = protocol.encodeReplRequest;
const decodeReplRequest = protocol.decodeReplRequest;
const encodeHeartbeat = protocol.encodeHeartbeat;
const decodeHeartbeat = protocol.decodeHeartbeat;
const encodeReplAck = protocol.encodeReplAck;
const decodeReplAck = protocol.decodeReplAck;
const encodeWriteForward = protocol.encodeWriteForward;
const decodeWriteForward = protocol.decodeWriteForward;

test "encode/decode repl_request" {
    const encoded = encodeReplRequest(42);
    const decoded = try decodeReplRequest(&encoded);
    try std.testing.expectEqual(@as(u64, 42), decoded);
}

test "encode/decode heartbeat v2 — round-trip" {
    const encoded = encodeHeartbeat(7, 100, 1234567890);
    const decoded = try decodeHeartbeat(&encoded);
    try std.testing.expectEqual(@as(u64, 7), decoded.epoch);
    try std.testing.expectEqual(@as(u64, 100), decoded.mutation_seq);
    try std.testing.expectEqual(@as(i64, 1234567890), decoded.timestamp_ms);
}

test "decode heartbeat v1 — epoch defaults to 0" {
    var v1_buf: [16]u8 = undefined;
    std.mem.writeInt(u64, v1_buf[0..8], 42, .little);
    std.mem.writeInt(i64, v1_buf[8..16], 1234567890, .little);
    const decoded = try decodeHeartbeat(&v1_buf);
    try std.testing.expectEqual(@as(u64, 0), decoded.epoch);
    try std.testing.expectEqual(@as(u64, 42), decoded.mutation_seq);
}

test "encode/decode repl_ack" {
    const encoded = encodeReplAck(1000, 5);
    const decoded = try decodeReplAck(&encoded);
    try std.testing.expectEqual(@as(u64, 1000), decoded.applied_seq);
    try std.testing.expectEqual(@as(u64, 5), decoded.epoch);
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
