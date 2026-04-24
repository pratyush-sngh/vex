# Benchmarks

[Back to README](../README.md) | [Architecture](architecture.md)

---

## Methodology

All benchmarks run under controlled, reproducible conditions:

- **Environment**: Docker containers on macOS (Apple Silicon, 14 cores / 48GB RAM)
- **Isolation**: Each container gets **4 dedicated CPU cores** (`cpuset`) and **4GB RAM** (`mem_limit`), with no overlap between competitors
- **Vex workers**: Capped at 4 (`--workers 4`) to match the 4-core allocation
- **Redis config**: `--appendonly no --save ""` (persistence disabled, same as Vex `--no-persistence`)
- **Versions**: Redis 8.0.3, Memgraph latest, Vex built with `-Doptimize=ReleaseFast`
- **Runs**: Median of 5 runs, 1000 warmup ops discarded before measurement
- **Client**: Go benchmark tool running on the host (not containerized), connecting via Docker port mapping

### Docker Compose Resource Pinning

```yaml
# KV benchmark (docker-compose.compare.yml)
redis:
  cpuset: "0-3"      # 4 cores
  mem_limit: 4g
vex:
  cpuset: "4-7"      # 4 cores (no overlap)
  mem_limit: 4g
  command: ["--reactor", "--workers", "4"]

# Graph benchmark (docker-compose.graph-bench.yml)
memgraph:
  cpuset: "0-3"
  mem_limit: 4g
vex:
  cpuset: "4-7"
  mem_limit: 4g
  command: ["--reactor", "--workers", "4"]
```

This ensures neither container can steal CPU time from the other. Redis is single-threaded, so 3 of its 4 cores go unused -- this is intentional to keep the comparison fair (same hardware budget, architectural choices determine throughput).

---

## KV: Vex vs Redis 8.0 (all commands, c=16)

### Single-command (no pipeline)

| Command | Redis ops/s | Vex ops/s | Delta |
|---|---|---|---|
| SET | 42,185 | 40,805 | tied |
| GET (hit) | 43,195 | 41,132 | tied |
| DEL | 43,796 | 42,308 | tied |
| EXISTS (hit) | 42,877 | 40,183 | tied |
| INCR | 43,632 | 41,529 | tied |
| APPEND | 44,008 | 42,083 | tied |
| EXPIRE+TTL | 21,756 | 21,358 | tied |
| MSET(10) | 41,502 | 41,150 | tied |
| MGET(10) | 41,794 | 41,460 | tied |

Single-command throughput is dominated by TCP round-trip latency (~370us). Both databases process the command in nanoseconds -- the network is the bottleneck.

### Pipelined (100 commands per batch, c=16)

| Command | Redis cmd/s | Vex cmd/s | Speedup |
|---|---|---|---|
| PIPE-SET(100) | 1.14M | **2.40M** | **+111%** |
| PIPE-GET(100) | 1.54M | **3.02M** | **+96%** |
| PIPE-INCR(100) | 1.55M | **2.61M** | **+69%** |
| PIPE-EXISTS(100) | 1.57M | **3.08M** | **+96%** |
| PIPE-DEL(100) | 1.20M | **2.67M** | **+123%** |

Pipelining amortizes network overhead, exposing the engine's raw throughput. Vex's multi-reactor workers process batches in parallel across 4 cores while Redis serializes everything on one thread.

### Pipeline scaling (c=1, single connection)

| Pipeline | Redis cmd/s | Vex cmd/s | Delta |
|---|---|---|---|
| p=1 | **7,188** | 7,176 | tied |
| p=10 | 67,500 | **73,200** | +8% |
| p=50 | 251,000 | **261,000** | +4% |
| p=100 | 442,000 | **491,000** | +11% |

At c=1, both are bottlenecked by TCP round-trip latency. The multi-reactor advantage only shows with concurrent connections.

---

## Graph: Vex vs Memgraph (Docker, 10K nodes / 50K edges)

| Operation | Memgraph | Vex | Speedup |
|---|---|---|---|
| AddNode | 175.4 us | **138.1 us** | **+21%** |
| AddEdge | 185.9 us | **140.5 us** | **+24%** |
| BFS Traverse (depth 3) | 334 us | **228 us** | **+32%** |
| Shortest Path | 4,524 us | **210 us** | **22x faster** |
| Neighbors | 202 us | **130 us** | **+36%** |

Vex wins all 5 operations. Shortest path uses bidirectional BFS (meet-in-the-middle), which explores ~sqrt(N) nodes instead of N -- dramatically faster than Memgraph's standard BFS.

---

## Internal Engine Benchmarks (no network)

**KV engine** (100K ops):

| Operation | Latency |
|---|---|
| GET (hit) | 24 ns |
| SET (insert) | 66 ns |
| DEL (tombstone) | 35 ns |

**Graph engine** (50K nodes / 500K edges):

| Operation | Latency |
|---|---|
| BFS Traverse (depth 4) | 64 us |
| Shortest Path | 146 us |
| Neighbors | <0.1 us |
| Memory | 19 MB (4.3x less than naive) |

---

## How to Reproduce

```bash
# KV: Vex vs Redis (Docker, all commands + pipelined)
docker compose -f docker-compose.compare.yml up --build -d
cd tools/compare-client
go run . -n 3000 -c 16 -warmup 1000 -runs 5 -timeout 60s -pipeline 100
docker compose -f docker-compose.compare.yml down -v

# KV: Pipeline scaling (c=1)
go run . -n 5000 -c 1 -warmup 1000 -runs 3 -timeout 30s -pipeline 100

# KV: High concurrency
go run . -n 3000 -c 32 -warmup 1000 -runs 5 -timeout 60s -pipeline 50

# Graph: Vex vs Memgraph (Docker)
docker compose -f docker-compose.graph-bench.yml up --build -d
cd tools/graph-bench
go run . -nodes 10000 -edges 5 -depth 3 -runs 5 -timeout 120s
docker compose -f docker-compose.graph-bench.yml down -v

# Internal engine benchmarks
zig build bench-kv -Doptimize=ReleaseFast
```

**Important**: Stop all unrelated Docker containers before benchmarking. Background containers competing for CPU will skew results (especially for the pipelined tests where throughput is CPU-bound).

---

## Why Vex is Faster

See [Architecture](architecture.md) for detailed explanation. Summary:

| Optimization | Impact |
|---|---|
| 256-stripe rwlock | Parallel GETs across workers |
| Prealloc outside lock | Lock held ~20ns (pointer swap only) |
| Cache-line aligned stripes | No false sharing between cores |
| Cached clock | Skip clock_gettime per GET |
| Bidirectional BFS | sqrt(N) explored vs N for shortest path |
| CSR adjacency | Cache-friendly traversal |
| Zero-copy RESP parse | No memcpy for complete commands |
| Comptime dispatch | O(1) command routing |
| AOF group commit | 1 write() per tick instead of per command |
| Tombstone DEL | 25ns flag vs 140ns full remove |
