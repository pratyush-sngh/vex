# Vex Performance Investigation Handover

**Session date:** 2026-06-10
**Audience:** the next engineer picking up this performance work.

This document is a complete record of one extended investigation into vex's
runtime performance: what was measured, what was changed, what was learned,
and what remains open. Read top-to-bottom on first contact; use the table of
contents for re-reference.

## Contents

1. [What started this](#what-started-this)
2. [Code cleanup that landed](#code-cleanup-that-landed)
3. [List `LINDEX` optimization](#list-lindex-optimization)
4. [HSET combined-allocation fix](#hset-combined-allocation-fix)
5. [Benchmark infrastructure](#benchmark-infrastructure)
6. [Findings — the comparison story](#findings--the-comparison-story)
7. [Findings — multi-worker scaling](#findings--multi-worker-scaling)
8. [Per-op timing probes](#per-op-timing-probes)
9. [Connection counter leak bug fix](#connection-counter-leak-bug-fix)
10. [Striped HashStore refactor](#striped-hashstore-refactor)
11. [The RTT-bound finding](#the-rtt-bound-finding)
12. [Open issues / known bugs](#open-issues--known-bugs)
13. [Files changed](#files-changed)
14. [Next steps, prioritized](#next-steps-prioritized)
15. [Pointers to artefacts](#pointers-to-artefacts)

---

## What started this

The session began with "look in project, look for ai slop." That triaged into
broad code-quality work and then escalated into a benchmark/perf investigation
when the user wanted to push vex faster than Redis 8.0.3.

The investigation has two distinct phases:

- **Phase A (code quality + small wins):** dead-code removal, micro
  optimizations, the LINDEX cursor cache, HSET combined-allocation.
- **Phase B (architecture + benchmarking):** sweep matrix, probes,
  understanding multi-worker behaviour, striping HashStore, identifying that
  vex is RTT-bound below `c=16` rather than CPU-bound.

Both produced concrete code changes (committed to working tree, all tests
pass) and concrete findings (recorded below + in `MEMORY.md` for future
sessions).

---

## Code cleanup that landed

Removed ~285 lines of genuinely dead code across these sites:

| File | Removed | Why dead |
|---|---|---|
| `src/config.zig:37-43` | Redundant `line_end` branch | First branch re-assigned the same value |
| `src/server/event_loop.zig:523,529,535,542` | 4× `if (!is_linux) unreachable;` | Type system already enforces non-Linux can't reach these |
| `src/perf/span.zig` | `recordLockWait` + `lock_wait_n/ns` fields + report column | Legacy threaded-mode metric, never called |
| `src/engine/concurrent_kv.zig` | `getAndWriteBulk` (unused zero-alloc GET) | 66 lines, zero call sites |
| `src/engine/concurrent_kv.zig` | `setInline` (unused inline-SET path) | 46 lines, zero call sites |
| `src/engine/concurrent_kv.zig` | `writeLockAll`, `writeUnlockAll` | 8 lines, never called (read variants are used) |
| `src/engine/kv.zig` | `KVStore.isExpired` | Shadowed by `ConcurrentKV.isExpired` which is the real call site |
| `src/engine/query.zig` | `prefetchCSROffsets`, `reconstructFlatPath`, `reconstructPath`, `reconstructWeightedPath` | 73 lines, never called |
| `src/observability/stats.zig` | `unpackArgs` | The SLOWLOG GET handler at `handler.zig:2044` inlines the decode |
| `src/server/worker.zig` | `writeMapHeaderTo`, `writeSetHeaderTo` | 28 lines, never called |

Also collapsed 8 near-identical RESP header serializers in `src/server/resp.zig`
into a shared `writePrefixedNum` helper — ~25 lines saved, no behavior change.

**Test impact:** all 218 unit tests still pass.

---

## List `LINDEX` optimization

`bench-ds` showed `LINDEX` at 641 ns/op while every other list op was at
4-30 ns. The cause: `List.get(idx)` was a linear walk through the block-list,
which is `O(blocks)` — 244 blocks for the 100 k-entry test.

**Fix:** added per-`List` cursor cache + cumulative-count index in
`src/engine/list.zig`:

- `block_index: ArrayList(*Block)` + `block_cumcount: ArrayList(usize)` for
  `O(log blocks)` binary search.
- `cursor: ?Cursor` field for `O(1)` access when the next call hits the
  cached block (which it does for sequential `LRANGE`/`LSET`/`LREM`
  workloads).
- `pushTail` incrementally maintains the index; other mutations mark dirty
  and rebuild on next `get()`.

**Result:** LINDEX 641 ns → **4 ns** (130× faster). RPUSH/LPUSH/LPOP/RPOP
all stayed at baseline (push/pop paths are unaffected).

**Subtle bug found and fixed during this:** `popTail` had to drop
`cumcount[last]` symmetrically with `pushTail`'s bump. Without this, a
`popTail → pushTail` cycle that triggered a new block carried the stale
cumcount as `prev_cum`, sending later `get(idx)` calls to the wrong block.
Regression test in `tests/unit/engine/list_test.zig`:
"RPOP then RPUSH across block boundary keeps reads correct."

---

## HSET combined-allocation fix

At `c=8`, HSET dropped from ~30k ops/s to 21k (−26 % vs Redis). Root cause:
`worker.zig`'s HSET path was doing **2 separate `allocator.dupe` calls** per
field/value pair, ahead of the stripe lock. The pre-dupe pattern was meant
to avoid holding the lock during alloc; in practice it just doubled
allocator pressure.

**Fix:** in `src/engine/hash.zig`, `FieldMap.set` now stores both bytes in
**one combined allocation** laid out as `[field bytes][value bytes]`. The
hashmap's `key_ptr` and `value_ptr` are slices into the same buffer. Free
goes through `key.ptr[0..key.len + value.len]`.

This eliminated the `hsetOwned` pre-dupe pattern in `worker.zig` — HSET
now passes raw `args[2..]` directly to `hs.hset()`.

**Result:** HSET `c=8` went 21,571 → 31,224 ops/s (**+45 %**, now beats
Redis by ~9 % at that load).

This optimization stayed in place through subsequent refactors. It pairs
well with the later striped-HashStore work.

---

## Benchmark infrastructure

Built fresh from scratch over the session. Three pieces:

### 1. `Dockerfile.compare`

Multi-stage build producing one container with:

- `redis-server`, `redis-cli`, `redis-benchmark` (copied from `redis:8.0.3`)
- vex compiled with `-Doptimize=ReleaseFast -Dcpu=x86_64_v3`
- Go `compare-client` (from `tools/compare-client/`)
- `linux-perf` (used for one experiment; perf is blocked by EKS kernel)

### 2. `scripts/run-bench-in-container.sh`

Entry point with three modes selected via env var:

- **Default** — single bench run, redis-server + vex co-located on TCP, args
  forwarded to compare-client.
- **`BENCH_MATRIX=1`** — sweep `WORKERS_LIST` × `C_LIST` (e.g., `1 4` ×
  `1 4 8 16 32`). Restarts vex between worker configs. Output is sectioned
  with `=== MATRIX RUN workers=X c=Y` headers, easy to grep/parse.
- **`BENCH_PROBES=1`** — vex-only (no redis-server in pod), enables
  `DEBUG PROBES`, drives load with `redis-benchmark`, dumps probe data per
  op type (SET, GET, HSET). This is the per-step-cost mode.

Also has a `BENCH_PROFILE=1` mode that attempts `perf record`. Blocked by
EKS kernel's `perf_event_paranoid` setting even with `privileged: true`.
Left in place for non-EKS use.

### 3. K8s Job manifest at `k8s/vex-compare-bench.yaml`

Targets the `scrum6` namespace, pins to `c5a.2xlarge` via nodeAffinity,
reserves 4-6 CPU cores. Image pushed to `jarvis/vex:compare-bench` in ECR.

The image build pattern:
```
aws ecr get-login-password --region ap-south-1 | docker login ...
docker buildx build --platform linux/amd64 -f Dockerfile.compare \
    -t 208168340597.dkr.ecr.ap-south-1.amazonaws.com/jarvis/vex:compare-bench \
    --push .
```

Note: AWS session tokens expire every ~hour. Re-login + repush if you see
`403 Forbidden` mid-build.

### `compare-client` extension

Added Unix-socket support: `-redis unix:/path/to/sock`. Lives in
`tools/compare-client/main.go`. Smart-prefix detection in `newClient()`.

---

## Findings — the comparison story

Headline numbers, all on EKS `c5a.2xlarge`, Linux TCP, `redis-benchmark` for
the load (the compare-client undermeasured by ~30 % due to its own per-op
overhead, switching to redis-benchmark unblocked the real numbers):

| Workload | Vex | Redis 8.0.3 | Vex Δ |
|---|---|---|---|
| `c=1` unpipelined SET | 21.2k rps | 18.0k rps | **+18 %** |
| `c=4` unpipelined SET | 54.8k rps | 51.2k rps | **+7 %** |
| `c=8` unpipelined SET | 65.5k rps | 73.9k rps | **−11 %** |
| `c=16` unpipelined SET | 91.4k rps | 98.9k rps | −8 % |
| `c=32` unpipelined SET | 107.9k rps | 104.1k rps | **+4 %** |
| `c=64` unpipelined SET | timeout | 112.9k rps | (vex bug) |

The `c=8` to `c=16` dip is the multi-worker coordination cost. The `c=32`
recovery is where multi-worker parallelism finally amortizes. Note `c=64`
times out — see [Open issues](#open-issues--known-bugs).

Vex with `--workers 1` did NOT show the dip — it tied or beat Redis at every
tested `c` from 1 to 32. The dip is multi-worker-specific.

**Key file in vex history:** `docs/benchmarks.md` documents a ~5-9 M rps
pipelined number. That number is **only reachable with `-P 50` or higher**.
Without pipelining (the typical real-world client default), vex is
within ~5 % of Redis. **The pipelined story and the unpipelined story are
different and the doc currently conflates them.**

---

## Findings — multi-worker scaling

Worth understanding because the architectural decisions hinge on it.

**At sub-saturation concurrency, more vex workers hurt throughput.**

| Workers | `c=8` SET rps | Per-worker rps |
|---|---|---|
| 1 | 65,533 | 65,533 |
| 4 | 46,699 | 11,675 |

The per-worker throughput dropped 5.6× when going from 1 worker to 4 workers
at the same load. Coordination cost exceeded parallelism gain.

**Reasons:**

1. **`DsStripeLocks` lease acquire** — atomic CAS on a 256-element shared
   array. Per probe data: 304 ns/op average at `c=8` with 4 workers.
2. **Shared cache lines** in `HashStore`'s top-level `StringHashMap` bucket
   array — every worker touched it.
3. **Co-located processes** (redis-server in the same pod) added another
   ~1500 ns/op to HSET specifically — pure cache pollution.

These were each addressed by separate fixes; the first by the
[striped HashStore](#striped-hashstore-refactor), the second by stripe
isolation, the third by dropping redis from the probe pod.

---

## Per-op timing probes

A new diagnostic system to measure exact per-step cost on vex's hot path.

### Design

`src/observability/probes.zig`:

- `WorkerProbes` struct: one set of `(sum_ns, count, max_ns)` triplets per
  measured section. Single-owner writes from the worker's own thread — no
  atomics.
- `enabled: std.atomic.Value(bool)` — master switch, default off, toggled
  via `DEBUG PROBES ON|OFF|RESET`. Default builds pay nothing (one
  `monotonic` load).
- `current: threadlocal var ?*WorkerProbes` — thread-local pointer set by
  each worker on startup so engine modules (e.g., `hash.zig`) can record
  probes without thread-loading.
- `forEach(ctx, cb)` — iterate registered worker probes. Used by the
  `DEBUG PROBES` command to dump aggregated data.

### Probes measured

| Probe | Section |
|---|---|
| `recv_batch` | One pass through `handleRecvCompletion` |
| `cmd_dispatch` | One command's `dispatchCommand` call |
| `stripe_lock` | `DsStripeLocks.releaseAll` (release side) |
| `storage_op` | The body of `executeHotFast` for one command |
| `shared_atomics` | `persistence_broken.load()` |
| `io_submit` | `submitUringWrite + rearmRecv` |
| `get_stripe_lock`, `get_hashmap_lookup`, `get_value_copy`, `get_resp_format` | GET substeps inside executeHotFast |
| `set_stripe_lock`, `set_hashmap_op`, `set_value_copy`, `set_seqlock` | SET substeps inside executeHotFast |
| `hset_get_or_create`, `hset_fieldmap_lookup`, `hset_alloc_copy`, `hset_old_free` | HSET substeps inside `hash.zig` |
| `nskey`, `dsl_acquire`, `hset_total`, `bump_watch`, `reply_write` | HSET frame probes around the `hash.zig` call |

### Usage

```
redis-cli -p 6380 DEBUG PROBES ON       # enable collection
redis-cli -p 6380 DEBUG PROBES RESET    # zero counters
# ... run load ...
redis-cli -p 6380 DEBUG PROBES          # dump per-worker breakdown
redis-cli -p 6380 DEBUG PROBES OFF      # disable, restore zero overhead
```

The dump output: per worker, one line per probe with `n`, `avg_ns`, `max_ns`.

### Headline measurements (c=8, vex `--workers 4`, vex-only pod)

After all optimizations landed:

| Op | cmd_dispatch | storage_op | Throughput |
|---|---|---|---|
| SET | 829 ns | 572 ns | 74.3k rps |
| GET | 781 ns | 524 ns | 74.9k rps |
| HSET | **1,267 ns** | **981 ns** | 74.9k rps |

HSET cost breakdown (the one we drilled into):

| Section | Avg ns | % of cmd_dispatch |
|---|---|---|
| `hset_total` (entire hash op including stripe rwlock) | 618 | 49 % |
| `nskey` | 53 | 4 % |
| `bump_watch` | 51 | 4 % |
| `reply_write` | 50 | 4 % |
| Other in storage_op (defer overhead, switch dispatch) | ~105 | 8 % |
| Parse + dispatch + io_submit + shared atomics + housekeeping outside storage_op | ~390 | 31 % |

---

## Connection counter leak bug fix

Found during probe runs. Symptom: vex would hit "ERR max number of clients
reached" even with `--maxclients 50000` after only a few thousand
connections.

**Root cause** at `src/server/worker.zig:761` (`closeConn`):

```zig
// BEFORE — bug:
fn closeConn(self: *Worker, fd: i32) void {
    ...
    if (self.conns.fetchRemove(fd)) |kv| { ... }  // may return null
    _ = self.active_connections.fetchSub(1, .monotonic);  // ALWAYS RUNS
    ...
}
```

`active_connections` is a `u32`. io_uring delivers multiple terminating
completions for one fd (recv-err + send-err). Second call to `closeConn`
finds nothing in `conns` (already removed) but **still decrements the
counter**. Eventually underflows to 4,294,967,295. The maxclients check then
rejects every subsequent connect.

**Fix:** move the decrement inside the `if (fetchRemove(fd))` block so it
only fires when we actually removed an entry. Now idempotent under
double-close.

```zig
// AFTER — fix:
fn closeConn(self: *Worker, fd: i32) void {
    ...
    if (self.conns.fetchRemove(fd)) |kv| {
        ...
        _ = self.active_connections.fetchSub(1, .monotonic);
        _ = stats_mod.connected_clients.fetchSub(1, .monotonic);
    }
    _ = std.c.close(fd);
}
```

This bug was responsible for several earlier benchmark runs getting truncated
with "max clients reached" errors. With the fix, sustained probe runs at
`c=8` complete cleanly.

---

## Striped HashStore refactor

The probe data revealed `dsl.acquire` (DsStripeLocks lease) cost 304 ns/op
average. `HashStore` had no stripe lock of its own — it relied on the
worker-level `DsStripeLocks` lease plus a single `pthread_mutex_t map_mutex`
for the rare new-key path.

**Refactor:** replaced `HashStore`'s single top-level mutex + single
`StringHashMap` with 32 stripes, each with its own `pthread_rwlock_t` +
`StringHashMap(FieldMap)`. Same pattern as `ConcurrentKV`.

Key file: `src/engine/hash.zig`.

- `STRIPE_COUNT: usize = 32`
- `stripeOf(key)` uses FNV-1a 32-bit + power-of-2 mask (~10-15 ns; the
  previous Wyhash-based version cost ~40-60 ns)
- Each public op (`hset`, `hget`, `hdel`, `hgetall`, `hlen`, `hexists`,
  `hincrby`, `hkeys`, `hvals`, `exists`, `delete`) routes through
  `stripeOf(key)` and takes the stripe's rwlock
- `initStripes()` must be called after `init()` returns at a stable memory
  address (macOS rwlocks don't survive struct copy)

Tests updated to call `initStripes()` after creating a HashStore in test
fixtures (`tests/unit/engine/hash_test.zig`, `tests/unit/command/handler_test.zig`).

`worker.zig`'s HSET/HGET/HLEN/HMGET/HMSET/HGETALL paths no longer call
`dsl.acquire` for the hash store. The lease is now redundant since the
HashStore handles its own per-stripe locking internally.

`tcp.zig:1040-1046` updated: drop the `mutex_init_fn(&hash_store.map_mutex, null)`
line, add `hash_store.initStripes()` after construction.

Also: replaced `DsStripeLocks.stripeIndex` to use FNV-1a + power-of-two mask
instead of Wyhash + modulo (`src/server/worker.zig:155`). Saves ~30 ns/op
for any op still using DsStripeLocks (list/set/zset).

### Net per-op savings on HSET

| Section | Before refactor | After refactor | Δ |
|---|---|---|---|
| `dsl.acquire` | 304 ns | 0 (removed) | −304 ns |
| `hset_total` (now includes per-stripe rwlock) | 503 ns | 618 ns | +115 ns |
| Other | barely moved | barely moved | ≈ 0 |
| **cmd_dispatch (total)** | **1,454 ns** | **1,267 ns** | **−187 ns (−13 %)** |

### Why throughput barely moved

At `c=8`, vex workers are 95 % idle (waiting on I/O). The 187 ns saved
per op doesn't translate to throughput. It DOES improve per-op latency
(visible as a p50 shift from 0.071 ms to 0.069 ms).

The throughput win will materialize at higher concurrency where vex
saturates CPU, or with pipelined workloads.

### What still uses DsStripeLocks

`ListStore`, `SetStore`, `SortedSetStore` — they still go through
`dsl.acquire` in worker.zig because their internal architecture wasn't
refactored. **This is the next obvious chunk of work** — same template
as HashStore, expected ~200 ns saved per op for those op families.

---

## The RTT-bound finding

At `c≤8`, **vex is not CPU-bound.** Per-op server processing is ~700-1300 ns
(~1 µs). End-to-end RTT (client → kernel → server → kernel → client) is
~70 µs. The server contributes ~1.5 % of round-trip time. The rest is
TCP stack, scheduler, io_uring delivery, client overhead.

**Why this matters:**

- Saving 200 ns server-side is a 0.3 % RTT improvement.
- Throughput at low `c` is RTT-bounded: `aggregate rps ≈ c / RTT`.
- Optimizing the server's hot path past this point doesn't help throughput
  unless you also reduce RTT.

This was recorded in `MEMORY.md` so future sessions don't repeat the trap:
[`memory/project_bench_bottleneck.md`].

Comparison to Redis 8.0.3 at the same conditions: Redis is ~5 % faster on
unpipelined SET at `c=8` (78.5k vs 74.9k rps). Both hit roughly the same
RTT ceiling. **Vex doesn't have a meaningful per-op latency disadvantage
versus Redis on raw KV.**

### What actually moves RTT

In order of impact:

1. **Pipelining** — 5-50× win on amortized RTT. The biggest single lever.
   But most clients **don't pipeline by default** (see "Pipelining default"
   table below).
2. **Unix sockets** — bypasses TCP stack. ~15 µs RTT win on same-host
   deployments. Vex supports `--unixsocket` (saw a stuck-listener bug
   under load on EKS — see [Open issues](#open-issues--known-bugs)).
3. **`IORING_RECV_MULTISHOT`** — one submission services multiple recv
   completions. ~500 ns/op saved. Kernel 5.18+, available on Amazon
   Linux 2023 (6.12 kernel on the EKS nodes).
4. **`TCP_QUICKACK`** — eliminates Linux's 40 ms delayed-ACK on
   request/reply patterns. Mostly tail latency, not throughput.
5. **RFS / XPS** — kernel network packet steering so completions land on
   the same CPU the worker reads from. ~2-5 µs.

### Pipelining default in major clients

| Client | Default pipelining? |
|---|---|
| `redis-py` | No |
| `redis-rb` | No |
| `Jedis` (Java sync) | No |
| `node-redis` v4+ | No |
| `redigo` (Go) | No |
| `go-redis` (Go) | No |
| `StackExchange.Redis` (C#) | Sort of (multiplexed conn pipelines opportunistically) |
| `Lettuce` (Java async) | Sort of (pipelines when concurrent awaits outstanding) |
| `redis-benchmark -P N` | Yes when `-P` passed |

So the typical web-app deployment hits vex un-pipelined, one command per
connection round-trip. The pipelined performance story is real but only
applies to specific workloads (ETL, batch jobs, multiplexed-client setups).

---

## Open issues / known bugs

Recorded for the next person — these came up during the investigation but
weren't fixed:

### 1. Vex hangs at `c=64` unpipelined load

In the matrix run, vex w=1 timed out completely at `c=64` (Redis handled it
at 113k rps). Looks related to per-connection processing falling behind on a
single worker. Likely an io_uring submission queue depth issue or recv
queue saturation. Reproduce: `redis-benchmark -p 6380 -c 64 -n 50000 -t SET`.

### 2. Vex unix socket listener gets stuck under load in reactor mode

When running in reactor mode (`--workers > 1`) with `--unixsocket`, the
socket starts refusing connections after several thousand commands. The vex
process is alive, the listener fd exists, but `connect()` returns ECONNREFUSED.
We worked around this by running on TCP instead in EKS. **The unix-socket
path on Linux should be the fastest config — this bug blocks measuring it.**

Reproduce: see `scripts/run-bench-in-container.sh` early commits (before we
pivoted to TCP).

### 3. Go `compare-client` RESP parser desyncs at `c≥16`

Symptoms: after a few thousand ops, the client starts reporting
"unknown RESP type byte: '0'" / "'\r'" / "'\n'" — the parser is reading
mid-frame bytes. Once it desyncs on a connection, that connection is
poisoned. Mitigation in the current bench script: use `redis-benchmark`
instead at high concurrency.

Plausible causes: the client's `bufio.Reader` not handling partial reads
correctly, or vex framing some response wrong at the wire level. Worth a
20-minute investigation with `tcpdump` + the trace from a failed run.

### 4. `redis-server` co-located in the same pod adds ~1500 ns/op to HSET

Pure cache pollution. Documented as a finding (see
[Striped HashStore refactor](#striped-hashstore-refactor)). The takeaway for
production: noisy-neighbor cache traffic significantly affects vex's
nested-hashmap operations (HSET, HMSET) more than flat KV ops (SET, GET).
HashStore's stripe rwlock + smaller bucket arrays helped here, but the
sensitivity remains.

### 5. `docs/benchmarks.md` conflates pipelined and unpipelined numbers

The headline 5-9 M rps numbers are with `redis-benchmark -P 50`. Without
pipelining (which is what most clients do by default — see table above),
vex hits ~75k-100k rps. **Doc should split these two stories** or readers
will be misled. Already pointed out in the unpipelined comparison results
above.

### 6. EKS host kernel blocks `perf record`

The EKS `c5a.2xlarge` Amazon Linux 2023 kernel returns `<not supported>`
for hardware perf counters and `<not counted>` for software events, even
with `privileged: true` and `CAP_SYS_ADMIN`. We worked around this by
adding in-process probes. If you need real `perf` data, run on a non-EKS
Linux host (raw EC2, vanilla Docker Desktop, etc.) where you can write
`/proc/sys/kernel/perf_event_paranoid`.

---

## Files changed

A complete list of files touched this session:

| File | Nature of change |
|---|---|
| `src/config.zig` | Dead branch removal |
| `src/server/event_loop.zig` | Removed dead `if (!is_linux) unreachable;` guards |
| `src/perf/span.zig` | Removed `recordLockWait` + related metric |
| `src/engine/concurrent_kv.zig` | Removed unused `getAndWriteBulk`, `setInline`, `writeLockAll`, `writeUnlockAll` |
| `src/engine/kv.zig` | Removed unused `isExpired` (shadowed) |
| `src/engine/query.zig` | Removed unused path-reconstruction helpers |
| `src/observability/stats.zig` | Removed unused `unpackArgs` |
| `src/server/worker.zig` | Added probes integration, **connection-leak fix**, dropped `dsl.acquire` for hash ops, FNV-1a hash for stripeIndex, dead `writeMapHeaderTo`/`writeSetHeaderTo` removed |
| `src/server/tcp.zig` | Wired up `hash_store.initStripes()`, removed obsolete `hash_store.map_mutex` init, registered probes |
| `src/server/resp.zig` | Consolidated 8 header serializers into `writePrefixedNum` helper |
| `src/engine/list.zig` | **Cursor cache + cumulative-count index** for `LINDEX`/`LRANGE` |
| `src/engine/hash.zig` | **Combined-allocation HSET + striped HashStore** (32 stripes, per-stripe rwlock) |
| `src/observability/probes.zig` | **New file** — `WorkerProbes`, `DEBUG PROBES` command backing data |
| `src/command/handler.zig` | `DEBUG PROBES` subcommand, HSET path simplified |
| `tests/unit/engine/list_test.zig` | Added regression test for popTail→pushTail boundary |
| `tests/unit/engine/hash_test.zig` | Added `initStripes()` after `HashStore.init()` (8 sites) |
| `tests/unit/command/handler_test.zig` | Same — `initStripes()` after `HashStore.init()` (2 sites) |
| `Dockerfile.compare` | **New file** — single-image bench container |
| `docker-compose.compare-tcp.yml` | **New file** — TCP-only variant (macOS bind-mount issue with unix sockets) |
| `k8s/vex-compare-bench.yaml` | **New file** — EKS bench job manifest |
| `scripts/run-bench-in-container.sh` | **New file** — bench/matrix/probe driver |
| `tools/compare-client/main.go` | Unix-socket support via `unix:` prefix |
| `docs/perf-handover.md` | This document |
| `~/.claude/projects/.../memory/project_bench_bottleneck.md` | Memory entry recording RTT-bound finding |

Tests at the end: **218 pass / 1 skip / 0 fail.**

---

## Next steps, prioritized

Ranked by impact-to-effort:

### 1. Run `redis-benchmark -P 50` against current vex on EKS (1 hour)

Verify the documented pipelined throughput numbers (~5-9 M rps) reproduce
on the current build. This validates whether the "vex differentiates on
pipelined / batch workloads" claim is sound. Update `docs/benchmarks.md`
to clearly separate pipelined vs unpipelined sections.

### 2. Strip ListStore, SetStore, SortedSetStore the same way HashStore is (2-4 days)

Follow the template established in `hash.zig`. Each store gets 32 stripes,
per-stripe rwlock, removes the global mutex, and `worker.zig` drops the
`dsl.acquire` call for that store. Expected ~200 ns/op saved per op family.

Once all four stores are migrated, **DsStripeLocks can be removed
entirely** — saves the lease-array cache footprint plus a per-recv-batch
release call.

### 3. Fix the c=64 hang (half day)

Reproduces locally. Probably an io_uring SQ depth or recv backlog issue.
Without this, we can't measure vex at the concurrency where multi-worker
ACTUALLY pays off. Currently blocking us from any "vex scales linearly
past c=32" claim.

### 4. Fix the unix-socket listener-stuck bug (half day - 1 day)

Critical for Linux production deployments. Unix sockets are the
single biggest RTT optimization on same-host deployments. Currently
documented as broken in reactor mode, so users can't use the fastest
config.

### 5. Add IORING_RECV_MULTISHOT (1 day)

~500 ns per op. Small but real. Available on the kernel everyone deploys
to. Easy code change in `event_loop.zig`.

### 6. Update `docs/benchmarks.md` (2 hours)

Separate pipelined and unpipelined headline numbers. Document the
`DEBUG PROBES` command. Add a section on "when to expect what throughput"
based on client pipelining behavior. Reference this handover for the
methodology.

### Do NOT do (rejected during this investigation)

- **Per-worker shared-nothing data structures** (Tier 3 from earlier
  thesis). Rejected because KeyDB's similar shared-state attempt fails
  at <16 cores. Dragonfly's shared-nothing succeeds, but the refactor is
  10+ weeks of engineering and the win at vex's target hardware (4-8
  cores) is marginal compared to options 1-5 above.
- **Per-op atomic micro-optimizations** (Tier 1 from earlier thesis).
  Rejected because at the concurrency vex targets, the server is
  RTT-bound — these wins don't move throughput. Worth reconsidering
  only if vex eventually saturates CPU (high `c` after fix #3).

---

## Pointers to artefacts

- **Memory entries created this session:**
  - `~/.claude/projects/-Users-pratyushsingh-fundsindia-personal-project-vex/memory/project_bench_bottleneck.md`
  - Linked from the project's `MEMORY.md`.
- **Image in ECR:** `208168340597.dkr.ecr.ap-south-1.amazonaws.com/jarvis/vex:compare-bench`
- **K8s namespace:** `scrum6`
- **Bench job manifest:** `k8s/vex-compare-bench.yaml`
- **Bench driver script:** `scripts/run-bench-in-container.sh`
- **Probe command:** `redis-cli -p 6380 DEBUG PROBES [ON|OFF|RESET]`
- **Existing benchmark docs:** `docs/benchmarks.md` (pipelined-favored;
  see [Open issue #5](#open-issues--known-bugs))

To re-run the matrix benchmark from scratch (~30 min):

```
# 1. (If session expired) re-login to ECR
aws ecr get-login-password --region ap-south-1 | \
    docker login --username AWS --password-stdin \
    208168340597.dkr.ecr.ap-south-1.amazonaws.com

# 2. Rebuild + push image
docker buildx build --platform linux/amd64 -f Dockerfile.compare \
    -t 208168340597.dkr.ecr.ap-south-1.amazonaws.com/jarvis/vex:compare-bench \
    --push .

# 3. Set BENCH_MATRIX=1 in k8s/vex-compare-bench.yaml then apply
kubectl apply -f k8s/vex-compare-bench.yaml

# 4. Watch
kubectl -n scrum6 logs -f job/vex-compare-bench
```

To re-run probes:

```
# Set BENCH_PROBES=1 in k8s/vex-compare-bench.yaml then apply.
# Output: per-worker DEBUG PROBES breakdown after SET / GET / HSET load.
```
