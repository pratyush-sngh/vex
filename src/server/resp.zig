const std = @import("std");
const Allocator = std.mem.Allocator;

/// RESP (Redis Serialization Protocol) v2 implementation.
/// Supports parsing client commands and serializing server responses.
/// Wire format: https://redis.io/docs/reference/protocol-spec/
///
/// Types:
///   + Simple String    "+OK\r\n"
///   - Error            "-ERR message\r\n"
///   : Integer          ":42\r\n"
///   $ Bulk String      "$5\r\nhello\r\n"    (or "$-1\r\n" for null)
///   * Array            "*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"

pub const Value = union(enum) {
    simple_string: []const u8,
    err: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: ?[]Value,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .simple_string => |s| allocator.free(s),
            .err => |s| allocator.free(s),
            .bulk_string => |maybe_s| {
                if (maybe_s) |s| allocator.free(s);
            },
            .array => |maybe_arr| {
                if (maybe_arr) |arr| {
                    for (arr) |*item| {
                        var m = item.*;
                        m.deinit(allocator);
                    }
                    allocator.free(arr);
                }
            },
            .integer => {},
        }
    }
};

pub const ParseError = error{
    InvalidProtocol,
    UnexpectedEof,
    InvalidLength,
    InvalidInteger,
    OutOfMemory,
};

/// Stateful RESP parser that reads from a fixed buffer.
pub const Parser = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Parser {
        return .{ .data = data, .pos = 0 };
    }

    pub fn parse(self: *Parser, allocator: Allocator) ParseError!Value {
        if (self.pos >= self.data.len) return ParseError.UnexpectedEof;

        const type_byte = self.data[self.pos];
        self.pos += 1;

        return switch (type_byte) {
            '+' => self.parseSimpleString(allocator),
            '-' => self.parseError(allocator),
            ':' => self.parseInteger(),
            '$' => self.parseBulkString(allocator),
            '*' => self.parseArray(allocator),
            else => ParseError.InvalidProtocol,
        };
    }

    fn parseSimpleString(self: *Parser, allocator: Allocator) ParseError!Value {
        const line = try self.readLine();
        const copy = allocator.dupe(u8, line) catch return ParseError.OutOfMemory;
        return Value{ .simple_string = copy };
    }

    fn parseError(self: *Parser, allocator: Allocator) ParseError!Value {
        const line = try self.readLine();
        const copy = allocator.dupe(u8, line) catch return ParseError.OutOfMemory;
        return Value{ .err = copy };
    }

    fn parseInteger(self: *Parser) ParseError!Value {
        const line = try self.readLine();
        const num = std.fmt.parseInt(i64, line, 10) catch return ParseError.InvalidInteger;
        return Value{ .integer = num };
    }

    fn parseBulkString(self: *Parser, allocator: Allocator) ParseError!Value {
        const len_line = try self.readLine();
        const len = std.fmt.parseInt(i64, len_line, 10) catch return ParseError.InvalidLength;

        if (len < 0) return Value{ .bulk_string = null };

        const ulen: usize = @intCast(len);
        if (self.pos + ulen + 2 > self.data.len) return ParseError.UnexpectedEof;

        const content = self.data[self.pos .. self.pos + ulen];
        self.pos += ulen + 2; // skip \r\n

        const copy = allocator.dupe(u8, content) catch return ParseError.OutOfMemory;
        return Value{ .bulk_string = copy };
    }

    fn parseArray(self: *Parser, allocator: Allocator) ParseError!Value {
        const len_line = try self.readLine();
        const len = std.fmt.parseInt(i64, len_line, 10) catch return ParseError.InvalidLength;

        if (len < 0) return Value{ .array = null };

        const ulen: usize = @intCast(len);
        const items = allocator.alloc(Value, ulen) catch return ParseError.OutOfMemory;
        errdefer allocator.free(items);

        for (0..ulen) |i| {
            items[i] = try self.parse(allocator);
        }
        return Value{ .array = items };
    }

    fn readLine(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.pos + 1 < self.data.len) {
            if (self.data[self.pos] == '\r' and self.data[self.pos + 1] == '\n') {
                const line = self.data[start..self.pos];
                self.pos += 2;
                return line;
            }
            self.pos += 1;
        }
        return ParseError.UnexpectedEof;
    }

    pub fn isComplete(self: *Parser) bool {
        return self.pos >= self.data.len;
    }
};

// ─── Serializer ───────────────────────────────────────────────────────

pub fn serializeSimpleString(w: *std.Io.Writer, msg: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("+");
    try w.writeAll(msg);
    try w.writeAll("\r\n");
}

pub fn serializeError(w: *std.Io.Writer, msg: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("-ERR ");
    try w.writeAll(msg);
    try w.writeAll("\r\n");
}

pub fn serializeErrorTyped(w: *std.Io.Writer, err_type: []const u8, msg: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("-");
    try w.writeAll(err_type);
    try w.writeAll(" ");
    try w.writeAll(msg);
    try w.writeAll("\r\n");
}

pub fn serializeInteger(w: *std.Io.Writer, val: i64) std.Io.Writer.Error!void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, ":{d}\r\n", .{val}) catch unreachable;
    try w.writeAll(s);
}

pub fn serializeBulkString(w: *std.Io.Writer, data: ?[]const u8) std.Io.Writer.Error!void {
    if (data) |d| {
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "${d}\r\n", .{d.len}) catch unreachable;
        try w.writeAll(h);
        try w.writeAll(d);
        try w.writeAll("\r\n");
    } else {
        try w.writeAll("$-1\r\n");
    }
}

pub fn serializeArrayHeader(w: *std.Io.Writer, len: ?usize) std.Io.Writer.Error!void {
    if (len) |l| {
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "*{d}\r\n", .{l}) catch unreachable;
        try w.writeAll(h);
    } else {
        try w.writeAll("*-1\r\n");
    }
}

pub fn serializeValue(w: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    switch (value) {
        .simple_string => |s| try serializeSimpleString(w, s),
        .err => |s| try serializeError(w, s),
        .integer => |n| try serializeInteger(w, n),
        .bulk_string => |s| try serializeBulkString(w, s),
        .array => |maybe_arr| {
            if (maybe_arr) |arr| {
                try serializeArrayHeader(w, arr.len);
                for (arr) |item| {
                    try serializeValue(w, item);
                }
            } else {
                try serializeArrayHeader(w, null);
            }
        },
    }
}

// ─── Inline Commands ──────────────────────────────────────────────────
// redis-cli sometimes sends inline commands (no RESP framing, just "PING\r\n")

pub fn isInlineCommand(data: []const u8) bool {
    if (data.len == 0) return false;
    return data[0] != '*' and data[0] != '+' and data[0] != '-' and data[0] != ':' and data[0] != '$';
}

pub fn parseInlineCommand(data: []const u8, allocator: Allocator) ![][]const u8 {
    var end = data.len;
    for (data, 0..) |c, i| {
        if (c == '\r' or c == '\n') {
            end = i;
            break;
        }
    }
    const line = data[0..end];

    var parts = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit();
    }

    var iter = std.mem.tokenizeScalar(u8, line, ' ');
    while (iter.next()) |token| {
        const copy = try allocator.dupe(u8, token);
        try parts.append(copy);
    }
    return parts.toOwnedSlice();
}

// ─── Tests ────────────────────────────────────────────────────────────

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
