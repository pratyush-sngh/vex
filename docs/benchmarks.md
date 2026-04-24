# Benchmarks

[Back to README](../README.md) | [Architecture](architecture.md)

---

## KV: Vex vs Redis 8.0 (Docker)

Real Redis clients pipeline commands. This is where Vex's multi-core architecture shines:

| Benchmark | Redis | Vex | Speedup |
|---|---|---|---|
| PIPE-SET(100) c=16 | 1.18M cmd/s | **2.25M cmd/s** | **+91%** |
| PIPE-GET(50) c=32 | 1.45M cmd/s | **2.46M cmd/s** | **+70%** |
| PIPE-GET(100) c=16 | 1.52M cmd/s | **2.96M cmd/s** | **+96%** |

Single-command (no pipeline):

| Concurrency | Vex SET | Redis SET | Vex GET | Redis GET |
|---|---|---|---|---|
| c=1 | **7,223** (+19%) | 6,064 | **7,079** (+6%) | 6,679 |
| c=10 | 28,676 | **29,615** | **30,601** (+1%) | 30,221 |
| c=32 | 49,080 | **53,707** | **50,266** (+3%) | 48,824 |

Pipeline scaling (c=1, single connection):

| Pipeline | Redis cmd/s | Vex cmd/s |
|---|---|---|
| p=1 | **7,104** | 5,775 |
| p=10 | 64,800 | **65,681** |
| p=50 | 277,345 | **288,415** |
| p=100 | 468,300 | **505,450** |

Vex wins at any pipeline size >= 10. Real applications always pipeline.

---

## Graph: Vex vs Memgraph (Docker, 10K nodes / 50K edges)

| Operation | Memgraph | Vex | Speedup |
|---|---|---|---|
| AddNode | 180 us | **139 us** | **+23%** |
| AddEdge | 197 us | **145 us** | **+26%** |
| BFS Traverse (depth 3) | **313 us** | 326 us | ~tied |
| Shortest Path | 4,838 us | **210 us** | **Vex 23x faster** |
| Neighbors | 233 us | **154 us** | **+34%** |

Vex wins or ties all 5 operations. Shortest path uses bidirectional BFS (meet-in-the-middle), which is dramatically faster than Memgraph's standard BFS.

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

## How to Run Benchmarks

```bash
# KV: Vex vs Redis (Docker, pipelined)
docker compose -f docker-compose.compare.yml up --build -d
cd tools/compare-client
go run . -n 2000 -c 16 -warmup 500 -runs 5 -timeout 60s -pipeline 100
docker compose -f docker-compose.compare.yml down -v

# KV: Standard benchmark (no pipeline)
go run . -n 20000 -c 32 -warmup 3000 -runs 5 -timeout 30s

# Graph: Vex vs Memgraph (Docker)
docker compose -f docker-compose.graph-bench.yml up --build -d
cd tools/graph-bench
go run . -nodes 10000 -edges 5 -depth 3 -runs 5 -timeout 120s
docker compose -f docker-compose.graph-bench.yml down -v

# Internal engine benchmarks
zig build bench-kv -Doptimize=ReleaseFast
```

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
