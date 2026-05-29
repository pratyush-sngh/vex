# DPDK kernel-bypass networking — design doc

[Back to README](../README.md) | [Benchmarks](benchmarks.md) | [Architecture](architecture.md)

**Status:** scaffolding only. No DPDK code lives in the binary yet.
This document records the decisions; subsequent commits implement them
incrementally on this branch.

---

## Goal

Take a redis-protocol server that already saturates io_uring on Linux
(see [benchmarks.md](benchmarks.md): vex hits ~10M ops/sec on UDS,
~2M on TCP) and push the TCP path to within 2x of the UDS path by
bypassing the kernel network stack entirely. Concretely:

- **Target**: sustained 8M+ ops/sec on TCP for a single small key
  workload (GET/SET on 4-byte payloads) on a single dual-NUMA box
  with one 25 GbE port at line rate.
- **Boundary**: only the network layer changes. RESP parsing, the
  KV / graph engines, persistence, replication — none of those move.

## Why DPDK specifically (vs alternatives)

| Option | Pro | Con | Verdict |
|---|---|---|---|
| **io_uring** (today) | Real socket semantics, kernel-managed TCP | Per-syscall cost, copy through skb, scheduling on producer cores | ✅ keep for posix path |
| **AF_XDP** | Bypasses skb without leaving the kernel; simpler ops | Still pays for XDP program JIT + ring-buffer copy; needs newer kernel | Maybe; revisit if DPDK is too painful |
| **DPDK** | Polled NIC RX/TX rings, zero-copy mbufs, NUMA-aware lcores | Driver detaches from kernel; need userspace TCP stack; ops burden | ✅ chosen for this work |
| **RDMA / RoCE** | Lowest latency | NIC-vendor-specific; RDMA-on-TCP isn't how vex's clients are wired today | ❌ out of scope |

DPDK wins because the client-side is unchanged: clients open ordinary
TCP sockets, hit the vex IP on the chosen port, send RESP-formatted
commands. The kernel-bypass layer is invisible above the L4 boundary.

## The hard part: DPDK is L1-L2, but RESP is L7

DPDK polls the NIC RX queue and hands the application **packets**, not
TCP segments. To serve RESP we need TCP termination, IP fragmentation
handling, the listen-accept-handshake machinery, retransmits, the
whole stack. We need to decide where that comes from. The realistic
options:

### Option A — Embed a userspace TCP stack

- **F-Stack** ([F-Stack](https://www.f-stack.org/)) — FreeBSD's TCP
  stack ported over DPDK with a POSIX-like socket shim. Mature. Adds
  ~250K LOC of C; binding from Zig is non-trivial but conceptually
  straightforward (the socket shim is `fstack/ff_*` and looks like
  Berkeley sockets).
- **TLDK** ([TLDK](https://github.com/intel/tldk)) — Intel's
  Transport Layer Development Kit. Tighter integration with DPDK,
  smaller surface, less battle-tested in production.
- **mTCP** — academic project, less actively maintained, but very
  thin and one of the cleanest references.

### Option B — Roll a minimal userspace TCP in Zig

Vex's wire shape is small: short-lived RESP-style request/response,
no long-lived bidirectional streams once we strip pub/sub. A
half-decent in-Zig TCP for the request/response case is on the order
of ~3k LOC. Big upside is no FFI to a C giant; big downside is we
inherit decades of corner cases that F-Stack already solved.

### Option C — Skip TCP, build a custom UDP protocol

Some KV systems (e.g. Aerospike) use a custom request/response
framing over UDP. Removes TCP from the picture entirely but breaks
client compatibility with redis-cli, Jedis, etc. Out of scope for v1.

### Decision (provisional)

Start with **Option A / F-Stack**. Rationale:

- The risk of subtle TCP bugs in a hand-rolled stack would bottleneck
  the whole effort on hard-to-debug retransmit edges.
- F-Stack's BSD lineage means the socket semantics match what vex
  already expects, so the rest of the codebase changes very little.
- If the FFI overhead turns out to dominate, we can swap to Option B
  later behind the same abstraction; revisiting that decision is
  cheap *if the abstraction layer is right* — which is what this
  branch's first commit is really about.

## How vex's threading maps to DPDK lcores

DPDK pins polling threads to physical cores ("lcores") and never
voluntarily yields. Today vex's worker threads do almost the same
thing already — busy-poll their event loop, handle whatever the
event loop hands them, repeat. The mapping is natural:

```
NIC RX queue 0 ──→ lcore 0 (worker 0) ──→ engines + RESP path
NIC RX queue 1 ──→ lcore 1 (worker 1) ──→ engines + RESP path
NIC RX queue N ──→ lcore N (worker N) ──→ engines + RESP path
```

With RSS (receive-side scaling) hashing client connections to queues
by 5-tuple, each lcore owns the connections it processes —
independent of every other lcore for the request/response path.
Cross-worker coordination (pub/sub, cluster replication, AOF flush)
already runs on its own lock disciplines and stays unchanged.

Open question: how the **listener** lcore (the one doing accept on
the F-Stack handle) hands new connections to the per-RSS-queue
workers. The natural answer is "it doesn't, RSS does it for us once
the SYN lands", but F-Stack's listen socket lives on a particular
lcore and that lcore receives the SYN; we need to confirm the
handover protocol matches the per-RSS model.

## What's in the v0.10 (DPDK) milestone

- [ ] Build option `-Ddpdk=true` (off by default; Linux x86_64 only).
- [ ] `src/server/net/` abstraction layer that the current posix
      (io_uring/epoll/kqueue) path implements as one driver and the
      DPDK path implements as another. **This commit starts here.**
- [ ] Zig binding to a minimal subset of `rte_eal`, `rte_mbuf`,
      `rte_ethdev`, `rte_lcore`. Hand-written; no full binding
      generator — only what the listener + worker actually call.
- [ ] F-Stack integration (initially via the POSIX shim;
      bypass-direct later if profiling demands it).
- [ ] Hugepages + NIC binding tooling captured in `tools/dpdk/`
      + `Dockerfile.dpdk` for repeatable lab runs.
- [ ] A perf gate in CI that *compiles* the DPDK target on every PR
      but doesn't try to run it (no NIC in GH Actions).
- [ ] Lab perf comparison published in `docs/benchmarks.md`:
      posix-io_uring vs dpdk-fstack on the same single-box config.

Explicitly **not** in v0.10:

- AF_XDP. We'll reconsider once DPDK ships, depending on how
  painful the ops surface ended up being.
- HW offloads (TLS termination, segmentation, checksum) — none of
  the boxes we test on initially have them.
- Multi-NIC bonding / failover.
- Anything for IPv4 fragmentation reassembly; we expect MTU-fitting
  RESP traffic only.

## Test plan

Real DPDK numbers come from **AWS Nitro `c5n.18xlarge` (default) or
`c5n.metal` (escalation)** — both have 100 Gbps Elastic Network
Adapter (ENA) which has a supported DPDK PMD (`net_ena`). GitHub
Actions can compile but not exercise the DPDK path because no
runner has a DPDK-bindable NIC. The plan:

1. **PR gate**: `-Ddpdk=true` must compile cleanly on `ubuntu-latest`
   (linking against system DPDK). No execution.
2. **AWS perf lab**: when we land a working hello-world, spin up
   `c5n.18xlarge` (Nitro passes ENA through via SR-IOV → DPDK PMD
   sees the NIC directly), run `tools/dpdk/perf-bench.sh` with
   redis-benchmark, side-by-side against the io_uring path on the
   same box. Numbers go into `docs/benchmarks.md` next to the
   existing TCP/UDS tables. Tear down after each run; on-demand is
   ~$4/hr, spot is ~$1.5/hr.
3. **Why not metal**: `c5n.metal` is the same NIC and exposes
   identical DPDK semantics — keep it as an escalation option if
   we hit a Nitro virtualization edge (rare; we'd see it as missing
   IOMMU groups or VFIO permission errors).
4. **Why c5n specifically**: 100 Gbps ENA + 4× 25 GbE flows is the
   AWS-supported baseline for the ENA DPDK PMD. `c6in.32xlarge`
   (200 Gbps Ice Lake) and `c6gn.16xlarge` (100 Gbps Graviton) are
   alternatives once we've validated x86_64 c5n.
5. **Regression**: chaos suite (already in `tests/chaos/`) gets a
   `pipelined-large-response-dpdk.sh` variant that exercises the
   same race that produced 0.7.4's io_uring `send_scratch` fix.
6. **Provisioning**: a small `tools/dpdk/aws-perf-up.sh` will
   `aws ec2 run-instances` with the right AMI + user-data (hugepages,
   ENA → vfio-pci, DPDK install) so a perf run is one command.

## Risks

- **F-Stack binding cost** — could be days of small fights with C
  enums and macros. Acceptable; bounded.
- **NIC choice** — Mellanox ConnectX-4 LX (mlx5) and Intel X710
  (i40e) are the safest bets. Avoid anything where the PMD has
  known-broken support for the kernel version on the lab box.
- **Userspace TCP corner cases** — F-Stack's listen-fd → accept-fd
  semantics differ slightly from POSIX in ways that bit the Seastar
  team. Worth a half-day audit before we wire it into worker.zig.
- **Walking away** — if profiling shows the FFI overhead dominates,
  we may end up rolling our own TCP after all. The abstraction
  layer (next commit on this branch) is structured so that decision
  doesn't require touching the engines or the RESP layer.

## References

- DPDK programmer's guide: https://doc.dpdk.org/guides/prog_guide/
- F-Stack architecture: https://github.com/F-Stack/f-stack#architecture
- TLDK: https://github.com/intel/tldk
- Seastar's network stack (good reference, C++): https://github.com/scylladb/seastar
- VPP / vector packet processing for DPDK: https://fd.io/
- io_uring → DPDK migration writeup (ScyllaDB): https://www.scylladb.com/2018/09/17/scylla-replaces-seastar-network-stack/
