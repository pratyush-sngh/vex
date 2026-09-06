//! Embedding HTTP client for vex-embed.
//!
//! Turns text into an `[]f32` by POSTing JSON to an external embedding
//! endpoint and parsing the float array out of the reply. Two wire shapes
//! are supported, selected by `Config.provider`:
//!
//!   Ollama   POST {"model":<m>,"prompt":<t>} -> {"embedding":[...]}
//!   OpenAI   POST {"model":<m>,"input":<t>}  -> {"data":[{"embedding":[...]}]}
//!            with `Authorization: Bearer <key>`.
//!
//! ## Why a hand-rolled HTTP/1.1 client (not std.http.Client)
//! This repo runs on a custom Zig 0.17 dev build whose networking goes
//! through the new `std.Io` async model; every other outbound connection in
//! the tree (src/cluster/replication.zig, sentinel/http.zig) is a plain
//! blocking libc socket via `std.c`. We follow that precedent: it keeps the
//! dependency surface identical to the rest of vex and sidesteps the
//! in-flux std.http.Client API. The request is one POST with a small JSON
//! body, so a fixed request-line + header writer and a Content-Length /
//! read-to-EOF body reader cover everything we need.
//!
//! NOTE: plain HTTP only. `https://` embed URLs would need TLS, which is out
//! of scope for the scaffold — point this at a local Ollama or an in-cluster
//! OpenAI-compatible gateway. A clear error is returned for `https://`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const Config = config_mod.Config;

pub const EmbedError = error{
    HttpsNotSupported,
    InvalidUrl,
    SocketFailed,
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    HttpError,
    BadResponse,
    EmptyEmbedding,
    OutOfMemory,
};

/// Compute the embedding for `text` against the endpoint described by `cfg`.
/// Caller owns the returned slice.
pub fn embed(allocator: Allocator, cfg: Config, text: []const u8) EmbedError![]f32 {
    const url = parseUrl(cfg.embed_url) catch |e| return e;

    const body = try buildRequestBody(allocator, cfg, text);
    defer allocator.free(body);

    const raw = try httpPost(allocator, cfg, url, body);
    defer allocator.free(raw);

    return parseEmbedding(allocator, cfg.provider, raw);
}

/// Serialize an `[]f32` to its little-endian raw byte buffer. This is the
/// exact format vex's GRAPH.SETVEC / VECSEARCH expect on the wire, so the
/// client can hand these bytes straight through. Caller owns the result.
pub fn floatsToBytes(allocator: Allocator, vec: []const f32) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, vec.len * 4);
    for (vec, 0..) |f, i| {
        const bits: u32 = @bitCast(f);
        std.mem.writeInt(u32, out[i * 4 ..][0..4], bits, .little);
    }
    return out;
}

// ── URL ─────────────────────────────────────────────────────────────

const Url = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Minimal `http://host[:port]/path` splitter. Rejects https (no TLS here).
fn parseUrl(raw: []const u8) EmbedError!Url {
    if (std.mem.startsWith(u8, raw, "https://")) return EmbedError.HttpsNotSupported;
    const rest = if (std.mem.startsWith(u8, raw, "http://"))
        raw["http://".len..]
    else
        return EmbedError.InvalidUrl;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    if (authority.len == 0) return EmbedError.InvalidUrl;

    if (std.mem.indexOfScalar(u8, authority, ':')) |c| {
        const host = authority[0..c];
        const port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return EmbedError.InvalidUrl;
        if (host.len == 0) return EmbedError.InvalidUrl;
        return .{ .host = host, .port = port, .path = path };
    }
    return .{ .host = authority, .port = 80, .path = path };
}

// ── Request body ────────────────────────────────────────────────────

fn buildRequestBody(allocator: Allocator, cfg: Config, text: []const u8) EmbedError![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    // Ollama keys the text as "prompt", OpenAI-compatible as "input".
    const text_field = switch (cfg.provider) {
        .ollama => ",\"prompt\":",
        .openai => ",\"input\":",
    };

    buf.appendSlice("{\"model\":") catch return EmbedError.OutOfMemory;
    appendJsonString(&buf, cfg.embed_model) catch return EmbedError.OutOfMemory;
    buf.appendSlice(text_field) catch return EmbedError.OutOfMemory;
    appendJsonString(&buf, text) catch return EmbedError.OutOfMemory;
    buf.append('}') catch return EmbedError.OutOfMemory;

    return buf.toOwnedSlice() catch EmbedError.OutOfMemory;
}

/// Append `s` to `buf` as a JSON string literal (quotes + minimal escaping).
fn appendJsonString(buf: *std.array_list.Managed(u8), s: []const u8) Allocator.Error!void {
    try buf.append('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var hex: [6]u8 = undefined;
                const out = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{ch}) catch unreachable;
                try buf.appendSlice(out);
            },
            else => try buf.append(ch),
        }
    }
    try buf.append('"');
}

// ── HTTP/1.1 over a blocking libc socket ────────────────────────────

fn httpPost(allocator: Allocator, cfg: Config, url: Url, body: []const u8) EmbedError![]u8 {
    const addr = resolveHost(allocator, url.host) orelse return EmbedError.ConnectFailed;

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return EmbedError.SocketFailed;
    defer _ = std.c.close(sock);

    // Bound connect+IO so a wedged embedder can't stall a proxy thread forever.
    var tv: std.c.timeval = .{ .sec = 30, .usec = 0 };
    _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(std.c.timeval));
    _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(std.c.timeval));

    var sa: std.c.sockaddr.in = .{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, url.port),
        .addr = addr,
    };
    if (std.c.connect(sock, @ptrCast(&sa), @sizeOf(std.c.sockaddr.in)) < 0) return EmbedError.ConnectFailed;

    // Request head. Built with allocPrint since it's a handful of short lines.
    const auth = if (cfg.provider == .openai and cfg.embed_key.len > 0)
        std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\r\n", .{cfg.embed_key}) catch
            return EmbedError.OutOfMemory
    else
        allocator.dupe(u8, "") catch return EmbedError.OutOfMemory;
    defer allocator.free(auth);

    const head = std.fmt.allocPrint(
        allocator,
        "POST {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "{s}" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ url.path, url.host, url.port, auth, body.len },
    ) catch return EmbedError.OutOfMemory;
    defer allocator.free(head);

    writeAll(sock, head) catch return EmbedError.WriteFailed;
    writeAll(sock, body) catch return EmbedError.WriteFailed;

    // Read whole response (Connection: close ⇒ read to EOF).
    var resp = std.array_list.Managed(u8).init(allocator);
    errdefer resp.deinit();
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(sock, &rbuf, rbuf.len);
        if (n < 0) return EmbedError.ReadFailed;
        if (n == 0) break;
        resp.appendSlice(rbuf[0..@intCast(n)]) catch return EmbedError.OutOfMemory;
        if (resp.items.len > 64 * 1024 * 1024) return EmbedError.BadResponse; // sanity cap
    }

    const raw = resp.toOwnedSlice() catch return EmbedError.OutOfMemory;
    errdefer allocator.free(raw);

    // Split head/body and check status. Status line: "HTTP/1.1 200 OK".
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return EmbedError.BadResponse;
    const status = parseStatus(raw[0..sep]) orelse return EmbedError.BadResponse;
    if (status < 200 or status >= 300) {
        allocator.free(raw);
        return EmbedError.HttpError;
    }

    // Hand back just the body. Chunked transfer-encoding is not decoded here
    // — Ollama and typical OpenAI gateways return Content-Length bodies under
    // Connection: close. (TODO: chunked decode if a gateway needs it.)
    const body_start = sep + 4;
    const out = allocator.dupe(u8, raw[body_start..]) catch return EmbedError.OutOfMemory;
    allocator.free(raw);
    return out;
}

fn parseStatus(head: []const u8) ?u16 {
    const line_end = std.mem.indexOfScalar(u8, head, '\r') orelse head.len;
    const line = head[0..line_end];
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next() orelse return null; // "HTTP/1.1"
    const code = it.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn writeAll(sock: std.c.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(sock, data.ptr + off, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

// ── Response parse ──────────────────────────────────────────────────

/// Pull the float array out of an embedding response body for `provider`.
pub fn parseEmbedding(allocator: Allocator, provider: config_mod.Provider, body: []const u8) EmbedError![]f32 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return EmbedError.BadResponse;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return EmbedError.BadResponse;

    const arr: std.json.Array = switch (provider) {
        .ollama => blk: {
            const e = root.object.get("embedding") orelse return EmbedError.BadResponse;
            if (e != .array) return EmbedError.BadResponse;
            break :blk e.array;
        },
        .openai => blk: {
            const data = root.object.get("data") orelse return EmbedError.BadResponse;
            if (data != .array or data.array.items.len == 0) return EmbedError.BadResponse;
            const first = data.array.items[0];
            if (first != .object) return EmbedError.BadResponse;
            const e = first.object.get("embedding") orelse return EmbedError.BadResponse;
            if (e != .array) return EmbedError.BadResponse;
            break :blk e.array;
        },
    };

    if (arr.items.len == 0) return EmbedError.EmptyEmbedding;

    const out = try allocator.alloc(f32, arr.items.len);
    errdefer allocator.free(out);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            .number_string => |s| std.fmt.parseFloat(f32, s) catch return EmbedError.BadResponse,
            else => return EmbedError.BadResponse,
        };
    }
    return out;
}

// ── Host resolution (mirrors src/cluster/replication.zig) ───────────

fn resolveHost(allocator: Allocator, host: []const u8) ?u32 {
    if (parseIpv4(host)) |ip| return ip;

    const host_z = allocator.dupeSentinel(u8, host, 0) catch return null;
    defer allocator.free(host_z);

    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.INET;

    var result: ?*std.c.addrinfo = null;
    const gai = std.c.getaddrinfo(host_z, null, &hints, &result);
    if (@intFromEnum(gai) != 0) return null;
    defer if (result) |r| std.c.freeaddrinfo(r);

    if (result) |res| {
        const addr: *std.c.sockaddr.in = @ptrCast(@alignCast(res.addr));
        return addr.addr;
    }
    return null;
}

fn parseIpv4(s: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var idx: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (idx >= 3) return null;
            octets[idx] = std.fmt.parseInt(u8, s[start..i], 10) catch return null;
            idx += 1;
            start = i + 1;
        }
    }
    if (idx != 3) return null;
    octets[3] = std.fmt.parseInt(u8, s[start..], 10) catch return null;
    return @as(u32, octets[0]) | (@as(u32, octets[1]) << 8) |
        (@as(u32, octets[2]) << 16) | (@as(u32, octets[3]) << 24);
}

// ── Tests ───────────────────────────────────────────────────────────

test "floatsToBytes round-trips f32 little-endian" {
    const in = [_]f32{ 0.0, 1.0, -1.5, 3.14159, 1234.5 };
    const bytes = try floatsToBytes(std.testing.allocator, &in);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqual(in.len * 4, bytes.len);

    // Decode back and compare bit-for-bit.
    for (in, 0..) |expected, i| {
        const bits = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        const got: f32 = @bitCast(bits);
        try std.testing.expectEqual(expected, got);
    }
}

test "parseEmbedding ollama shape" {
    const body = "{\"embedding\":[0.5,-0.25,2]}";
    const vec = try parseEmbedding(std.testing.allocator, .ollama, body);
    defer std.testing.allocator.free(vec);
    try std.testing.expectEqual(@as(usize, 3), vec.len);
    try std.testing.expectEqual(@as(f32, 0.5), vec[0]);
    try std.testing.expectEqual(@as(f32, -0.25), vec[1]);
    try std.testing.expectEqual(@as(f32, 2.0), vec[2]);
}

test "parseEmbedding openai shape" {
    const body = "{\"data\":[{\"embedding\":[1.0,0.0]}],\"model\":\"x\"}";
    const vec = try parseEmbedding(std.testing.allocator, .openai, body);
    defer std.testing.allocator.free(vec);
    try std.testing.expectEqual(@as(usize, 2), vec.len);
    try std.testing.expectEqual(@as(f32, 1.0), vec[0]);
}

test "parseUrl splits host port path" {
    const u = try parseUrl("http://localhost:11434/api/embeddings");
    try std.testing.expectEqualStrings("localhost", u.host);
    try std.testing.expectEqual(@as(u16, 11434), u.port);
    try std.testing.expectEqualStrings("/api/embeddings", u.path);

    const d = try parseUrl("http://example.com/x");
    try std.testing.expectEqual(@as(u16, 80), d.port);

    try std.testing.expectError(EmbedError.HttpsNotSupported, parseUrl("https://x/y"));
    try std.testing.expectError(EmbedError.InvalidUrl, parseUrl("ftp://x"));
}

test "buildRequestBody escapes and selects field" {
    const cfg = Config{ .provider = .ollama, .embed_model = "m" };
    const b = try buildRequestBody(std.testing.allocator, cfg, "he\"llo\n");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("{\"model\":\"m\",\"prompt\":\"he\\\"llo\\n\"}", b);

    const cfg2 = Config{ .provider = .openai, .embed_model = "m" };
    const b2 = try buildRequestBody(std.testing.allocator, cfg2, "hi");
    defer std.testing.allocator.free(b2);
    try std.testing.expectEqualStrings("{\"model\":\"m\",\"input\":\"hi\"}", b2);
}
