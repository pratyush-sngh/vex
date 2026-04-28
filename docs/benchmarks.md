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
| **LPUSH** | 1.02M | **1.27M** | **+24%** | 3.03M | **7.94M** | **+162%** |
| **HSET** | 879K | **1.12M** | **+27%** | 3.49M | **8.11M** | **+132%** |
| **RPUSH** | 1.05M | **1.34M** | **+27%** | 3.90M | **8.57M** | **+120%** |
| **ZADD** | 891K | **1.18M** | **+32%** | 3.33M | **6.98M** | **+109%** |
| **SADD** | 1.12M | **1.34M** | **+20%** | 4.17M | **7.50M** | **+79%** |
| **INCR** | 958K | **1.31M** | **+37%** | 4.13M | **6.17M** | **+49%** |
| **SET** | 1.08M | **1.22M** | **+13%** | 3.62M | **4.59M** | **+27%** |
| **GET** | 1.15M | **1.34M** | **+17%** | 5.68M | **7.14M** | **+26%** |
| **MSET** | 385K | **518K** | **+34%** | 663K | **1.95M** | **+193%** |
| **LPOP** | 1.52M | **1.64M** | **+8%** | 6.00M | **6.82M** | **+13%** |
| **RPOP** | 1.54M | **1.65M** | **+7%** | 6.00M | **7.32M** | **+22%** |

All values in requests per second. TCP from host, UDS inside Docker via `docker exec`. Sorted by UDS speedup.

**Key takeaways:**
- **TCP**: Vex faster on **11/11 commands** (+7% to +37%).
- **UDS**: Vex faster on **11/11 commands** (+13% to +162%). UDS shows true engine speed without network overhead.
- **LPUSH +162% UDS** (7.94M rps): Stripe lease locks hold across pipeline — 1 CAS per batch instead of 50.
- **HSET +132% UDS** (8.11M rps): Pre-alloc outside lock + lease batching.
- **RPUSH +120% UDS** (8.57M rps): Quicklist O(1) push + lease fast path.
- **ZADD +109% UDS** (6.98M rps): Lazy sorted cache + lease batching.
- **At P=100 c=32 UDS**: ZADD +236%, LPUSH +224%, HSET +178%, SADD +159%.
- **UDS is 2-6x faster than TCP** for both Redis and Vex — use `--unixsocket` for same-machine deployments.

### UDS scaling across pipeline depth and concurrency

| Command | P=50 c=16 | P=50 c=32 | P=100 c=16 | P=100 c=32 | P=50 c=128 |
|---|---|---|---|---|---|
| LPUSH | **+153%** | **+166%** | **+224%** | **+224%** | **+159%** |
| HSET | **+132%** | **+127%** | **+196%** | **+178%** | **+156%** |
| RPUSH | **+120%** | **+100%** | **+146%** | **+130%** | **+108%** |
| ZADD | **+109%** | **+107%** | **+196%** | **+236%** | **+109%** |
| SADD | **+79%** | **+76%** | **+153%** | **+159%** | **+74%** |
| INCR | **+57%** | **+52%** | **+88%** | **+103%** | **+51%** |
| SET | **+26%** | **+20%** | **+33%** | **+29%** | **+43%** |
| GET | **+21%** | **+15%** | **+55%** | **+57%** | **+18%** |
| RPOP | **+21%** | **+15%** | **+36%** | **+42%** | **+7%** |
| LPOP | **+13%** | **+9%** | **+48%** | **+53%** | **+9%** |

50/50 wins across all configurations. Performance scales with pipeline depth — deeper pipelines amortize the lease lock CAS across more commands.

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
| Stripe lease locks | Hold-one-release-on-switch: 1 CAS per pipeline batch instead of per command |
| TTAS spinlock | Load-before-CAS reduces cache line bouncing under contention |
| Quicklist (8KB blocks) | O(1) push/pop with trailers, lazy ring buffer rebuild for LINDEX |
| Encapsulated CKV alloc | Zero ownership transfer — CKV allocates internally, inline for small values |
| Pre-alloc outside lock | HSET/SADD: heap alloc before lock acquire, pointer swap under lock |
| Unix Domain Sockets | 3-4x faster than TCP for local connections |
| Bidirectional BFS | sqrt(N) explored vs N for shortest path |
| CSR adjacency | Cache-friendly graph traversal |
| Zero-copy RESP parse | No memcpy for complete commands |
| Comptime dispatch | O(1) command routing |
| AOF group commit | 1 write() per tick instead of per command |
| Tombstone DEL | 25ns flag vs 140ns full remove |
