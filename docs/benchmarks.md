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
| **MSET** | 354K | **559K** | **+58%** | 663K | **1.63M** | **+146%** |
| **ZADD** | 873K | **1.22M** | **+39%** | 3.25M | **4.90M** | **+51%** |
| **SET** | 1.02M | **1.32M** | **+29%** | 3.57M | **4.67M** | **+31%** |
| **RPUSH** | 1.05M | **1.35M** | **+28%** | 3.91M | **4.76M** | **+22%** |
| **SADD** | 1.14M | **1.41M** | **+24%** | 4.13M | **6.49M** | **+57%** |
| **INCR** | 1.10M | **1.36M** | **+23%** | 4.13M | **6.67M** | **+61%** |
| **LRANGE_100** | 167K | **197K** | **+18%** | 275K | **316K** | **+15%** |
| **HSET** | 1.03M | **1.19M** | **+16%** | 3.47M | **4.39M** | **+26%** |
| **LPUSH** | 1.16M | **1.34M** | **+15%** | 2.96M | **4.31M** | **+46%** |
| **LPOP** | 1.46M | **1.67M** | **+15%** | **5.88M** | 3.60M | -39% |
| **RPOP** | 1.59M | **1.72M** | **+9%** | **5.95M** | 3.62M | -39% |
| **GET** | 1.25M | **1.32M** | **+5%** | 5.75M | **7.46M** | **+30%** |
| **LRANGE_300** | 70.2K | **71.9K** | **+2%** | **77.1K** | 76.1K | -1% |

All values in requests per second (median of 15 runs). FLUSHALL between runs. TCP benchmarks run from host via Docker port mapping. UDS benchmarks run inside Docker via `docker exec`. Sorted by TCP speedup.

**Key takeaways:**
- **TCP**: Vex faster on **13/13 commands** (+2% to +58%). Every TCP command is faster.
- **UDS**: Vex faster on 10/13 commands (+15% to +146%). MSET +146% over UDS is the standout.
- **GET 7.46M rps over UDS** — 30% faster than Redis. Lock-free SeqLock reads + pre-sized buffers.
- **INCR +61% over UDS**: Native i64 storage — no string parse/format on each increment.
- **ZADD +39% TCP / +51% UDS**: Lazy sorted cache + O(1) HashMap score lookup.
- **LRANGE_100 +18% TCP / +15% UDS**: O(1) offset ring buffer eliminates linear scan within quicklist blocks.
- **LPOP/RPOP -39% UDS**: Multi-reactor lock overhead shows under zero-network UDS. TCP hides this (+15%/+9%).
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
| 256-stripe rwlock | Parallel GETs across workers |
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
