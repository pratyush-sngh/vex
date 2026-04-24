const std = @import("std");

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

pub const Logger = struct {
    min_level: Level,

    pub fn init(min_level: Level) Logger {
        return .{ .min_level = min_level };
    }

    pub fn debug(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    fn log(self: *const Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        // Format: [2026-04-23T10:30:00Z] [INFO] message
        var ts_buf: [30]u8 = undefined;
        const ts = formatTimestamp(&ts_buf);

        std.debug.print("[{s}] [{s}] " ++ fmt ++ "\n", .{ts, level.label()} ++ args);
    }
};

fn formatTimestamp(buf: *[30]u8) []const u8 {
    const now_ms = std.time.milliTimestamp();
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
    // info should be filtered (no crash, just test it doesn't panic)
    logger.info("this should be filtered", .{});
    // warn and above should pass through
    logger.warn("this should appear", .{});
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
