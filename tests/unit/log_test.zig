// Migrated unit tests for src/log.zig.

const std = @import("std");
const vex_log = @import("../../src/log.zig");

const Level = vex_log.Level;
const Format = vex_log.Format;
const Logger = vex_log.Logger;
const formatTimestamp = vex_log.formatTimestamp;
const jsonEscape = vex_log.jsonEscape;
const formatJsonLine = vex_log.formatJsonLine;

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
