yes# Plan: Profiling-first performance (vs Redis compare benchmark)

- **Status**: Accepted — **execution pending agent mode** (Cursor rejected switching out of plan-only mode; non-markdown edits are blocked until Agent mode is enabled)
- **Date**: 2026-04-15
- **Goal**: Identify **actual** latency contributors before large refactors; then optimize in order of measured impact toward **Zigraph p95 ≤ 0.8 × Redis p95** on the existing compare workload (see README / `scripts/run-compare-benchmark.sh`), with **p99 + throughput** as guardrails.

## Why this plan exists

The Go compare client measures **end-to-end RTT** only. It cannot attribute time to parse vs KV vs graph vs AOF vs socket write. Prior hypotheses (single-writer, AOF batching) remain **candidates** until span and CPU evidence rank them.

## Phase A — Instrumentation (no behavior change in release defaults)

### A1. Server-side span histograms (primary breakdown)

- **Where**: [`src/server/tcp.zig`](../../src/server/tcp.zig) around `processOneCommand`, plus hooks in [`src/storage/aof.zig`](../../src/storage/aof.zig) (`logCommand` / `writeRecord`), and optionally coarse splits inside [`src/command/handler.zig`](../../src/command/handler.zig) (e.g. KV vs `GRAPH.*`).
- **How**: gated by env or CLI flag (e.g. `ZIGRAPH_PROFILE=1` or `--profile`), use monotonic ns timestamps; aggregate **count + sum + percentiles** per span bucket in memory; periodic dump (stderr or `INFO`-like output) to avoid per-command logging overhead when disabled.
- **Spans (initial set)**:
  - `parse_resp` (parser + building arg slices)
  - `execute_total`
  - `aof_write` (include sub-markers if needed: `length`, `seek`, `flush` if still separate calls)
  - `serialize_response`
  - `socket_write`
  - optional: `mutex_wait` if we can measure cheaply without distorting hot path (may defer)

### A2. CPU profiling (secondary, confirms cycles)

- Run compare workload with **Linux `perf record -g`** inside the zigraph container (or host-attached to container PID), alongside the Go client matrix.
- Keep one “golden” command mix for reproducibility.

### A3. Allocation / memcpy duplication lens (tertiary)

- Dev-only **counting allocator** wrapper or allocation counters around RESP parse and KV `setInternal` paths ([`src/server/resp.zig`](../../src/server/resp.zig), [`src/engine/kv.zig`](../../src/engine/kv.zig)).
- Report allocs / bytes copied **per command class** (`SET`, `GET`, `DEL`, graph ops).

## Phase B — Benchmark harness improvements (fairness + SLO guardrails)

Update [`tools/compare-client/main.go`](../../tools/compare-client/main.go) and [`scripts/run-compare-benchmark.sh`](../../scripts/run-compare-benchmark.sh):

- **Warmup** (discarded samples)
- **p99** + **throughput** (ops/s) alongside p95
- **Repeat runs** (e.g. 3×) report median
- Optional **swap order** (Redis vs Zigraph first) to reduce ordering bias

## Phase C — Optimization backlog (ordered only after A ranks bottlenecks)

Candidate work items (pick based on evidence, not upfront):

1. **AOF**: remove per-command `length` + `seekTo` EOF + `flush` if traces show `aof_write` dominates; document durability window if batching/group commit is introduced ([`src/storage/aof.zig`](../../src/storage/aof.zig)).
2. **Receive buffer / RESP**: reduce `copyForwards` shifts ([`src/server/tcp.zig`](../../src/server/tcp.zig)); reduce `dupe` churn ([`src/server/resp.zig`](../../src/server/resp.zig)) where lifetimes allow.
3. **Execution model**: if mutex/wait dominates at high `-c`, move to **single-writer reactor** (Redis-like) or other architecture; if parse/alloc dominates, prefer micro-structural fixes first.
4. **Graph queries**: fix obvious algorithmic tails in [`src/engine/query.zig`](../../src/engine/query.zig) (e.g. `orderedRemove(0)` BFS dequeue) when graph read paths matter.

## Verification loop

```text
run compare matrix → collect spans + perf + alloc report → pick top 1–2 contributors
→ implement smallest change → re-run matrix → stop when p95 gate met without p99/regression
```

## References (high-perf DB patterns checklist)

Use as a menu after measurement, not as default implementation:

- WAL **group commit** / append buffering (tail latency)
- Single-writer execution + non-blocking IO (Redis-style)
- LSM / compaction (only if measurement shows on-disk structure is the bottleneck)
- Arena/bump allocation for request-scoped work (if alloc churn dominates)

## Out of scope (until evidence says otherwise)

- Rewriting storage engine to LSM “because big DBs use it”
- Sharding / multi-node (covered separately in ADR 0001)

---

## Execution checklist (when Agent mode is enabled)

### A1 — Zigraph server spans

1. Add [`src/perf/span.zig`](../../src/perf/span.zig) with:
   - `Profile` struct holding `std.Io` + `report_every` + atomics for: `parse_ns/n`, `locked_ns/n` (mutex + `execute` + `writeAll`), `aof_ns/n`.
   - `monotonicNs(t0, t1)` using `t0.durationTo(t1).raw.toNanoseconds()` (same pattern as [`src/bench/persistence_bench.zig`](../../src/bench/persistence_bench.zig)).
   - `recordLocked` increments command count; every `report_every` commands call `std.debug.print` with **avg microseconds** per span (cheap; no per-op logging when disabled).
2. [`src/main.zig`](../../src/main.zig): parse `--profile` and `--profile-every <u64>` (default every when profile on, e.g. `100_000`); stack-allocate `Profile`, pass `?*Profile` into `Server.init` and set `aof_instance.prof = ptr`.
3. [`src/server/tcp.zig`](../../src/server/tcp.zig): extend `Server` / `ClientCtx` / `processOneCommand`:
   - **RESP path**: timestamp before `parser.parse`, after args built → `recordParse`.
   - Timestamp around `pthread_mutex_lock` … `execute` … `writeAll` → `recordLocked`.
   - **Inline path**: same around `parseInlineCommand` + locked section.
4. [`src/storage/aof.zig`](../../src/storage/aof.zig): optional `prof: ?*Profile`; in `writeRecord`, measure full record write → `recordAofWrite`.
5. [`src/main.zig`](../../src/main.zig) tests root: `@import("perf/span.zig")`.

### A2 — `perf` script (optional doc-only or small script)

- Add `scripts/profile-zigraph-perf.sh`: `docker exec` into `zigraph-compare` with `perf record -g -p 1` pattern **or** document manual steps in README (if `perf` unavailable in slim image, note host-attach).

### A3 — Allocation lens (follow-up PR)

- Wrap allocator or add counters in `resp.parse` / `kv.setInternal` after spans show need.

### B — Go compare client

[`tools/compare-client/main.go`](../../tools/compare-client/main.go):

- Flags: `-warmup`, `-runs`, `-zigraph-first` (swap Redis/Zigraph order for KV section).
- Extend `summarize` with **p99**; pass **wall ms** + `n` into summarize for **ops/s** (`n * 1000 / wallMs`).
- `printScenario` prints p99 + throughput.
- Warmup: run each scenario’s workload `warmup` times without recording (or discard samples).

[`scripts/run-compare-benchmark.sh`](../../scripts/run-compare-benchmark.sh):

- Pass e.g. `-warmup 500 -runs 3` and optionally `-zigraph-first`.

[`README.md`](../../README.md): document new flags and `--profile` / `--profile-every` for zigraph.
