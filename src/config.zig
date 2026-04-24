const std = @import("std");
const Allocator = std.mem.Allocator;

/// Simple key-value config file parser.
/// Format: "key value" per line, # for comments, blank lines ignored.
/// Example:
///   port 6380
///   requirepass secret
///   maxmemory 256mb
pub const ConfigFile = struct {
    entries: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ConfigFile {
        return .{
            .entries = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConfigFile) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Parse a config file from raw bytes.
    pub fn parse(allocator: Allocator, data: []const u8) !ConfigFile {
        var cfg = ConfigFile.init(allocator);
        errdefer cfg.deinit();

        var line_start: usize = 0;
        for (data, 0..) |byte, i| {
            if (byte == '\n' or i == data.len - 1) {
                var line_end = i;
                if (byte == '\n' and line_end > 0) {
                    line_end = i;
                } else if (i == data.len - 1 and byte != '\n') {
                    line_end = i + 1;
                }
                const line = std.mem.trim(u8, data[line_start..line_end], &[_]u8{ ' ', '\t', '\r' });
                line_start = i + 1;

                if (line.len == 0 or line[0] == '#') continue;

                // Split on first whitespace
                var split_pos: ?usize = null;
                for (line, 0..) |c, j| {
                    if (c == ' ' or c == '\t') {
                        split_pos = j;
                        break;
                    }
                }

                if (split_pos) |sp| {
                    const key = std.mem.trim(u8, line[0..sp], &[_]u8{ ' ', '\t' });
                    const value = std.mem.trim(u8, line[sp + 1 ..], &[_]u8{ ' ', '\t' });
                    if (key.len > 0) {
                        const owned_key = try allocator.dupe(u8, key);
                        errdefer allocator.free(owned_key);
                        const owned_val = try allocator.dupe(u8, value);
                        errdefer allocator.free(owned_val);
                        try cfg.entries.put(owned_key, owned_val);
                    }
                } else {
                    // Key with no value (boolean flag)
                    const owned_key = try allocator.dupe(u8, line);
                    errdefer allocator.free(owned_key);
                    const owned_val = try allocator.dupe(u8, "");
                    errdefer allocator.free(owned_val);
                    try cfg.entries.put(owned_key, owned_val);
                }
            }
        }
        return cfg;
    }

    /// Load and parse a config file from disk.
    pub fn loadFile(allocator: Allocator, io: std.Io, path: []const u8) !ConfigFile {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const len = try file.length(io);
        if (len == 0) return ConfigFile.init(allocator);
        const data = try allocator.alloc(u8, @intCast(len));
        defer allocator.free(data);
        const n = try file.readPositionalAll(io, data, 0);
        return ConfigFile.parse(allocator, data[0..n]);
    }

    pub fn get(self: *const ConfigFile, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "parse config file" {
    const allocator = std.testing.allocator;
    const data =
        \\# Vex configuration
        \\port 6380
        \\requirepass secret
        \\maxmemory 256mb
        \\
        \\# Empty lines and comments ignored
        \\reactor
        \\maxclients 5000
    ;

    var cfg = try ConfigFile.parse(allocator, data);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("6380", cfg.get("port").?);
    try std.testing.expectEqualStrings("secret", cfg.get("requirepass").?);
    try std.testing.expectEqualStrings("256mb", cfg.get("maxmemory").?);
    try std.testing.expectEqualStrings("5000", cfg.get("maxclients").?);
    try std.testing.expectEqualStrings("", cfg.get("reactor").?); // boolean flag
    try std.testing.expect(cfg.get("nonexistent") == null);
}

test "parse empty config" {
    const allocator = std.testing.allocator;
    var cfg = try ConfigFile.parse(allocator, "");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.entries.count());
}

test "parse config with comments only" {
    const allocator = std.testing.allocator;
    const data = "# just a comment\n# another\n";
    var cfg = try ConfigFile.parse(allocator, data);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.entries.count());
}
