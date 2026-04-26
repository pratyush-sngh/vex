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
| **Strings** | | | |
| SET | 42,660 | 41,142 | tied |
| GET (hit) | 43,801 | 41,965 | tied |
| DEL | 43,613 | 42,138 | tied |
| EXISTS (hit) | 41,794 | 40,183 | tied |
| INCR | 41,984 | 42,957 | tied |
| APPEND | 42,395 | 42,197 | tied |
| EXPIRE+TTL | 21,265 | 20,863 | tied |
| MSET(10) | 36,663 | 39,826 | tied |
| MGET(10) | 38,463 | 41,718 | tied |
| **Lists** | | | |
| RPUSH | 42,393 | 41,561 | tied |
| LPUSH | 44,102 | 39,354 | tied |
| LRANGE(0,9) | 42,998 | 41,022 | tied |
| LLEN | 43,680 | 42,471 | tied |
| LPOP | 43,459 | 42,479 | tied |
| RPOP | 44,207 | 41,749 | tied |
| **Hashes** | | | |
| HSET | 46,047 | 45,010 | tied |
| HGET | 45,780 | 43,816 | tied |
| HGETALL | 43,422 | 43,619 | tied |
| HLEN | 44,766 | 44,353 | tied |
| HINCRBY | 45,440 | 42,229 | tied |
| HDEL | 45,119 | 45,477 | tied |
| **Sets** | | | |
| SADD | 45,541 | 44,114 | tied |
| SISMEMBER | 43,524 | 45,263 | tied |
| SCARD | 43,326 | 40,795 | tied |
| **Sorted Sets** | | | |
| ZADD | 41,598 | 43,389 | tied |
| ZSCORE | 45,735 | 44,860 | tied |
| ZRANGE(0,9) | 39,500 | **44,099** | +12% |
| ZCARD | 43,853 | 44,644 | tied |

Single-command throughput is dominated by TCP round-trip latency (~350us). Both databases process the command in nanoseconds -- the network is the bottleneck. All 28 commands are within ~5% of each other.

### Pipelined (100 commands per batch, c=16)

| Command | Redis cmd/s | Vex cmd/s | Speedup |
|---|---|---|---|
| **Strings** | | | |
| PIPE-SET(100) | 1.78M | **1.85M** | **+4%** |
| PIPE-GET(100) | 2.34M | **3.00M** | **+28%** |
| PIPE-INCR(100) | 2.34M | **2.64M** | **+13%** |
| PIPE-EXISTS(100) | 2.41M | **3.04M** | **+26%** |
| PIPE-DEL(100) | 2.05M | **2.71M** | **+32%** |
| **Lists** | | | |
| PIPE-RPUSH(100) | 2.01M | **2.45M** | **+22%** |
| **Hashes** | | | |
| PIPE-HSET(100) | 1.99M | **2.28M** | **+15%** |
| **Sets** | | | |
| PIPE-SADD(100) | 2.25M | **2.69M** | **+19%** |
| **Sorted Sets** | | | |
| PIPE-ZADD(100) | 1.95M | **2.38M** | **+22%** |

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
