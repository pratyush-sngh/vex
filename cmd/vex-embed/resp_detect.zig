//! Head-of-stream RESP command detection for the proxy.
//!
//! The proxy is byte-transparent except for `EMBED <text>`, so it only
//! needs to answer one question about the bytes at the head of the client
//! stream: "is a complete command sitting here, and is it EMBED?" It does
//! NOT need a full RESP parser — for non-EMBED commands it just needs the
//! byte length of the leading array so it can forward exactly those bytes.
//!
//! Recognized client command form (the only form redis-cli / clients send):
//!   *<argc>\r\n $<len>\r\n <arg> \r\n ...        (RESP array of bulk strings)
//!
//! EMBED is `*2\r\n$5\r\nEMBED\r\n$<n>\r\n<text>\r\n`. The command name is
//! matched case-insensitively (clients may send `embed`).

const std = @import("std");

pub const Embed = struct {
    /// Bytes the caller should consume (the whole `*2…` command).
    consumed: usize,
    /// `[text_start, text_end)` into the SAME buffer = the raw text arg.
    text_start: usize,
    text_end: usize,
};

pub const Detection = union(enum) {
    /// A complete EMBED command sits at the head.
    embed: Embed,
    /// A complete non-EMBED RESP array command sits at the head; forward
    /// this many bytes verbatim.
    not_embed: usize,
    /// Not enough bytes yet to decide.
    incomplete,
};

/// Inspect the head of `buf`. Only RESP arrays (`*`) are classified; any
/// other leading byte (inline command, mid-stream junk) is reported as a
/// `not_embed` of one byte so the proxy forwards it and moves on — we never
/// need to understand non-array traffic, only to pass it through.
pub fn detectEmbed(buf: []const u8) Detection {
    if (buf.len == 0) return .incomplete;
    if (buf[0] != '*') {
        // Not an array header. Forward whatever contiguous non-'*' run we
        // have; the proxy doesn't intercept inline commands.
        return .{ .not_embed = buf.len };
    }

    var p: usize = 0;
    const argc = switch (readLenLine(buf, &p, '*')) {
        .ok => |n| n,
        .incomplete => return .incomplete,
        .malformed => return .{ .not_embed = buf.len },
    };
    if (argc <= 0) {
        // `*0\r\n` / `*-1\r\n` — a complete, empty command. Forward it.
        return .{ .not_embed = p };
    }

    var args_text_start: usize = 0;
    var args_text_end: usize = 0;
    var first_is_embed = false;

    var i: i64 = 0;
    while (i < argc) : (i += 1) {
        if (p >= buf.len) return .incomplete;
        if (buf[p] != '$') {
            // Malformed for our purposes; forward what we have so we don't
            // wedge the stream trying to be clever.
            return .{ .not_embed = buf.len };
        }
        const len = switch (readLenLine(buf, &p, '$')) {
            .ok => |n| n,
            .incomplete => return .incomplete,
            .malformed => return .{ .not_embed = buf.len },
        };
        if (len < 0) return .{ .not_embed = buf.len }; // null bulk: forward
        const ulen: usize = @intCast(len);
        if (p + ulen + 2 > buf.len) return .incomplete; // arg bytes + trailing CRLF
        const arg = buf[p .. p + ulen];

        if (i == 0) {
            first_is_embed = eqlIgnoreCase(arg, "EMBED");
        } else if (i == 1) {
            args_text_start = p;
            args_text_end = p + ulen;
        }
        p += ulen + 2; // skip arg + CRLF
    }

    // p now points just past the whole command.
    if (first_is_embed and argc == 2) {
        return .{ .embed = .{ .consumed = p, .text_start = args_text_start, .text_end = args_text_end } };
    }
    return .{ .not_embed = p };
}

/// Could the (incomplete) head still become an EMBED command once more bytes
/// arrive? Used by the proxy to decide whether to hold partial bytes back or
/// forward them immediately. Conservative: only holds when the prefix is
/// consistent with `*2\r\n$5\r\nEMBED…`.
pub fn mightBeEmbed(buf: []const u8) bool {
    if (buf.len == 0) return true; // empty: could be anything, wait
    if (buf[0] != '*') return false;
    // Compare against the canonical EMBED prefix up to the command name,
    // case-insensitively, for as many bytes as we have.
    const prefix = "*2\r\n$5\r\nEMBED";
    const n = @min(buf.len, prefix.len);
    return eqlIgnoreCase(buf[0..n], prefix[0..n]);
}

// ── General command parse (for auto-rewrite) ────────────────────────
// detectEmbed only needs arg0/arg1; the rewrite path needs every arg's
// boundaries so it can substitute a `TEXT "<s>"` pair with embedded bytes.

pub const MAX_ARGS = 64;

pub const Arg = struct { start: usize, end: usize };

pub const Command = struct {
    /// Total bytes of the whole `*…` command.
    consumed: usize,
    argc: usize,
    args: [MAX_ARGS]Arg = undefined, // valid [0..argc); each = bulk-string body

    pub fn arg(self: *const Command, buf: []const u8, i: usize) []const u8 {
        return buf[self.args[i].start..self.args[i].end];
    }
};

/// Parse a complete leading RESP array of bulk strings. Returns null if the
/// command is incomplete, malformed, not an array, or has > MAX_ARGS args
/// (caller forwards those verbatim — never our concern to rewrite).
pub fn parseCommand(buf: []const u8) ?Command {
    if (buf.len == 0 or buf[0] != '*') return null;
    var p: usize = 0;
    const argc = switch (readLenLine(buf, &p, '*')) {
        .ok => |n| n,
        else => return null,
    };
    if (argc <= 0 or argc > MAX_ARGS) return null;
    var cmd = Command{ .consumed = 0, .argc = @intCast(argc) };
    var i: usize = 0;
    while (i < cmd.argc) : (i += 1) {
        if (p >= buf.len or buf[p] != '$') return null;
        const len = switch (readLenLine(buf, &p, '$')) {
            .ok => |n| n,
            else => return null,
        };
        if (len < 0) return null;
        const ulen: usize = @intCast(len);
        if (p + ulen + 2 > buf.len) return null; // body + CRLF not all here
        cmd.args[i] = .{ .start = p, .end = p + ulen };
        p += ulen + 2;
    }
    cmd.consumed = p;
    return cmd;
}

const LenLine = union(enum) {
    ok: i64,
    /// Header line not fully present yet — wait for more bytes.
    incomplete,
    /// Wrong type byte / non-numeric length — give up and forward.
    malformed,
};

/// Read a `<type><number>\r\n` header line starting at `*p`. On success
/// advances `*p` past the CRLF and returns the number.
fn readLenLine(buf: []const u8, p: *usize, type_byte: u8) LenLine {
    if (p.* >= buf.len) return .incomplete;
    if (buf[p.*] != type_byte) return .malformed;
    const i = p.* + 1;
    const crlf = std.mem.indexOfScalarPos(u8, buf, i, '\r') orelse return .incomplete;
    if (crlf + 1 >= buf.len) return .incomplete; // need the '\n'
    if (buf[crlf + 1] != '\n') return .malformed;
    const num = std.fmt.parseInt(i64, buf[i..crlf], 10) catch return .malformed;
    p.* = crlf + 2;
    return .{ .ok = num };
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

test "detects a complete EMBED command" {
    const cmd = "*2\r\n$5\r\nEMBED\r\n$5\r\nhello\r\n";
    const det = detectEmbed(cmd);
    try std.testing.expect(det == .embed);
    const e = det.embed;
    try std.testing.expectEqual(cmd.len, e.consumed);
    try std.testing.expectEqualStrings("hello", cmd[e.text_start..e.text_end]);
}

test "EMBED command name is case-insensitive" {
    const cmd = "*2\r\n$5\r\nembed\r\n$2\r\nhi\r\n";
    const det = detectEmbed(cmd);
    try std.testing.expect(det == .embed);
    try std.testing.expectEqualStrings("hi", cmd[det.embed.text_start..det.embed.text_end]);
}

test "EMBED text may contain spaces and binary-ish bytes" {
    const text = "the quick brown fox";
    const cmd = "*2\r\n$5\r\nEMBED\r\n$19\r\n" ++ text ++ "\r\n";
    const det = detectEmbed(cmd);
    try std.testing.expect(det == .embed);
    try std.testing.expectEqualStrings(text, cmd[det.embed.text_start..det.embed.text_end]);
}

test "non-EMBED array command is forwarded whole" {
    const cmd = "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n";
    const det = detectEmbed(cmd);
    try std.testing.expect(det == .not_embed);
    try std.testing.expectEqual(cmd.len, det.not_embed);
}

test "GET is not mistaken for EMBED" {
    const cmd = "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n";
    const det = detectEmbed(cmd);
    try std.testing.expect(det == .not_embed);
    try std.testing.expectEqual(cmd.len, det.not_embed);
}

test "partial EMBED command is incomplete" {
    const full = "*2\r\n$5\r\nEMBED\r\n$5\r\nhello\r\n";
    // Every strict prefix should be incomplete (header present, body short).
    var len: usize = 1;
    while (len < full.len) : (len += 1) {
        const det = detectEmbed(full[0..len]);
        // Once we have the whole thing it's .embed; before that, while the
        // prefix is EMBED-consistent, it must be .incomplete (never a wrong
        // .not_embed that would leak EMBED bytes to vex).
        if (det == .embed) {
            try std.testing.expectEqual(full.len, len);
        } else {
            try std.testing.expect(det == .incomplete);
        }
    }
}

test "mightBeEmbed holds EMBED prefixes, releases others" {
    try std.testing.expect(mightBeEmbed("*2\r\n$5\r\nEM"));
    try std.testing.expect(mightBeEmbed("*2\r\n$5\r\nembe"));
    try std.testing.expect(!mightBeEmbed("*2\r\n$3\r\nGET"));
    try std.testing.expect(!mightBeEmbed("+OK\r\n"));
}

test "parseCommand: args + boundaries for a multi-arg command" {
    const cmd = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const c = parseCommand(cmd).?;
    try std.testing.expectEqual(@as(usize, 3), c.argc);
    try std.testing.expectEqual(cmd.len, c.consumed);
    try std.testing.expectEqualStrings("SET", c.arg(cmd, 0));
    try std.testing.expectEqualStrings("key", c.arg(cmd, 1));
    try std.testing.expectEqualStrings("value", c.arg(cmd, 2));
}

test "parseCommand: locates a TEXT marker + its value" {
    // GRAPH.VECSEARCH field TEXT "hi there" K 5
    const cmd = "*6\r\n$15\r\nGRAPH.VECSEARCH\r\n$5\r\nfield\r\n$4\r\nTEXT\r\n$8\r\nhi there\r\n$1\r\nK\r\n$1\r\n5\r\n";
    const c = parseCommand(cmd).?;
    try std.testing.expectEqual(@as(usize, 6), c.argc);
    try std.testing.expectEqualStrings("TEXT", c.arg(cmd, 2));
    try std.testing.expectEqualStrings("hi there", c.arg(cmd, 3));
    try std.testing.expectEqualStrings("5", c.arg(cmd, 5));
}

test "parseCommand: incomplete + malformed return null" {
    const full = "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n";
    try std.testing.expect(parseCommand(full[0 .. full.len - 3]) == null); // body short
    try std.testing.expect(parseCommand("+OK\r\n") == null); // not an array
    try std.testing.expect(parseCommand("") == null);
}

test "two commands: only the head is consumed at a time" {
    const cmd = "*2\r\n$5\r\nEMBED\r\n$2\r\nhi\r\n*1\r\n$4\r\nPING\r\n";
    const det = detectEmbed(cmd);
    try std.testing.expect(det == .embed);
    // consumed stops at the end of the EMBED command, not the PING after it.
    const embed_len = "*2\r\n$5\r\nEMBED\r\n$2\r\nhi\r\n".len;
    try std.testing.expectEqual(embed_len, det.embed.consumed);

    const rest = cmd[det.embed.consumed..];
    const det2 = detectEmbed(rest);
    try std.testing.expect(det2 == .not_embed);
    try std.testing.expectEqual(rest.len, det2.not_embed);
}
