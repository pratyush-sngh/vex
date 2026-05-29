# src/server/net/

Network layer abstraction that decouples the redis-protocol code path
(parser, dispatcher, engines) from whichever transport is moving bytes
underneath. Two backends are planned:

| Backend | Status | Source |
|---|---|---|
| **posix** (io_uring / epoll / kqueue) | Active — currently inlined in `src/server/worker.zig` and `src/server/event_loop.zig`. Lives here as a stub today; migration is incremental on this branch. | `posix.zig` |
| **dpdk** (kernel-bypass via DPDK + F-Stack TCP) | Stub. Real implementation tracked in [docs/dpdk.md](../../../docs/dpdk.md). | `dpdk.zig` |

## Why an abstraction at all

The DPDK path replaces only the L1-L4 substrate — RESP framing, the
KV / graph engines, persistence, all of `command/`, all of `engine/`,
and the entire `worker.zig` command-dispatch logic are unchanged. The
narrowest possible cut between "the part that has to change" and "the
part that absolutely doesn't" lives at the boundary defined by
[`iface.zig`](iface.zig).

The aim of this abstraction is **not** to enable arbitrary transports
forever — it's to enable swapping io_uring for DPDK behind a single
known surface, with the option to add others later without
rediscovering the cut. We accept some indirection cost in the posix
path in exchange for keeping the DPDK port from sprawling.

## Status today

`iface.zig` defines the shape. The posix and dpdk modules are
**stubs** — they document where their implementations will go, but
the active vex binary still uses the inline code in `worker.zig`. No
behavior change yet. See [docs/dpdk.md](../../../docs/dpdk.md) for
the migration sequence.
