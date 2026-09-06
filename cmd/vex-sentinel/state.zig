//! Persisted sentinel state: the current leader node id and the highest
//! epoch this sentinel has ever issued or observed.
//!
//! The file is rewritten via vex_atomic_io.atomicWrite on every change so
//! a crash mid-update either leaves the previous state or the new state,
//! never partial. This matches the durability story for vex.epoch.
//!
//! Wire format (little-endian, fixed 32 bytes):
//!   [0..8]   magic "VEXSENT1"
//!   [8..10]  leader_node_id (u16; 0 = unknown / no leader)
//!   [10..18] epoch (u64)
//!   [18..26] last_update_unix_ms (i64)
//!   [26..32] reserved (zero)

const std = @import("std");
const atomic_io = @import("vex_atomic_io");
const Allocator = std.mem.Allocator;

pub const MAGIC = "VEXSENT1".*;
pub const FILE_SIZE: usize = 32;

pub const State = struct {
    leader_node_id: u16 = 0,
    epoch: u64 = 0,
    last_update_unix_ms: i64 = 0,

    pub fn encode(self: State) [FILE_SIZE]u8 {
        var buf: [FILE_SIZE]u8 = std.mem.zeroes([FILE_SIZE]u8);
        @memcpy(buf[0..8], &MAGIC);
        std.mem.writeInt(u16, buf[8..10], self.leader_node_id, .little);
        std.mem.writeInt(u64, buf[10..18], self.epoch, .little);
        std.mem.writeInt(i64, buf[18..26], self.last_update_unix_ms, .little);
        return buf;
    }

    pub fn decode(buf: []const u8) !State {
        if (buf.len < FILE_SIZE) return error.Truncated;
        if (!std.mem.eql(u8, buf[0..8], &MAGIC)) return error.BadMagic;
        return .{
            .leader_node_id = std.mem.readInt(u16, buf[8..10], .little),
            .epoch = std.mem.readInt(u64, buf[10..18], .little),
            .last_update_unix_ms = std.mem.readInt(i64, buf[18..26], .little),
        };
    }
};

pub const Store = struct {
    allocator: Allocator,
    path: []const u8,
    current: State,

    pub fn init(allocator: Allocator, path: []const u8) Store {
        return .{ .allocator = allocator, .path = path, .current = .{} };
    }

    /// Load existing state from disk. Returns a fresh zero State when the
    /// file is missing — first boot is not an error.
    pub fn load(self: *Store) !void {
        const path_z = try self.allocator.dupeSentinel(u8, self.path, 0);
        defer self.allocator.free(path_z);

        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            self.current = .{};
            return;
        }
        defer _ = std.c.close(fd);

        var buf: [FILE_SIZE]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n < @as(isize, FILE_SIZE)) return error.Truncated;
        self.current = try State.decode(&buf);
    }

    pub fn save(self: *Store, new_state: State) !void {
        const buf = new_state.encode();
        try atomic_io.atomicWrite(self.allocator, self.path, &buf);
        self.current = new_state;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "State encode/decode round-trip" {
    const s = State{ .leader_node_id = 42, .epoch = 123, .last_update_unix_ms = 1_700_000_000_000 };
    const buf = s.encode();
    const back = try State.decode(&buf);
    try std.testing.expectEqual(s.leader_node_id, back.leader_node_id);
    try std.testing.expectEqual(s.epoch, back.epoch);
    try std.testing.expectEqual(s.last_update_unix_ms, back.last_update_unix_ms);
}

test "State decode rejects bad magic" {
    var buf: [FILE_SIZE]u8 = std.mem.zeroes([FILE_SIZE]u8);
    @memcpy(buf[0..8], "NOTAVEXS");
    try std.testing.expectError(error.BadMagic, State.decode(&buf));
}
