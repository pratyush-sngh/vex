const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NodeRole = enum { leader, follower };

pub const ClusterNode = struct {
    id: u16,
    role: NodeRole,
    host: []const u8,
    port: u16,
};

/// Cluster configuration parsed from a config file.
///
/// Format:
///   node <id> <leader|follower> <host>:<port>
///   self <id>
///
/// Example:
///   node 1 leader 10.0.0.1:6380
///   node 2 follower 10.0.0.2:6380
///   node 3 follower 10.0.0.3:6380
///   self 1
pub const ClusterConfig = struct {
    self_id: u16,
    nodes: []ClusterNode,
    allocator: Allocator,

    pub fn deinit(self: *ClusterConfig) void {
        for (self.nodes) |n| {
            self.allocator.free(n.host);
        }
        self.allocator.free(self.nodes);
    }

    /// Get this node's config.
    pub fn selfNode(self: *const ClusterConfig) ?ClusterNode {
        for (self.nodes) |n| {
            if (n.id == self.self_id) return n;
        }
        return null;
    }

    /// Is this node the leader?
    pub fn isLeader(self: *const ClusterConfig) bool {
        const node = self.selfNode() orelse return false;
        return node.role == .leader;
    }

    /// Get the leader node.
    pub fn getLeader(self: *const ClusterConfig) ?ClusterNode {
        for (self.nodes) |n| {
            if (n.role == .leader) return n;
        }
        return null;
    }

    /// Count followers.
    pub fn followerCount(self: *const ClusterConfig) usize {
        var c: usize = 0;
        for (self.nodes) |n| {
            if (n.role == .follower) c += 1;
        }
        return c;
    }
};

/// Parse a cluster config file.
pub fn parse(allocator: Allocator, io: std.Io, path: []const u8) !ClusterConfig {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const data = try readAll(file, io, allocator);
    defer allocator.free(data);

    return parseString(allocator, data);
}

/// Parse cluster config from a string (for testing).
pub fn parseString(allocator: Allocator, data: []const u8) !ClusterConfig {
    var nodes = std.array_list.Managed(ClusterNode).init(allocator);
    errdefer {
        for (nodes.items) |n| allocator.free(n.host);
        nodes.deinit();
    }

    var self_id: ?u16 = null;
    var pos: usize = 0;

    while (pos < data.len) {
        // Find line end
        var end = pos;
        while (end < data.len and data[end] != '\n') : (end += 1) {}
        const raw_line = data[pos..end];
        // Trim trailing \r, spaces, tabs
        var line_end: usize = raw_line.len;
        while (line_end > 0 and (raw_line[line_end - 1] == '\r' or raw_line[line_end - 1] == ' ' or raw_line[line_end - 1] == '\t')) {
            line_end -= 1;
        }
        const line = raw_line[0..line_end];
        pos = end + 1;

        // Skip empty lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Parse "self <id>"
        if (std.mem.startsWith(u8, line, "self ")) {
            self_id = std.fmt.parseInt(u16, std.mem.trim(u8, line[5..], &[_]u8{ ' ', '\t' }), 10) catch
                return error.InvalidConfig;
            continue;
        }

        // Parse "node <id> <role> <host>:<port>"
        if (std.mem.startsWith(u8, line, "node ")) {
            const rest = line[5..];
            // Split by spaces
            var parts: [4][]const u8 = undefined;
            var part_count: usize = 0;
            var start: usize = 0;
            var in_space = true;
            for (rest, 0..) |c, i| {
                if (c == ' ' or c == '\t') {
                    if (!in_space and part_count < 4) {
                        parts[part_count] = rest[start..i];
                        part_count += 1;
                    }
                    in_space = true;
                } else {
                    if (in_space) start = i;
                    in_space = false;
                }
            }
            if (!in_space and part_count < 4) {
                parts[part_count] = rest[start..];
                part_count += 1;
            }

            if (part_count < 3) return error.InvalidConfig;

            const id = std.fmt.parseInt(u16, parts[0], 10) catch return error.InvalidConfig;
            const role: NodeRole = if (std.mem.eql(u8, parts[1], "leader"))
                .leader
            else if (std.mem.eql(u8, parts[1], "follower"))
                .follower
            else
                return error.InvalidConfig;

            // Parse host:port
            const addr = parts[2];
            const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidConfig;
            const host = try allocator.dupe(u8, addr[0..colon]);
            errdefer allocator.free(host);
            const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch return error.InvalidConfig;

            try nodes.append(.{ .id = id, .role = role, .host = host, .port = port });
            continue;
        }

        // Unknown line — skip
    }

    if (self_id == null) return error.InvalidConfig;

    return .{
        .self_id = self_id.?,
        .nodes = try nodes.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn readAll(file: std.Io.File, io: std.Io, allocator: Allocator) ![]u8 {
    const len = try file.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != @as(usize, @intCast(len))) return error.UnexpectedEof;
    return buf;
}

// ─── Tests ────────────────────────────────────────────────────────────

test "parse cluster config" {
    const data =
        \\# Vex cluster config
        \\node 1 leader 10.0.0.1:6380
        \\node 2 follower 10.0.0.2:6380
        \\node 3 follower 10.0.0.3:6380
        \\self 1
        \\
    ;
    var config = try parseString(std.testing.allocator, data);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 1), config.self_id);
    try std.testing.expectEqual(@as(usize, 3), config.nodes.len);
    try std.testing.expect(config.isLeader());

    const leader = config.getLeader().?;
    try std.testing.expectEqualStrings("10.0.0.1", leader.host);
    try std.testing.expectEqual(@as(u16, 6380), leader.port);

    try std.testing.expectEqual(@as(usize, 2), config.followerCount());
}

test "parse follower config" {
    const data =
        \\node 1 leader 10.0.0.1:6380
        \\node 2 follower 10.0.0.2:6380
        \\self 2
        \\
    ;
    var config = try parseString(std.testing.allocator, data);
    defer config.deinit();

    try std.testing.expect(!config.isLeader());
    try std.testing.expectEqual(@as(u16, 2), config.self_id);

    const self_node = config.selfNode().?;
    try std.testing.expectEqual(NodeRole.follower, self_node.role);
}

test "invalid config missing self" {
    const data = "node 1 leader 10.0.0.1:6380\n";
    const result = parseString(std.testing.allocator, data);
    try std.testing.expect(result == error.InvalidConfig);
}
