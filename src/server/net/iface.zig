//! Network layer interface — the narrow cut between vex's RESP-and-up
//! code and the L1-L4 substrate underneath. Currently a shape document
//! only; no live code paths use it yet. See ../../../docs/dpdk.md for
//! the migration plan.
//!
//! The deliberate goal of this file is to be *boring*: every type here
//! exists because both `posix` (io_uring/epoll/kqueue) and `dpdk`
//! (kernel-bypass) implementations need it. If a type only one backend
//! needs ends up here, that's the signal to push it back into the
//! backend module.
//!
//! Naming convention: the methods on every interface struct take
//! `self` as their last parameter. That matches Zig's preferred
//! vtable shape (closure pointer at the end) and makes a future
//! migration to direct interface types (Zig 0.18+) painless.

const std = @import("std");

/// One bidirectional byte stream — TCP connection in the posix world,
/// an F-Stack connection in the DPDK world. The connection object
/// doesn't know who owns it; the listener that produced it is gone by
/// the time vex sees the Connection.
pub const Connection = struct {
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        recv: *const fn (impl: *anyopaque, buf: []u8) RecvResult,
        send: *const fn (impl: *anyopaque, data: []const u8) SendResult,
        close: *const fn (impl: *anyopaque) void,
        /// File-descriptor-like handle for logging / metrics only.
        /// On DPDK this is a synthetic identifier, not a kernel fd.
        handle: *const fn (impl: *anyopaque) u64,
    };

    pub const RecvResult = union(enum) {
        /// `bytes` of payload now live in the caller's buffer.
        ok: usize,
        /// Peer closed cleanly (FIN / TLS close_notify / DPDK reset bit).
        closed,
        /// Nothing available right now. Caller should poll again.
        again,
        /// Hard failure (RST, NIC error, OOM). The caller should
        /// close() and discard the Connection.
        err,
    };

    pub const SendResult = union(enum) {
        /// `bytes` of `data` were written. May be < data.len.
        ok: usize,
        /// Send queue full; caller should retry after a poll cycle.
        again,
        /// Peer dropped the connection.
        closed,
        err,
    };

    pub inline fn recv(self: Connection, buf: []u8) RecvResult {
        return self.vtable.recv(self.impl, buf);
    }
    pub inline fn send(self: Connection, data: []const u8) SendResult {
        return self.vtable.send(self.impl, data);
    }
    pub inline fn close(self: Connection) void {
        return self.vtable.close(self.impl);
    }
    pub inline fn handle(self: Connection) u64 {
        return self.vtable.handle(self.impl);
    }
};

/// A bound listening socket — the thing that produces new Connections
/// as clients arrive.
pub const Listener = struct {
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns null if no client is waiting; non-null on accept.
        /// Never blocks — callers integrate accept into their poll loop.
        accept: *const fn (impl: *anyopaque) ?Connection,
        close: *const fn (impl: *anyopaque) void,
    };

    pub inline fn accept(self: Listener) ?Connection {
        return self.vtable.accept(self.impl);
    }
    pub inline fn close(self: Listener) void {
        return self.vtable.close(self.impl);
    }
};

/// One ready event from a poll() call. The backend (posix or DPDK)
/// produces these whenever it advances. The redis-protocol code
/// drains them.
pub const Event = struct {
    conn: Connection,
    kind: Kind,

    pub const Kind = enum {
        readable,
        writable,
        hangup,
        err,
    };
};

/// The top-level driver — the thing a worker thread holds. One
/// Driver per lcore in the DPDK model; one per worker in the posix
/// model. The Driver owns the Listener and the polling loop.
pub const Driver = struct {
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Bind a listener at addr:port. Returns null on bind failure.
        /// Caller takes ownership; multiple listeners per driver are
        /// allowed (DPDK case: one for RESP, one for replication, etc.)
        listen: *const fn (impl: *anyopaque, addr: []const u8, port: u16) ?Listener,

        /// Poll for events, fill the caller's buffer, return how many
        /// were filled. `timeout_ns` is advisory — DPDK ignores it and
        /// always returns immediately; posix uses it as a wait bound.
        poll: *const fn (impl: *anyopaque, out: []Event, timeout_ns: i64) usize,

        /// Wake any thread blocked inside `poll`. No-op on DPDK.
        wake: *const fn (impl: *anyopaque) void,

        /// Tear down. After this, no further method calls are valid.
        deinit: *const fn (impl: *anyopaque) void,
    };

    pub inline fn listen(self: Driver, addr: []const u8, port: u16) ?Listener {
        return self.vtable.listen(self.impl, addr, port);
    }
    pub inline fn poll(self: Driver, out: []Event, timeout_ns: i64) usize {
        return self.vtable.poll(self.impl, out, timeout_ns);
    }
    pub inline fn wake(self: Driver) void {
        return self.vtable.wake(self.impl);
    }
    pub inline fn deinit(self: Driver) void {
        return self.vtable.deinit(self.impl);
    }
};
