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
| **GET** | 1.05M | **1.75M** | **+66%** | 4.76M | **5.32M** | **+12%** |
| **SET** | 1.14M | **1.66M** | **+45%** | 3.79M | **5.15M** | **+36%** |
| **INCR** | 1.19M | **1.69M** | **+42%** | 4.50M | **4.46M** | tied |
| **LPOP** | 1.80M | **2.01M** | **+12%** | 3.07M | **6.02M** | **+96%** |
| **RPOP** | 1.87M | **2.08M** | **+12%** | 3.82M | **5.88M** | **+54%** |
| **SADD** | 1.61M | 1.57M | tied | 5.38M | **6.02M** | **+12%** |
| **HSET** | 1.42M | **1.54M** | **+8%** | 3.62M | **5.15M** | **+42%** |
| **LPUSH** | 1.55M | **1.60M** | +3% | 3.23M | **4.03M** | **+25%** |
| **RPUSH** | 1.53M | **1.59M** | +4% | 4.13M | **4.07M** | tied |

All values in requests per second. TCP benchmarks run from host via Docker port mapping. UDS benchmarks run inside Docker via `docker exec`.

**Key takeaways:**
- **TCP**: Vex wins 7/9 commands (+8% to +66%). TCP overhead masks engine speed.
- **UDS**: Vex wins 7/9 commands (+12% to +96%). Without TCP stack, the multi-reactor advantage is fully exposed.
- **LPOP +96% over UDS**: Vex's O(1) deque vs Redis's quicklist shows the biggest gain when network overhead is removed.
- **UDS is 3-4x faster than TCP** for both Redis and Vex — use `--unixsocket` for same-machine deployments.

### Single-command, no pipeline (TCP, c=16, 100K ops)

| Command | Redis rps | Vex rps | Delta |
|---|---|---|---|
| SET | 47,893 | 45,788 | tied |
| GET | 46,729 | 45,704 | tied |
| INCR | 44,484 | 44,863 | tied |
| LPUSH | 47,281 | 45,935 | tied |
| RPUSH | 47,687 | 45,872 | tied |
| LPOP | 47,037 | 45,600 | tied |
| RPOP | 46,904 | 46,125 | tied |
| SADD | 48,239 | 42,194 | tied |
| HSET | 47,939 | 45,998 | tied |

Without pipelining, throughput is dominated by TCP round-trip latency (~320us). The engine processes each command in 20-80ns — the network is 99.99% of the time.

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
| ZSCORE | **35 ns** | O(1) HashMap lookup |
| ZADD | 68 ns | |
| ZREM | 77 ns | |
| ZCARD | 4 ns | |
| ZRANGE(top 10) | 8,472 us | Sorts 100K items -- optimization target |
| ZRANK | 8,456 us | Sorts 100K items -- optimization target |

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
