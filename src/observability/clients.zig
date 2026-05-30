//! Process-wide registry of connected clients, for CLIENT LIST.
//!
//! Each Connection embeds a ClientView; on accept the worker registers a
//! pointer to its view, on close it unregisters. CLIENT LIST snapshots the
//! registry under a brief mutex (rare command, contention irrelevant).
//!
//! Why a separate module: Connection is a worker.zig-private type, but
//! handler.zig can't import worker.zig (worker imports handler — cycle).
//! ClientView lives here so both sides depend only on observability/.

const std = @import("std");

pub const MAX_ADDR_LEN: usize = 47; // ipv6 "[xxxx:...:xxxx]:65535"
pub const MAX_NAME_LEN: usize = 64;

/// Per-connection view used by CLIENT LIST. Written by the owning worker
/// (single-owner), read by snapshot() under the registry mutex.
/// All reads/writes from the owning thread can be plain field access; the
/// snapshot path uses memcpy under the lock to grab a consistent slice
/// (acceptable inconsistency for an introspection command).
pub const ClientView = struct {
    /// Monotonic per-process id assigned at accept.
    id: u64 = 0,
    /// Socket fd (i32 fits in i64 RESP int just fine).
    fd: i32 = -1,
    /// Currently-selected logical database.
    db: u8 = 0,
    /// True if the connection is in pub/sub mode.
    pubsub_mode: bool = false,
    /// True if a MULTI is in flight.
    in_multi: bool = false,
    /// ts_ms when the connection was accepted.
    connect_ts_ms: i64 = 0,
    /// ts_ms of the last command dispatch (or accept if none yet).
    last_interaction_ts_ms: i64 = 0,
    /// Last command's index in the cmd_table. 0xFF = none.
    last_cmd_idx: u8 = 0xFF,
    /// Current input buffer size (bytes pending parse). Worker updates
    /// pre-dispatch.
    qbuf: u32 = 0,
    /// Current output buffer size (bytes pending write).
    obl: u32 = 0,
    /// Peer "ip:port" snapshot, captured at accept. Empty if getpeername
    /// failed. NUL-terminated within MAX_ADDR_LEN.
    addr: [MAX_ADDR_LEN + 1]u8 = std.mem.zeroes([MAX_ADDR_LEN + 1]u8),
    addr_len: u8 = 0,
    /// Client name set via CLIENT SETNAME. NUL-terminated within MAX_NAME_LEN.
    name: [MAX_NAME_LEN + 1]u8 = std.mem.zeroes([MAX_NAME_LEN + 1]u8),
    name_len: u8 = 0,

    pub fn addrSlice(self: *const ClientView) []const u8 {
        return self.addr[0..self.addr_len];
    }
    pub fn nameSlice(self: *const ClientView) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn setName(self: *ClientView, s: []const u8) void {
        const n = @min(s.len, MAX_NAME_LEN);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
    pub fn setAddr(self: *ClientView, s: []const u8) void {
        const n = @min(s.len, MAX_ADDR_LEN);
        @memcpy(self.addr[0..n], s[0..n]);
        self.addr_len = @intCast(n);
    }
};

pub const MAX_CLIENTS: usize = 16384;

var registry: [MAX_CLIENTS]?*ClientView = @splat(null);
var registry_len: usize = 0;
var registry_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

/// Register a ClientView with the global registry. Idempotent.
/// Returns false if MAX_CLIENTS is reached (caller should still proceed —
/// the connection is fine, it just won't appear in CLIENT LIST).
pub fn register(view: *ClientView) bool {
    _ = std.c.pthread_mutex_lock(&registry_mutex);
    defer _ = std.c.pthread_mutex_unlock(&registry_mutex);
    for (registry[0..registry_len]) |existing| {
        if (existing == view) return true;
    }
    if (registry_len >= MAX_CLIENTS) return false;
    registry[registry_len] = view;
    registry_len += 1;
    return true;
}

pub fn unregister(view: *ClientView) void {
    _ = std.c.pthread_mutex_lock(&registry_mutex);
    defer _ = std.c.pthread_mutex_unlock(&registry_mutex);
    var i: usize = 0;
    while (i < registry_len) : (i += 1) {
        if (registry[i] == view) {
            registry[i] = registry[registry_len - 1];
            registry[registry_len - 1] = null;
            registry_len -= 1;
            return;
        }
    }
}

/// Snapshot every registered ClientView into an owned slice. Use this for
/// CLIENT LIST — readers iterate the snapshot without holding the lock.
pub fn snapshot(alloc: std.mem.Allocator) ![]ClientView {
    _ = std.c.pthread_mutex_lock(&registry_mutex);
    defer _ = std.c.pthread_mutex_unlock(&registry_mutex);
    const out = try alloc.alloc(ClientView, registry_len);
    var i: usize = 0;
    while (i < registry_len) : (i += 1) {
        if (registry[i]) |v| {
            out[i] = v.*; // memcpy under lock — accepts brief inconsistency
        } else {
            out[i] = .{};
        }
    }
    return out;
}

pub fn count() usize {
    _ = std.c.pthread_mutex_lock(&registry_mutex);
    defer _ = std.c.pthread_mutex_unlock(&registry_mutex);
    return registry_len;
}

pub fn resetForTest() void {
    _ = std.c.pthread_mutex_lock(&registry_mutex);
    defer _ = std.c.pthread_mutex_unlock(&registry_mutex);
    for (registry[0..registry_len]) |*slot| slot.* = null;
    registry_len = 0;
}

// ── Tests ───────────────────────────────────────────────────────────

