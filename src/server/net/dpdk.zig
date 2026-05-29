//! DPDK + F-Stack net.iface implementation.
//!
//! Status: **stub**. No DPDK code links into the binary. The first
//! real commits on this branch will fill in:
//!
//! 1. `tools/dpdk/Dockerfile.dpdk` — base image with DPDK + F-Stack
//!    installed and a hugepages bootstrap.
//! 2. `tools/dpdk/aws-perf-up.sh` — `aws ec2 run-instances` for the
//!    `c5n.18xlarge` test target (see docs/dpdk.md §Test plan).
//! 3. Build wiring: `-Ddpdk=true` build option that links against
//!    system DPDK headers and emits a `vex-dpdk` binary alongside
//!    `vex`. Off by default; Linux x86_64 only.
//! 4. `DpdkDriver` here, backed by F-Stack's POSIX shim
//!    (`ff_socket` / `ff_accept` / `ff_recv` / `ff_send` /
//!    `ff_close` / `ff_kqueue`). Provides exactly `iface.Driver`.
//! 5. Concrete `DpdkListener` and `DpdkConnection` wrapping F-Stack
//!    fds; their VTables wire to the `ff_*` C calls via Zig
//!    `extern fn` declarations.
//! 6. RSS hash → lcore steering so each worker's `DpdkDriver` polls
//!    exactly its share of the NIC RX queues (see docs/dpdk.md
//!    §"How vex's threading maps to DPDK lcores").
//!
//! None of those land in this commit. This file is here so the
//! directory layout and the abstraction's shape are visible while
//! the real work is being scoped.

const std = @import("std");
const iface = @import("iface.zig");

// Intentionally empty. The minimal F-Stack `extern fn` block and the
// concrete DpdkDriver land in a later commit on this branch.
//
// Sketch for future readers:
//
//   // F-Stack C symbols. The full set is small (~12 calls) because
//   // F-Stack already provides a POSIX-shaped facade.
//   extern fn ff_init(argc: c_int, argv: [*][*:0]u8) c_int;
//   extern fn ff_run(loop: ?*const fn(arg: ?*anyopaque) callconv(.c) c_int,
//                    arg: ?*anyopaque) c_int;
//   extern fn ff_socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
//   extern fn ff_bind(fd: c_int, addr: *const std.posix.sockaddr,
//                     len: u32) c_int;
//   extern fn ff_listen(fd: c_int, backlog: c_int) c_int;
//   extern fn ff_accept(fd: c_int, addr: ?*std.posix.sockaddr,
//                       len: ?*u32) c_int;
//   extern fn ff_recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
//   extern fn ff_send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
//   extern fn ff_close(fd: c_int) c_int;
//
//   pub const DpdkDriver = struct { ... };
//   const DpdkListener   = struct { ff_fd: c_int, ... };
//   const DpdkConnection = struct { ff_fd: c_int, ... };
