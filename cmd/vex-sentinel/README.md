# vex-sentinel

Failover orchestrator for a vex cluster. Separate binary; lives outside the data plane so failover policy and split-brain prevention can evolve independently of the storage engine.

See [`docs/separation-of-concerns.md`](../docs/separation-of-concerns.md) for the rationale and [`docs/clustering.md#promotion`](../docs/clustering.md#promotion) for the wire-level protocol sentinel drives.

## Status

Scaffold. The pieces in place:

- `main.zig` — arg parsing, signal handling, wires the poller and HTTP server.
- `health.zig` — per-node poll state (PING/VEX.STATUS reply parsing lands in the next PR).
- `election.zig` — pure picker: given the health table, returns the node that should be promoted.
- `quorum.zig` — placeholder for multi-sentinel quorum.
- `state.zig` — atomic persistence of `(leader_node_id, epoch)` via `atomic_io.atomicWrite`.
- `http.zig` — `GET /leader` for client discovery.

What's missing: the control loop body in `main.zig` (snapshot health → detect dead leader → run election → send `VEX.PROMOTE` → save state → update `setLeader`). The vex side of `VEX.PROMOTE` also doesn't yet flip the in-process role; that's a separate follow-on.

## Shared modules

Sentinel reuses a handful of `vex` modules via `build.zig` module imports. No `common/` extraction — the surface is small enough that a third binary would be the right trigger.

| Import name | Source file | Used for |
|---|---|---|
| `vex_log` | `src/log.zig` | Logger + `Level` enum + `global` instance. Same logging surface as `vex`. |
| `vex_atomic_io` | `src/storage/atomic_io.zig` | `atomicWrite` for the state file (`sentinel.state`). |
| `vex_cluster_config` | `src/cluster/config.zig` | `ClusterConfig`, `ClusterNode`, `NodeRole`, `parse`, `parseString`. Stable contract — see the header comment in that file. |
| `vex_resp` | `src/server/resp.zig` | Reserved for the next health PR (parsing PING / VEX.STATUS replies). Not consumed today. |

## Build + run

```bash
zig build run-sentinel -- --cluster sentinel-cluster.conf --state sentinel.state --http-port 26380
```

Unit tests:

```bash
zig build test-sentinel
```

Cluster config format is identical to vex's — see [`docs/clustering.md`](../docs/clustering.md). A typical sentinel deployment points at the same file vex uses.
