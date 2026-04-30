const std = @import("std");
const Allocator = std.mem.Allocator;

/// RESP (Redis Serialization Protocol) v2/v3 implementation.
/// Supports parsing client commands and serializing server responses.
/// Wire format: https://redis.io/docs/reference/protocol-spec/
///
/// RESP2 types:
///   + Simple String    "+OK\r\n"
///   - Error            "-ERR message\r\n"
///   : Integer          ":42\r\n"
///   $ Bulk String      "$5\r\nhello\r\n"    (or "$-1\r\n" for null)
///   * Array            "*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"
///
/// RESP3 additions:
///   _ Null             "_\r\n"
///   # Boolean          "#t\r\n" / "#f\r\n"
///   , Double           ",3.14\r\n"
///   % Map              "%2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n..."
///   ~ Set              "~2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"
///   > Push             ">3\r\n$7\r\nmessage\r\n..."
///   ! Blob Error       "!11\r\nERR unknown\r\n"
///   = Verbatim String  "=15\r\ntxt:hello world\r\n"

pub const ProtocolVersion = enum(u8) {
    resp2 = 2,
    resp3 = 3,
};

pub const Value = union(enum) {
    simple_string: []const u8,
    err: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: ?[]Value,
    // RESP3 types
    resp_null: void,
    boolean: bool,
    double: f64,
    map: ?[]Value, // alternating key-value pairs
    set_type: ?[]Value,
    push: ?[]Value,
    blob_error: []const u8,
    verbatim_string: []const u8,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .simple_string => |s| allocator.free(s),
            .err => |s| allocator.free(s),
            .blob_error => |s| allocator.free(s),
            .verbatim_string => |s| allocator.free(s),
            .bulk_string => |maybe_s| {
                if (maybe_s) |s| allocator.free(s);
            },
            .array, .map, .set_type, .push => |maybe_arr| {
                if (maybe_arr) |arr| {
                    for (arr) |*item| {
                        var m = item.*;
                        m.deinit(allocator);
                    }
                    allocator.free(arr);
                }
            },
            .integer, .resp_null, .boolean, .double => {},
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
/// Handles both RESP2 and RESP3 type bytes.
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
            // RESP2
            '+' => self.parseSimpleString(allocator),
            '-' => self.parseError(allocator),
            ':' => self.parseInteger(),
            '$' => self.parseBulkString(allocator),
            '*' => self.parseArray(allocator),
            // RESP3
            '_' => self.parseNull(),
            '#' => self.parseBoolean(),
            ',' => self.parseDouble(),
            '%' => self.parseMap(allocator),
            '~' => self.parseSet(allocator),
            '>' => self.parsePush(allocator),
            '!' => self.parseBlobError(allocator),
            '=' => self.parseVerbatimString(allocator),
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

    // ── RESP3 parsers ──────────────────────────────────────────────────

    fn parseNull(self: *Parser) ParseError!Value {
        // "_\r\n" — type byte already consumed, just skip \r\n
        if (self.pos + 2 > self.data.len) return ParseError.UnexpectedEof;
        if (self.data[self.pos] != '\r' or self.data[self.pos + 1] != '\n')
            return ParseError.InvalidProtocol;
        self.pos += 2;
        return Value{ .resp_null = {} };
    }

    fn parseBoolean(self: *Parser) ParseError!Value {
        const line = try self.readLine();
        if (line.len != 1) return ParseError.InvalidProtocol;
        return switch (line[0]) {
            't' => Value{ .boolean = true },
            'f' => Value{ .boolean = false },
            else => ParseError.InvalidProtocol,
        };
    }

    fn parseDouble(self: *Parser) ParseError!Value {
        const line = try self.readLine();
        if (std.mem.eql(u8, line, "inf")) return Value{ .double = std.math.inf(f64) };
        if (std.mem.eql(u8, line, "-inf")) return Value{ .double = -std.math.inf(f64) };
        const val = std.fmt.parseFloat(f64, line) catch return ParseError.InvalidInteger;
        return Value{ .double = val };
    }

    fn parseMap(self: *Parser, allocator: Allocator) ParseError!Value {
        const len_line = try self.readLine();
        const len = std.fmt.parseInt(i64, len_line, 10) catch return ParseError.InvalidLength;
        if (len < 0) return Value{ .map = null };
        const pair_count: usize = @intCast(len);
        const items = allocator.alloc(Value, pair_count * 2) catch return ParseError.OutOfMemory;
        errdefer allocator.free(items);
        for (0..pair_count * 2) |i| {
            items[i] = try self.parse(allocator);
        }
        return Value{ .map = items };
    }

    fn parseSet(self: *Parser, allocator: Allocator) ParseError!Value {
        const len_line = try self.readLine();
        const len = std.fmt.parseInt(i64, len_line, 10) catch return ParseError.InvalidLength;
        if (len < 0) return Value{ .set_type = null };
        const ulen: usize = @intCast(len);
        const items = allocator.alloc(Value, ulen) catch return ParseError.OutOfMemory;
        errdefer allocator.free(items);
        for (0..ulen) |i| {
            items[i] = try self.parse(allocator);
        }
        return Value{ .set_type = items };
    }

    fn parsePush(self: *Parser, allocator: Allocator) ParseError!Value {
        const len_line = try self.readLine();
        const len = std.fmt.parseInt(i64, len_line, 10) catch return ParseError.InvalidLength;
        if (len < 0) return Value{ .push = null };
        const ulen: usize = @intCast(len);
        const items = allocator.alloc(Value, ulen) catch return ParseError.OutOfMemory;
        errdefer allocator.free(items);
        for (0..ulen) |i| {
            items[i] = try self.parse(allocator);
        }
        return Value{ .push = items };
    }

    fn parseBlobError(self: *Parser, allocator: Allocator) ParseError!Value {
        const len_line = try self.readLine();
        const len = std.fmt.parseInt(i64, len_line, 10) catch return ParseError.InvalidLength;
        if (len < 0) return ParseError.InvalidLength;
        const ulen: usize = @intCast(len);
        if (self.pos + ulen + 2 > self.data.len) return ParseError.UnexpectedEof;
        const content = self.data[self.pos .. self.pos + ulen];
        self.pos += ulen + 2;
        const copy = allocator.dupe(u8, content) catch return ParseError.OutOfMemory;
        return Value{ .blob_error = copy };
    }

    fn parseVerbatimString(self: *Parser, allocator: Allocator) ParseError!Value {
        const len_line = try self.readLine();
        const len = std.fmt.parseInt(i64, len_line, 10) catch return ParseError.InvalidLength;
        if (len < 0) return ParseError.InvalidLength;
        const ulen: usize = @intCast(len);
        if (self.pos + ulen + 2 > self.data.len) return ParseError.UnexpectedEof;
        const content = self.data[self.pos .. self.pos + ulen];
        self.pos += ulen + 2;
        const copy = allocator.dupe(u8, content) catch return ParseError.OutOfMemory;
        return Value{ .verbatim_string = copy };
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

// ─── RESP2 Serializer ────────────────────────────────────────────────

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
        .resp_null => try serializeNull(w),
        .boolean => |b| try serializeBoolean(w, b),
        .double => |d| try serializeDouble(w, d),
        .map => |maybe_arr| {
            if (maybe_arr) |arr| {
                try serializeMapHeader(w, arr.len / 2);
                for (arr) |item| try serializeValue(w, item);
            } else {
                try serializeNull(w);
            }
        },
        .set_type => |maybe_arr| {
            if (maybe_arr) |arr| {
                try serializeSetHeader(w, arr.len);
                for (arr) |item| try serializeValue(w, item);
            } else {
                try serializeNull(w);
            }
        },
        .push => |maybe_arr| {
            if (maybe_arr) |arr| {
                try serializePushHeader(w, arr.len);
                for (arr) |item| try serializeValue(w, item);
            } else {
                try serializeNull(w);
            }
        },
        .blob_error => |s| try serializeBlobError(w, s),
        .verbatim_string => |s| try serializeVerbatimString(w, s),
    }
}

// ─── RESP3 Serializers ───────────────────────────────────────────────

pub fn serializeNull(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("_\r\n");
}

pub fn serializeBoolean(w: *std.Io.Writer, val: bool) std.Io.Writer.Error!void {
    try w.writeAll(if (val) "#t\r\n" else "#f\r\n");
}

pub fn serializeDouble(w: *std.Io.Writer, val: f64) std.Io.Writer.Error!void {
    if (std.math.isInf(val)) {
        try w.writeAll(if (val > 0) ",inf\r\n" else ",-inf\r\n");
    } else {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, ",{d}\r\n", .{val}) catch unreachable;
        try w.writeAll(s);
    }
}

pub fn serializeMapHeader(w: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "%{d}\r\n", .{count}) catch unreachable;
    try w.writeAll(h);
}

pub fn serializeSetHeader(w: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "~{d}\r\n", .{count}) catch unreachable;
    try w.writeAll(h);
}

pub fn serializePushHeader(w: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, ">{d}\r\n", .{count}) catch unreachable;
    try w.writeAll(h);
}

pub fn serializeBlobError(w: *std.Io.Writer, msg: []const u8) std.Io.Writer.Error!void {
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "!{d}\r\n", .{msg.len}) catch unreachable;
    try w.writeAll(h);
    try w.writeAll(msg);
    try w.writeAll("\r\n");
}

pub fn serializeVerbatimString(w: *std.Io.Writer, encoding: []const u8, data: []const u8) std.Io.Writer.Error!void {
    const total = encoding.len + 1 + data.len;
    var hdr: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "={d}\r\n", .{total}) catch unreachable;
    try w.writeAll(h);
    try w.writeAll(encoding);
    try w.writeAll(":");
    try w.writeAll(data);
    try w.writeAll("\r\n");
}

// ─── Version-aware helpers ───────────────────────────────────────────

/// Serialize null in the correct format for the connection's protocol version.
pub fn serializeNullValue(w: *std.Io.Writer, proto: ProtocolVersion) std.Io.Writer.Error!void {
    switch (proto) {
        .resp2 => try w.writeAll("$-1\r\n"),
        .resp3 => try w.writeAll("_\r\n"),
    }
}

/// Serialize a bulk string that may be null, using the correct null format.
pub fn serializeBulkStringProto(w: *std.Io.Writer, data: ?[]const u8, proto: ProtocolVersion) std.Io.Writer.Error!void {
    if (data) |d| {
        try serializeBulkString(w, d);
    } else {
        try serializeNullValue(w, proto);
    }
}

/// Serialize a collection header as array (RESP2) or map (RESP3).
/// pair_count is the number of key-value pairs.
pub fn serializeMapOrArrayHeader(w: *std.Io.Writer, pair_count: usize, proto: ProtocolVersion) std.Io.Writer.Error!void {
    switch (proto) {
        .resp2 => try serializeArrayHeader(w, pair_count * 2),
        .resp3 => try serializeMapHeader(w, pair_count),
    }
}

/// Serialize a collection header as array (RESP2) or set (RESP3).
pub fn serializeSetOrArrayHeader(w: *std.Io.Writer, count: usize, proto: ProtocolVersion) std.Io.Writer.Error!void {
    switch (proto) {
        .resp2 => try serializeArrayHeader(w, count),
        .resp3 => try serializeSetHeader(w, count),
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
