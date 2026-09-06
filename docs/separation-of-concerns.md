# Separation of Concerns

[Back to README](../README.md) | [Architecture](architecture.md) | [Clustering](clustering.md) | [Observability](observability.md)

---

Vex follows a deliberate split between **data-plane** concerns (which live in the `vex` binary) and **control-plane** / **operational** concerns (which live outside it). This page is the canonical explainer for the architecture.

The TL;DR:

| Layer | What it does | Where it lives | When |
|---|---|---|---|
| **Data plane** | KV / graph / vector storage, RESP protocol, persistence, replication wire | `vex` binary (`src/`) — Zig | exists today |
| **Control plane** | Cluster orchestration, leader election, failover policy, client leader-discovery | `sentinel/` — Zig | planned (post-stability) |
| **Metrics export** | Prometheus scrape endpoint | external sidecar | `redis_exporter` works today; native via Zig Prom lib later |
| **Chaos & soak tests** | `kill -9` harness, network partition, slow disk, fill disk | `tests/chaos/` — bash/Python | SRE-owned |
| **Backup ship** | snapshot upload to S3/GCS, retention policy | external sidecar | not part of vex |

---

## Why split mechanism from policy?

The most important split is inside **cluster mode**. Vex implements the **mechanism** of replication — sending bytes between leader and follower, persisting an epoch, accepting promotion via an admin command — but does not implement the **policy** — *who* should be the leader, *when* to fail over, *how* to detect split-brain via quorum.

This matches how Redis split with Redis Sentinel, and how Postgres splits with Patroni / Stolon. It avoids two failure modes:

1. **Bundled orchestration breaks together.** When the consensus logic shares a process with the data-plane, a bug in either takes down both. Sentinel-style separation isolates them.
2. **Quorum on a small N is fragile.** Two followers timing out at the same heartbeat tick should not both promote. A dedicated coordinator with its own state machine handles this without races.

Concretely, the v0.8 plan removes vex's existing "follower self-promotes" path in favor of an externally-supplied epoch (see [Clustering](clustering.md) for the protocol details). Until `vex-sentinel` ships, operators must do failover manually via `VEX.PROMOTE <epoch>`.

---

## What stays in vex (data plane)

These cannot move out — they need direct access to per-request state:

- **All RESP command handling** (`src/command/`, `src/server/`)
- **In-memory storage**: KV, hash, list, set, sorted set (`src/engine/`)
- **Graph engine + vector store + HNSW** (`src/engine/graph/graph.zig`, `vector_store.zig`, `hnsw.zig`)
- **Persistence**: AOF, snapshots, atomic rename + fsync helpers (`src/storage/`)
- **Replication wire**: heartbeats, broadcast queues, ack frames, full-sync (`src/cluster/replication.zig`, `protocol.zig`)
- **Observability data capture**: per-command counters, SLOWLOG ring, LATENCY events, CLIENT LIST registry (`src/observability/`)
- **Per-request mechanism**: epoch validation, STOP-WRITE gate, output buffer limits, connection limits

Anything that needs to observe data at the moment it flows through the request path stays in vex. An external observer can't see fsync errors in real time; an external coordinator can't make per-request authorization decisions fast enough.

---

## What moves to `sentinel/` (control plane)

These can be external because they observe vex from outside via the RESP admin port + the new `VEX.STATUS` / `VEX.PROMOTE` commands:

- **Liveness monitoring**: poll each vex node every ~1s, mark dead after N consecutive failures
- **Leader election**: pick the next leader from the alive set, by priority + applied-seq
- **Epoch coordination**: increment + persist + push to the chosen leader via `VEX.PROMOTE`
- **Quorum across multiple sentinels** (v2): only act if a majority agrees the leader is dead
- **Client discovery**: HTTP `GET /leader` returns the current leader's addr+port

Same monorepo (`sentinel/`), separate binary, same toolchain (Zig). Shared code (RESP client, Logger, Config) lives in `src/` as named modules consumed by both targets.

See the [stability plan](https://github.com/pratyush-sngh/vex/blob/main/.claude/plans/cozy-riding-quail.md) for the work breakdown.

---

## What's a sidecar (external entirely)

These are well-trodden patterns from the Redis/Postgres ecosystems. Vex doesn't ship them; operators bring their own.

### `redis_exporter` (Prometheus metrics) — works **today**

Vex's `INFO` field names mirror Redis 7. Point an unmodified `redis_exporter` at vex and you get Prometheus metrics with no new code:

```bash
# Run alongside vex
redis_exporter -redis.addr=redis://vex-host:6380 -web.listen-address=:9121

# Then in prometheus.yml
scrape_configs:
  - job_name: vex
    static_configs:
      - targets: ['vex-host:9121']
```

Grafana dashboards designed for `redis_exporter` populate against vex with minor field-name fixups. See [Observability](observability.md) for the full surface.

A native `/metrics` endpoint via a Zig Prometheus library is on the roadmap but not the critical path — `redis_exporter` removes the urgency.

### Chaos / fault-injection tests (`tests/chaos/`)

Planned location: `tests/chaos/` in this repo. Bash + Python:

- `kill-and-restart.sh` — `kill -9` vex at random points during a workload, restart, validate no acked write is lost
- `slow-disk.sh` — `iotune` or similar, verify STOP-WRITE fires correctly
- `partition-leader.sh` — drop traffic to the leader, verify follower acks stall, sentinel-driven failover works
- `fill-disk.sh` — fill the filesystem, verify ENOSPC → `aof_last_write_status:err` and clients see `-MISCONF`

Zig isn't a good fit for chaos tests (verbose for subprocess orchestration). Bash/Python is the natural choice. SRE-owned.

### Log shipping (Vector / Fluentbit / promtail)

Vex's `log-format json` produces one `{"ts":...,"level":...,"msg":...}` line per event. Point any log shipper at the file:

```yaml
# vector.toml example
[sources.vex_logs]
type = "file"
include = ["/var/log/vex/*.log"]

[transforms.parse_json]
type = "remap"
inputs = ["vex_logs"]
source = '. = parse_json!(.message)'

[sinks.loki]
type = "loki"
inputs = ["parse_json"]
endpoint = "http://loki:3100"
```

No vex changes needed. Configure `log-file` and `log-format json` in `vex.conf` and you're done.

### Backup uploader (S3, GCS, restic)

Vex writes `vex.zdb` and `vex.aof` atomically. An external watcher uploads them on a schedule + retention policy. Not vex's job.

---

## Why all-Zig for the in-repo binaries?

The original sentinel plan flirted with Go because of `redis_exporter`'s precedent and Go's ergonomic concurrency. The decision landed on Zig instead:

1. **Same toolchain.** One build system, one CI, one release pipeline.
2. **Real code reuse.** RESP serializer (`src/protocol/resp.zig`), Logger (`src/log.zig`), Config (`src/config.zig`), atomic_io (`src/storage/atomic_io.zig`) — all consumed directly by `sentinel/` via build.zig modules. No FFI, no duplicate implementations.
3. **Single binary deployment per concern.** Operators get `vex` and `vex-sentinel` from the same release, same way.
4. **Ecosystem investment.** A Zig Prom library and a Zig HTTP server come out of this work, usable beyond vex.

Tax paid: ~1 week extra effort for `vex-sentinel` vs. a Go implementation (no mature Zig HTTP server or RESP client yet — we'll build them as part of `sentinel/`). Reasonable price for a unified stack.

The exception is chaos tests, which are throwaway subprocess orchestration scripts. Zig is overkill there.

---

## Monorepo layout (current and planned)

```
vex/
├── build.zig                    # builds vex; will add `sentinel` target next
├── build.zig.zon
├── src/                         # vex (the data-plane binary)
│   ├── main.zig
│   ├── server/                  # RESP, TLS, event loop, worker, accept
│   ├── engine/                  # KV (concurrent + plain), graph, vector, HNSW
│   ├── command/                 # dispatch + each command's impl
│   ├── cluster/                 # replication wire protocol, leader/follower
│   ├── storage/                 # snapshot, AOF, atomic_io
│   ├── observability/           # WorkerStats, cmd_table, event_stats, clients
│   ├── log.zig                  # Logger (text/JSON; file or stderr)
│   └── config.zig               # config file parser
├── sentinel/                    # NEW (planned): control plane in Zig
│   ├── main.zig                 # entry, poll loop
│   ├── health.zig               # PING + VEX.STATUS polling
│   ├── quorum.zig               # multi-sentinel agreement
│   ├── election.zig             # leader pick by priority + lag
│   ├── http.zig                 # GET /leader endpoint
│   └── state.zig                # persisted state via atomic_io
├── tests/chaos/                 # NEW (planned): bash/python chaos scripts
├── bench/                       # microbenchmarks
├── tools/                       # graph-bench, compare-client (KV)
├── scripts/                     # release, benchmark drivers
└── docs/                        # this directory
```

---

## How an operator deploys this

**Single-node** (no clustering): one `vex` binary, optional `redis_exporter` sidecar, log shipper of choice. Done.

**HA cluster (after `sentinel/` ships)**: N × `vex` (one per node, configured with `cluster.conf`), M × `vex-sentinel` (typically 3 or 5 for quorum), `redis_exporter` per node. Clients query a sentinel's `GET /leader` for the current writable address; reads can hit any vex.

**HA cluster today (without sentinel)**: N × `vex` configured with `cluster.conf`. Failover is manual — operator calls `VEX.PROMOTE <epoch>` on the chosen node when the leader fails. Not yet recommended for unattended production.

See [Clustering](clustering.md) for the protocol details and [Deployment](deployment.md) for production checklists.

---

## Open questions / not yet decided

- **`vex-sentinel` v1 = single sentinel or multi?** Plan calls for v1 single (similar to Redis Sentinel's evolution); multi-sentinel quorum is v2.
- **Native `/metrics` via Zig Prom lib — separate repo or in-repo `lib/`?** Probably separate repo so other Zig projects can consume it cleanly. Open.
- **Chaos harness — bash/Python or a small Zig-based runner?** Leaning bash/Python for verbosity reasons but worth revisiting.
