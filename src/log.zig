const std = @import("std");
const c = std.c;

pub const Level = enum(u3) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn parse(s: []const u8) Level {
        if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(s, "warn")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error")) return .err;
        return .info;
    }
};

pub const Format = enum {
    text,
    json,

    pub fn parse(s: []const u8) Format {
        if (std.ascii.eqlIgnoreCase(s, "json")) return .json;
        return .text;
    }
};

pub const Logger = struct {
    min_level: Level,
    format: Format = .text,
    /// If null, writes go to stderr via std.debug.print. If set, owned fd opened
    /// with O_WRONLY|O_CREAT|O_APPEND; Logger closes it on deinit.
    file_fd: ?c_int = null,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,

    pub fn init(min_level: Level) Logger {
        return .{ .min_level = min_level };
    }

    pub fn initStderr(min_level: Level, format: Format) Logger {
        return .{ .min_level = min_level, .format = format };
    }

    /// Open `path` for appending. Caller owns the returned Logger and must call
    /// `deinit()` to close the fd. Errors only if the file can't be opened —
    /// callers should fall back to `initStderr` on error.
    pub fn initFile(path: [:0]const u8, min_level: Level, format: Format) !Logger {
        const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o644));
        if (fd < 0) return error.OpenFailed;
        return .{
            .min_level = min_level,
            .format = format,
            .file_fd = fd,
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file_fd) |fd| {
            _ = c.close(fd);
            self.file_fd = null;
        }
    }

    pub fn enabled(self: *const Logger, level: Level) bool {
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    fn log(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled(level)) return;

        var ts_buf: [30]u8 = undefined;
        const ts = formatTimestamp(&ts_buf);

        // Format the user message into a stack buffer first. This is the same
        // buffer used for both text and JSON modes; in JSON mode the message
        // becomes the "msg" field value (escaped).
        var msg_buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
            // Message too long — truncate and signal truncation.
            const tail = "...<truncated>";
            const room = msg_buf.len - tail.len;
            const partial = std.fmt.bufPrint(msg_buf[0..room], fmt, args) catch msg_buf[0..0];
            @memcpy(msg_buf[partial.len .. partial.len + tail.len], tail);
            break :blk msg_buf[0 .. partial.len + tail.len];
        };

        var line_buf: [8192]u8 = undefined;
        const line = switch (self.format) {
            .text => std.fmt.bufPrint(&line_buf, "[{s}] [{s}] {s}\n", .{ ts, level.label(), msg }) catch return,
            .json => formatJsonLine(&line_buf, ts, level.label(), msg) orelse return,
        };

        self.write(line);
    }

    fn write(self: *Logger, line: []const u8) void {
        if (self.file_fd) |fd| {
            _ = c.pthread_mutex_lock(&self.mutex);
            defer _ = c.pthread_mutex_unlock(&self.mutex);
            var written: usize = 0;
            while (written < line.len) {
                const n = c.write(fd, line.ptr + written, line.len - written);
                if (n <= 0) return;
                written += @intCast(n);
            }
        } else {
            std.debug.print("{s}", .{line});
        }
    }
};

fn formatJsonLine(buf: []u8, ts: []const u8, level: []const u8, msg: []const u8) ?[]const u8 {
    var pos: usize = 0;
    const prefix = "{\"ts\":\"";
    if (pos + prefix.len > buf.len) return null;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    pos += jsonEscape(buf[pos..], ts) orelse return null;
    const mid1 = "\",\"level\":\"";
    if (pos + mid1.len > buf.len) return null;
    @memcpy(buf[pos .. pos + mid1.len], mid1);
    pos += mid1.len;
    pos += jsonEscape(buf[pos..], level) orelse return null;
    const mid2 = "\",\"msg\":\"";
    if (pos + mid2.len > buf.len) return null;
    @memcpy(buf[pos .. pos + mid2.len], mid2);
    pos += mid2.len;
    pos += jsonEscape(buf[pos..], msg) orelse return null;
    const suffix = "\"}\n";
    if (pos + suffix.len > buf.len) return null;
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;
    return buf[0..pos];
}

/// Write a JSON-escaped version of `s` into `dst`. Returns bytes written, or
/// null if `dst` is too small.
fn jsonEscape(dst: []u8, s: []const u8) ?usize {
    var pos: usize = 0;
    for (s) |ch| {
        switch (ch) {
            '"' => {
                if (pos + 2 > dst.len) return null;
                dst[pos] = '\\';
                dst[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                if (pos + 2 > dst.len) return null;
                dst[pos] = '\\';
                dst[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                if (pos + 2 > dst.len) return null;
                dst[pos] = '\\';
                dst[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                if (pos + 2 > dst.len) return null;
                dst[pos] = '\\';
                dst[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                if (pos + 2 > dst.len) return null;
                dst[pos] = '\\';
                dst[pos + 1] = 't';
                pos += 2;
            },
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                if (pos + 6 > dst.len) return null;
                _ = std.fmt.bufPrint(dst[pos..][0..6], "\\u{x:0>4}", .{ch}) catch return null;
                pos += 6;
            },
            else => {
                if (pos + 1 > dst.len) return null;
                dst[pos] = ch;
                pos += 1;
            },
        }
    }
    return pos;
}

fn formatTimestamp(buf: *[30]u8) []const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    const epoch_secs: u64 = @intCast(@divTrunc(now_ms, 1000));

    const SECS_PER_DAY: u64 = 86400;
    const DAYS_PER_YEAR: u64 = 365;

    var days = epoch_secs / SECS_PER_DAY;
    const day_secs = epoch_secs % SECS_PER_DAY;
    const hours = day_secs / 3600;
    const minutes = (day_secs % 3600) / 60;
    const seconds = day_secs % 60;

    // Compute year/month/day from days since epoch
    var year: u64 = 1970;
    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else DAYS_PER_YEAR;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const month_days = if (isLeapYear(year))
        [_]u64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u64 = 1;
    for (month_days) |md| {
        if (days < md) break;
        days -= md;
        month += 1;
    }

    const s = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, month, days + 1, hours, minutes, seconds,
    }) catch return "????-??-??T??:??:??Z";
    return s;
}

fn isLeapYear(y: u64) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

/// Global logger instance. Set once at startup.
pub var global: Logger = Logger.init(.info);

/// Convenience functions using global logger.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    global.debug(fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    global.info(fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    global.warn(fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    global.err(fmt, args);
}

test "log level parse" {
    try std.testing.expectEqual(Level.debug, Level.parse("debug"));
    try std.testing.expectEqual(Level.info, Level.parse("info"));
    try std.testing.expectEqual(Level.warn, Level.parse("warn"));
    try std.testing.expectEqual(Level.err, Level.parse("error"));
    try std.testing.expectEqual(Level.info, Level.parse("unknown"));
}

test "log level filtering" {
    const logger = Logger.init(.warn);
    try std.testing.expect(!logger.enabled(.debug));
    try std.testing.expect(!logger.enabled(.info));
    try std.testing.expect(logger.enabled(.warn));
    try std.testing.expect(logger.enabled(.err));
}

test "format parse" {
    try std.testing.expectEqual(Format.json, Format.parse("json"));
    try std.testing.expectEqual(Format.json, Format.parse("JSON"));
    try std.testing.expectEqual(Format.text, Format.parse("text"));
    try std.testing.expectEqual(Format.text, Format.parse("anything-else"));
}

test "timestamp format" {
    var buf: [30]u8 = undefined;
    const ts = formatTimestamp(&buf);
    // Should be like "2026-04-23T10:30:00Z" — 20 chars
    try std.testing.expectEqual(@as(usize, 20), ts.len);
    try std.testing.expect(ts[4] == '-');
    try std.testing.expect(ts[10] == 'T');
    try std.testing.expect(ts[19] == 'Z');
}

test "json escape — plain ascii" {
    var buf: [64]u8 = undefined;
    const n = jsonEscape(&buf, "hello world").?;
    try std.testing.expectEqualStrings("hello world", buf[0..n]);
}

test "json escape — quote and backslash" {
    var buf: [64]u8 = undefined;
    const n = jsonEscape(&buf, "say \"hi\" \\ ok").?;
    try std.testing.expectEqualStrings("say \\\"hi\\\" \\\\ ok", buf[0..n]);
}

test "json escape — control chars" {
    var buf: [64]u8 = undefined;
    const n = jsonEscape(&buf, "line1\nline2\ttab\r").?;
    try std.testing.expectEqualStrings("line1\\nline2\\ttab\\r", buf[0..n]);
}

test "json escape — buffer too small" {
    var buf: [4]u8 = undefined;
    try std.testing.expect(jsonEscape(&buf, "abcdefghij") == null);
}

test "format json line — well-formed" {
    var buf: [256]u8 = undefined;
    const line = formatJsonLine(&buf, "2026-05-24T12:00:00Z", "WARN", "broadcast to fd=7 failed: BrokenPipe").?;
    try std.testing.expectEqualStrings(
        "{\"ts\":\"2026-05-24T12:00:00Z\",\"level\":\"WARN\",\"msg\":\"broadcast to fd=7 failed: BrokenPipe\"}\n",
        line,
    );
}

test "format json line — escapes in message" {
    var buf: [256]u8 = undefined;
    const line = formatJsonLine(&buf, "2026-05-24T12:00:00Z", "INFO", "got \"frame\" type=3\nrest").?;
    try std.testing.expectEqualStrings(
        "{\"ts\":\"2026-05-24T12:00:00Z\",\"level\":\"INFO\",\"msg\":\"got \\\"frame\\\" type=3\\nrest\"}\n",
        line,
    );
}
