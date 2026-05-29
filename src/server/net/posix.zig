//! POSIX-family net.iface implementation.
//!
//! Status: **stub**. The active vex binary still goes through
//! `src/server/worker.zig`'s inline `connRead` / `connWrite` /
//! `submitUringWrite` plus `src/server/event_loop.zig`. This module
//! exists to anchor the migration path documented in
//! `../../../docs/dpdk.md`:
//!
//! 1. Lift the io_uring submit/complete machinery out of
//!    `worker.zig` into a `PosixDriver` defined here.
//! 2. Lift the kqueue/epoll fallback similarly.
//! 3. Adapt `worker.zig` to call through `net.iface.Driver` instead
//!    of touching syscalls directly. (This is the disruptive step;
//!    do it on a feature flag.)
//! 4. Land the `dpdk.zig` sibling. By that point the worker doesn't
//!    care which Driver it has.
//!
//! Each step is independently testable and reversible. None of them
//! land in this commit.

const std = @import("std");
const iface = @import("iface.zig");

// Intentionally empty. Concrete types land in step 1 above.
//
// Sketch for future readers:
//
//   pub const PosixDriver = struct {
//       backend: union(enum) {
//           io_uring: IoUringBackend,
//           epoll: EpollBackend,
//           kqueue: KqueueBackend,
//       },
//
//       pub fn init(...) !PosixDriver { ... }
//       pub fn driver(self: *PosixDriver) iface.Driver { ... }
//   };
//
//   const PosixConnection = struct { fd: i32, ... };
//   const PosixListener   = struct { fd: i32, ... };
