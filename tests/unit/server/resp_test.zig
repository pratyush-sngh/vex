// Migrated unit tests for src/protocol/resp.zig.

const std = @import("std");
const resp = @import("../../../src/protocol/resp.zig");

const Parser = resp.Parser;
const serializeBulkString = resp.serializeBulkString;
const parseInlineCommand = resp.parseInlineCommand;
const serializeNull = resp.serializeNull;
const serializeMapHeader = resp.serializeMapHeader;
const serializeNullValue = resp.serializeNullValue;

test "parse simple RESP array" {
    const allocator = std.testing.allocator;
    const input = "*2\r\n$4\r\nPING\r\n$5\r\nhello\r\n";
    var parser = Parser.init(input);
    var val = try parser.parse(allocator);
    defer val.deinit(allocator);

    const arr = val.array.?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("PING", arr[0].bulk_string.?);
    try std.testing.expectEqualStrings("hello", arr[1].bulk_string.?);
}

test "parse bulk string null" {
    const allocator = std.testing.allocator;
    const input = "$-1\r\n";
    var parser = Parser.init(input);
    var val = try parser.parse(allocator);
    defer val.deinit(allocator);

    try std.testing.expect(val.bulk_string == null);
}

test "serialize round-trip" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();

    try serializeBulkString(&aw.writer, "hello");
    try std.testing.expectEqualStrings("$5\r\nhello\r\n", aw.written());
}

test "inline command parse" {
    const allocator = std.testing.allocator;
    const parts = try parseInlineCommand("PING hello\r\n", allocator);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("PING", parts[0]);
    try std.testing.expectEqualStrings("hello", parts[1]);
}

test "RESP3 parse null" {
    const allocator = std.testing.allocator;
    var parser = Parser.init("_\r\n");
    var val = try parser.parse(allocator);
    defer val.deinit(allocator);
    try std.testing.expect(val == .resp_null);
}

test "RESP3 parse boolean" {
    const allocator = std.testing.allocator;
    var p1 = Parser.init("#t\r\n");
    var v1 = try p1.parse(allocator);
    defer v1.deinit(allocator);
    try std.testing.expect(v1.boolean == true);

    var p2 = Parser.init("#f\r\n");
    var v2 = try p2.parse(allocator);
    defer v2.deinit(allocator);
    try std.testing.expect(v2.boolean == false);
}

test "RESP3 parse double" {
    const allocator = std.testing.allocator;
    var p1 = Parser.init(",3.14\r\n");
    var v1 = try p1.parse(allocator);
    defer v1.deinit(allocator);
    try std.testing.expectApproxEqRel(@as(f64, 3.14), v1.double, 0.001);
}

test "RESP3 parse map" {
    const allocator = std.testing.allocator;
    const input = "%2\r\n$3\r\nfoo\r\n:1\r\n$3\r\nbar\r\n:2\r\n";
    var parser = Parser.init(input);
    var val = try parser.parse(allocator);
    defer val.deinit(allocator);
    const items = val.map.?;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("foo", items[0].bulk_string.?);
    try std.testing.expectEqual(@as(i64, 1), items[1].integer);
}

test "RESP3 serialize null" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();

    try serializeNull(&aw.writer);
    try std.testing.expectEqualStrings("_\r\n", aw.written());
}

test "RESP3 serialize map header" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();

    try serializeMapHeader(&aw.writer, 3);
    try std.testing.expectEqualStrings("%3\r\n", aw.written());
}

test "version-aware null" {
    const allocator = std.testing.allocator;
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
        defer aw.deinit();
        try serializeNullValue(&aw.writer, .resp2);
        try std.testing.expectEqualStrings("$-1\r\n", aw.written());
    }
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
        defer aw.deinit();
        try serializeNullValue(&aw.writer, .resp3);
        try std.testing.expectEqualStrings("_\r\n", aw.written());
    }
}

test "inline command: double-quoted values are unquoted (sdssplitargs)" {
    const allocator = std.testing.allocator;
    const parts = try parseInlineCommand("SET k1 \"hello world\"\r\n", allocator);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("hello world", parts[2]);
}

test "inline command: escapes in double quotes" {
    const allocator = std.testing.allocator;
    const parts = try parseInlineCommand("SET k \"a\\x41b\\nc\\\"d\"\r\n", allocator);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    try std.testing.expectEqualStrings("aAb\nc\"d", parts[2]);
}

test "inline command: single quotes are literal except escaped quote" {
    const allocator = std.testing.allocator;
    const parts = try parseInlineCommand("SET k 'a\\x41 \\'b'\r\n", allocator);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    try std.testing.expectEqualStrings("a\\x41 'b", parts[2]);
}

test "inline command: unbalanced quotes error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnbalancedQuotes, parseInlineCommand("SET k \"oops\r\n", allocator));
    try std.testing.expectError(error.UnbalancedQuotes, parseInlineCommand("SET k \"a\"b\r\n", allocator));
}

test "inline command: unquoted tokens unchanged" {
    const allocator = std.testing.allocator;
    const parts = try parseInlineCommand("SET k1 plain-value\r\n", allocator);
    defer {
        for (parts) |p| allocator.free(p);
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("plain-value", parts[2]);
}
