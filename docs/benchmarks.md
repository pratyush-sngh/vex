# Benchmarks

[Back to README](../README.md) | [Architecture](architecture.md)

---

## Methodology

All network benchmarks use **`redis-benchmark`** (the industry-standard Redis benchmarking tool, v8.0.3). Internal engine benchmarks use Zig-native timing with no network overhead.

- **Environment**: Docker containers on macOS (Apple Silicon, 14 cores / 48GB RAM)
- **Isolation**: Each container gets **4 dedicated CPU cores** (`cpuset`) and **4GB RAM** (`mem_limit`), with no overlap between competitors
- **Vex workers**: Capped at 4 (`--workers 4`) to match the 4-core allocation
- **Redis config**: `--appendonly no --save ""` (persistence disabled, same as Vex `--no-persistence`)
- **Versions**: Redis 8.0.3, Memgraph latest, Vex built with `-Doptimize=ReleaseFast`
- **Tool**: `redis-benchmark` (ships with Redis) for network benchmarks, `zig build bench-kv` / `bench-ds` for engine benchmarks
- **UDS benchmarks**: `redis-benchmark` runs inside the Docker container via `docker exec`, connecting over a shared Unix socket volume

### Docker Compose Resource Pinning

```yaml
redis:
  cpuset: "0-3"      # 4 cores
  mem_limit: 4g
  command: ["redis-server", "--unixsocket", "/socks/redis.sock", "--unixsocketperm", "777"]
vex:
  cpuset: "4-7"      # 4 cores (no overlap)
  mem_limit: 4g
  command: ["--reactor", "--workers", "4", "--unixsocket", "/socks/vex.sock"]
```

---

## Vex vs Redis 8.0 (`redis-benchmark`, P=50, c=16)

### All commands — TCP and UDS side by side

| Command | Redis TCP | Vex TCP | TCP Δ | Redis UDS | Vex UDS | UDS Δ |
|---|---|---|---|---|---|---|
| **LPUSH** | 971K | **1.38M** | **+42%** | 3.01M | **4.10M** | **+36%** |
| **RPUSH** | 1.08M | **1.33M** | **+24%** | 3.79M | **4.17M** | **+10%** |
| **SADD** | 1.19M | **1.42M** | **+19%** | 4.13M | **6.85M** | **+66%** |
| **MSET** | 491K | **583K** | **+19%** | 668K | **1.84M** | **+175%** |
| **LPOP** | 1.46M | **1.72M** | **+18%** | 5.88M | **7.25M** | **+23%** |
| **ZADD** | 1.07M | **1.25M** | **+16%** | 3.27M | **5.49M** | **+68%** |
| **HSET** | 1.03M | **1.19M** | **+16%** | 3.33M | **4.63M** | **+39%** |
| **SET** | 1.16M | **1.31M** | **+13%** | 3.57M | **3.91M** | **+9%** |
| **INCR** | 1.17M | **1.31M** | **+13%** | 4.10M | **6.49M** | **+58%** |
| **LRANGE_100** | 184K | **202K** | **+10%** | 273K | **316K** | **+16%** |
| **GET** | 1.28M | **1.39M** | **+9%** | 5.81M | **7.35M** | **+27%** |
| **RPOP** | 1.60M | **1.74M** | **+9%** | 5.95M | **7.35M** | **+24%** |
| **LRANGE_300** | 69.3K | **71.4K** | **+3%** | **77.2K** | 76.8K | -1% |

All values in requests per second (median of 15 runs). FLUSHALL between runs. TCP benchmarks run from host via Docker port mapping. UDS benchmarks run inside Docker via `docker exec`. Sorted by TCP speedup.

**Key takeaways:**
- **TCP**: Vex faster on **13/13 commands** (+3% to +42%). Every TCP command is faster.
- **UDS**: Vex faster on **12/13 commands** (+9% to +175%). Only LRANGE_300 is tied (-1%).
- **LPOP 7.25M / RPOP 7.35M rps over UDS** — +23%/+24% faster than Redis. Atomic spinlocks (~10ns) replaced pthread_rwlock (~100-200ns).
- **MSET +175% over UDS**: Bulk key-value writes benefit from multi-reactor parallelism.
- **SADD +66% / ZADD +68% over UDS**: Atomic spinlocks + pre-allocated HashMaps.
- **INCR +58% over UDS**: Native i64 storage — no string parse/format on each increment.
- **GET 7.35M rps over UDS** — 27% faster than Redis. Lock-free SeqLock reads + pre-sized buffers.
- **LRANGE_100 +16% UDS**: O(1) offset ring buffer eliminates linear scan within quicklist blocks.
- **UDS is 2-4x faster than TCP** for both Redis and Vex — use `--unixsocket` for same-machine deployments.

---

## Internal Engine Benchmarks (no network)

Pure engine speed, measured in Zig with `clock_gettime(MONOTONIC)`. 100K operations per benchmark, `ReleaseFast` optimization.

### KV Strings (`zig build bench-kv -Doptimize=ReleaseFast`)

| Operation | Latency |
|---|---|
| GET (hit) | **22 ns** |
| EXISTS | 19 ns |
| SET (insert) | 71 ns |
| SET (update) | 66 ns |
| DEL (tombstone) | 32 ns |
| SET (reuse tombstone) | 42 ns |

### Lists — Quicklist (`zig build bench-ds -Doptimize=ReleaseFast`)

| Operation | Latency | Notes |
|---|---|---|
| RPUSH | **34 ns** | O(1) append to tail block |
| LPUSH | **26 ns** | O(1) prepend to head block |
| LPOP | **19 ns** | O(1) pop from head block |
| RPOP | **14 ns** | O(1) trailer-based reverse pop |
| LLEN | 4 ns | |
| LINDEX | varies | O(blocks) — scan through block chain |

### Hashes

| Operation | Latency |
|---|---|
| HGET | **28 ns** |
| HSET | 87 ns |
| HDEL | 51 ns |
| HLEN | 3 ns |

### Sets

| Operation | Latency |
|---|---|
| SISMEMBER | **24 ns** |
| SADD | 52 ns |
| SREM | 32 ns |
| SCARD | 3 ns |

### Sorted Sets

| Operation | Latency | Notes |
|---|---|---|
| ZSCORE | **68 ns** | O(1) HashMap lookup |
| ZADD | 143 ns | |
| ZREM | 37 ns | |
| ZCARD | 3 ns | |
| ZRANGE(top 10) | **8.8 us** | Lazy sorted cache (was 8,472 us — 963x faster) |
| ZRANK | **0.5 us** | Lazy sorted cache (was 8,456 us — 16,912x faster) |

### Graph Engine (50K nodes / 500K edges)

| Operation | Latency |
|---|---|
| BFS Traverse (depth 4) | 64 us |
| Shortest Path | 146 us |
| Neighbors | <0.1 us |
| Memory | 19 MB (4.3x less than naive) |

---

## Graph: Vex vs Memgraph (Docker, 10K nodes / 50K edges)

| Operation | Memgraph | Vex | Speedup |
|---|---|---|---|
| AddNode | 175.4 us | **138.1 us** | **+21%** |
| AddEdge | 185.9 us | **140.5 us** | **+24%** |
| BFS Traverse (depth 3) | 334 us | **228 us** | **+32%** |
| Shortest Path | 4,524 us | **210 us** | **22x faster** |
| Neighbors | 202 us | **130 us** | **+36%** |

Vex wins all 5 operations. Shortest path uses bidirectional BFS (meet-in-the-middle), which explores ~sqrt(N) nodes instead of N.

---

## How to Reproduce

```bash
# Start containers (equal resources: 4 cores, 4GB each, UDS enabled)
docker compose -f docker-compose.compare.yml up --build -d

# Automated benchmark (15 runs, median, FLUSHALL between runs)
./tools/bench.sh 15

# Or manually — TCP benchmarks (from host)
redis-benchmark -h 127.0.0.1 -p 16379 -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,zadd,mset,lrange_100 --csv
redis-benchmark -h 127.0.0.1 -p 16380 -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,zadd,mset,lrange_100 --csv

# UDS benchmarks (inside Docker — host can't access container sockets on macOS)
docker exec redis-compare redis-benchmark -s /socks/redis.sock \
  -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,zadd,mset,lrange_100 --csv
docker exec redis-compare redis-benchmark -s /socks/vex.sock \
  -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,zadd,mset,lrange_100 --csv

docker compose -f docker-compose.compare.yml down -v

# Graph: Vex vs Memgraph
docker compose -f docker-compose.graph-bench.yml up --build -d
cd tools/graph-bench
go run . -nodes 10000 -edges 5 -depth 3 -runs 5 -timeout 120s
docker compose -f docker-compose.graph-bench.yml down -v

# Internal engine benchmarks (no network)
zig build bench-kv -Doptimize=ReleaseFast
zig build bench-ds -Doptimize=ReleaseFast
```

**Important**: Stop all unrelated Docker containers before benchmarking. Background containers competing for CPU will skew results.

---

## Why Vex is Faster

See [Architecture](architecture.md) for detailed explanation. Summary:

| Optimization | Impact |
|---|---|
| 256-stripe atomic spinlock | ~10ns CAS vs ~100-200ns pthread_rwlock |
| Prealloc outside lock | Lock held ~20ns (pointer swap only) |
| Cache-line aligned stripes | No false sharing between cores |
| Cached clock | Skip clock_gettime per GET |
| Quicklist (8KB blocks) | O(1) LPUSH/RPUSH/LPOP/RPOP with trailer-based reverse scan, O(1) LINDEX via offset ring buffer |
| Hot-path dispatch | Lists/hashes/sets bypass global mutex |
| Unix Domain Sockets | 3-4x faster than TCP for local connections |
| Bidirectional BFS | sqrt(N) explored vs N for shortest path |
| CSR adjacency | Cache-friendly graph traversal |
| Zero-copy RESP parse | No memcpy for complete commands |
| Comptime dispatch | O(1) command routing |
| AOF group commit | 1 write() per tick instead of per command |
| Tombstone DEL | 25ns flag vs 140ns full remove |
