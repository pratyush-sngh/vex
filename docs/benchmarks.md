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
| **SADD** | 1.14M | **1.76M** | **+55%** | 5.49M | **6.41M** | **+17%** |
| **LPOP** | 1.35M | **2.08M** | **+55%** | 3.45M | **6.17M** | **+79%** |
| **RPOP** | 1.43M | **2.07M** | **+46%** | 4.17M | **5.95M** | **+43%** |
| **RPUSH** | 1.24M | **1.74M** | **+41%** | 4.81M | **5.49M** | **+14%** |
| **LPUSH** | 1.35M | **1.72M** | **+28%** | 3.60M | **5.21M** | **+45%** |
| **GET** | 1.37M | **1.79M** | **+31%** | 4.90M | **7.04M** | **+44%** |
| **HSET** | 1.08M | **1.55M** | **+43%** | 3.68M | **5.95M** | **+62%** |
| **SET** | 1.56M | **1.76M** | **+13%** | 3.88M | **6.25M** | **+61%** |
| **INCR** | 1.61M | **1.74M** | **+8%** | 4.59M | **6.41M** | **+40%** |

All values in requests per second (median of 15 runs). TCP benchmarks run from host via Docker port mapping. UDS benchmarks run inside Docker via `docker exec`. Sorted by TCP speedup.

**Key takeaways:**
- **TCP**: Vex faster on 9/9 commands (+8% to +55%). SADD and LPOP show the biggest TCP gains.
- **UDS**: Vex faster on 9/9 commands (+14% to +79%). Native int INCR eliminated Redis's last UDS win.
- **LPOP +79% over UDS**: Vex's O(1) deque vs Redis's quicklist — biggest gain when network overhead is removed.
- **GET 7.04M rps over UDS** — 44% faster than Redis. Parallel read locks + pre-sized buffers.
- **INCR +40% over UDS**: Native i64 storage — no string parse/format on each increment.
- **UDS is 2-4x faster than TCP** for both Redis and Vex — use `--unixsocket` for same-machine deployments.

### Single-command, no pipeline (TCP, c=16, 100K ops)

| Command | Redis rps | Vex rps | Δ |
|---|---|---|---|
| SET | 47,893 | 45,788 | -4% |
| GET | 46,729 | 45,704 | -2% |
| INCR | 44,484 | 44,863 | +1% |
| LPUSH | 47,281 | 45,935 | -3% |
| RPUSH | 47,687 | 45,872 | -4% |
| LPOP | 47,037 | 45,600 | -3% |
| RPOP | 46,904 | 46,125 | -2% |
| SADD | **48,239** | 42,194 | **-13%** |
| HSET | 47,939 | 45,998 | -4% |

Without pipelining, throughput is dominated by TCP round-trip latency (~320us). The engine processes each command in 20-80ns — the network is 99.99% of the time. Redis is slightly faster on most single commands because its single-threaded event loop has lower per-request overhead. Vex's multi-reactor advantage shows under concurrent pipelined load (+8% to +55% TCP, +14% to +79% UDS).

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

### Lists (`zig build bench-ds -Doptimize=ReleaseFast`)

| Operation | Latency | Notes |
|---|---|---|
| RPUSH | **34 ns** | O(1) deque append |
| LPUSH | **26 ns** | O(1) deque prepend |
| LPOP | **19 ns** | O(1) amortized |
| RPOP | **14 ns** | O(1) amortized |
| LLEN | 4 ns | |
| LINDEX | 4 ns | O(1) deque index |

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

# TCP benchmarks (from host)
redis-benchmark -h 127.0.0.1 -p 16379 -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset --csv
redis-benchmark -h 127.0.0.1 -p 16380 -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset --csv

# UDS benchmarks (inside Docker — host can't access container sockets on macOS)
docker exec redis-compare redis-benchmark -s /socks/redis.sock \
  -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset --csv
docker exec redis-compare redis-benchmark -s /socks/vex.sock \
  -c 16 -n 500000 -P 50 -q \
  -t set,get,incr,lpush,rpush,lpop,rpop,sadd,hset --csv

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
| Two-stack deque | O(1) LPUSH/LPOP (+96% vs Redis UDS) |
| Hot-path dispatch | Lists/hashes/sets bypass global mutex |
| Unix Domain Sockets | 3-4x faster than TCP for local connections |
| Bidirectional BFS | sqrt(N) explored vs N for shortest path |
| CSR adjacency | Cache-friendly graph traversal |
| Zero-copy RESP parse | No memcpy for complete commands |
| Comptime dispatch | O(1) command routing |
| AOF group commit | 1 write() per tick instead of per command |
| Tombstone DEL | 25ns flag vs 140ns full remove |
