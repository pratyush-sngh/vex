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

Reproduced via `./tools/bench.sh 15` — runs the standard `redis-benchmark`
matrix 15 times per command and reports the **median** rps.

### All commands — TCP and UDS side by side

| Command | Redis TCP | Vex TCP | TCP Δ | Redis UDS | Vex UDS | UDS Δ |
|---|---|---|---|---|---|---|
| **LPUSH** | 1.33M | **2.01M** | **+51%** | 3.42M | **8.20M** | **+139%** |
| **ZADD** | 1.18M | **1.78M** | **+51%** | 3.68M | **8.20M** | **+123%** |
| **RPUSH** | 1.66M | **1.93M** | **+16%** | 4.39M | **9.09M** | **+107%** |
| **HSET** | 1.57M | **1.75M** | **+11%** | 3.91M | **7.94M** | **+103%** |
| **SADD** | 1.42M | **1.97M** | **+39%** | 4.67M | **8.47M** | **+81%** |
| **INCR** | 1.75M | **2.00M** | **+14%** | 4.85M | **8.33M** | **+72%** |
| **RPOP** | 2.37M | **2.46M** | **+4%** | 7.14M | **10.20M** | **+43%** |
| **LPOP** | 1.97M | **2.42M** | **+23%** | 7.14M | **9.43M** | **+32%** |
| **GET** | 1.71M | **2.00M** | **+17%** | 7.25M | **9.43M** | **+30%** |
| **SET** | 1.62M | **1.95M** | **+20%** | 4.20M | **4.24M** | **+1%** |
| **LRANGE_100** | 167K | **191K** | **+14%** | 290K | **327K** | **+13%** |
| **MSET** | 565K | 564K | ≈ | 715K | 681K | -5% |

All values in requests per second. TCP from host, UDS inside the
container via `docker exec`. Sorted by UDS speedup (descending).
Median of 15 runs, P=50, c=16, n=500,000 per run.

**Key takeaways:**
- **TCP**: Vex faster on **11 of 12** commands (+4% to +51%); MSET tied.
- **UDS**: Vex faster on **11 of 12** commands (+1% to +139%); MSET -5%.
  UDS strips out network framing and shows the engine's true ceiling.
- **LPUSH +139% UDS** (8.20M rps): stripe lease locks hold across the
  pipeline — 1 CAS per batch instead of 50.
- **ZADD +123% UDS** (8.20M rps): lazy sorted cache + lease batching.
- **RPUSH +107% UDS** (9.09M rps): quicklist O(1) push + lease fast path.
- **HSET +103% UDS** (7.94M rps): pre-alloc outside lock + lease batching.
- **UDS is 2-6× faster than TCP** for both Redis and Vex — prefer
  `--unixsocket` for same-machine deployments.
- **MSET is the lone soft spot.** Vex's hot-path MSET takes the
  per-stripe rdlock added in 0.7.3 (B3) — fine for safety, costly here
  where the pipeline is bottlenecked on lock acquires rather than work.
  Fix path: skip the rdlock for stripes the writer can already prove are
  not under rehash. Tracked as a 0.7.x perf TODO.

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

Pure engine speed, measured in Zig with `clock_gettime(MONOTONIC)`. 100K operations per benchmark, `ReleaseFast` optimization. Numbers are median of 5 runs.

### KV Strings (`zig build bench-kv -Doptimize=ReleaseFast`)

| Operation | Latency |
|---|---|
| GET (miss) | **4.5 ns** |
| EXISTS | 22.5 ns |
| DEL (tombstone) | 32.6 ns |
| SET (reuse tombstone) | 40.6 ns |
| GET (hit) | 42.1 ns |
| SET (insert) | 70.1 ns |
| SET (update) | 83.5 ns |
| Compact (50k entries) | 1.29 ms |

GET (hit) is slightly slower than pre-0.7.3 (22 ns → 42 ns) because the
hot-path GET now acquires the stripe `rdlock` to be safe against
concurrent rehash (B3 fix in 0.7.3). The cost is one uncontended
`pthread_rwlock_rdlock`/`unlock` round.

### Lists — Quicklist (`zig build bench-ds -Doptimize=ReleaseFast`)

| Operation | Latency | Notes |
|---|---|---|
| LLEN | **3.9 ns** | |
| LPOP | **4.7 ns** | O(1) pop from head block |
| RPOP | **4.7 ns** | O(1) trailer-based reverse pop |
| LPUSH | 20.5 ns | O(1) prepend to head block |
| RPUSH | 38.0 ns | O(1) append to tail block |
| LINDEX | 619.7 ns | O(blocks) — scan through block chain |

### Hashes

| Operation | Latency |
|---|---|
| HLEN | **3.8 ns** |
| HGET | 28.6 ns |
| HDEL | 46.9 ns |
| HSET | 80.7 ns |

### Sets

| Operation | Latency |
|---|---|
| SCARD | **3.7 ns** |
| SISMEMBER | 24.9 ns |
| SREM | 34.0 ns |
| SADD | 54.2 ns |

### Sorted Sets

| Operation | Latency | Notes |
|---|---|---|
| ZCARD | **3.8 ns** | |
| ZSCORE | 25.6 ns | O(1) HashMap lookup |
| ZREM | 37.8 ns | |
| ZADD | 69.4 ns | |
| ZRANK | **0.5 us** | Lazy sorted cache |
| ZRANGE(top 10) | **9.3 us** | Lazy sorted cache, 100K-member set |

### Persistence (`zig build bench-persistence -Doptimize=ReleaseFast`)

Measured on a 50,000-key KV store with 10,000-node / 20,000-edge graph
plus per-entity properties. Each test runs warmup=1 + timed=5 iterations
and reports the mean.

| Operation | Latency (mean) | Notes |
|---|---|---|
| snapshot.save | **14.4 ms** | Whole-state RDB-style file write |
| snapshot.load | **8.7 ms** | Whole-state restore from RDB |
| aof.append(SET) | **1.36 us/op** | Per-command AOF buffer append |
| aof.replay | **0.02 us/op** | Per-command replay during startup |

### Graph Engine (`zig build bench-graph -Doptimize=ReleaseFast`, 50K nodes / 500K edges / 5 props each)

| Operation | Latency | Notes |
|---|---|---|
| Neighbors | **52.6 ns** | CSR O(1) lookup |
| ADDNODE | 61.4 ns | |
| ADDEDGE | 67.1 ns | |
| SETPROP | 83.1 ns | O(1) HashMap + per-entity index |
| GETNODE | 174.1 ns | O(1) countProps + O(k) collectAll |
| BFS Traverse (depth 4) | **4.3 us** | avg 95 nodes visited |
| Shortest Path | **32.3 us** | Bidirectional BFS |
| Weighted Path | 162.4 us | Bidirectional Dijkstra (flat arrays) |

### Contraction Hierarchies (`bench-graph`, 100-node random graph)

| Metric | Value | Notes |
|---|---|---|
| Dijkstra (bidir) | 4.4 us/op | Flat-array bidirectional Dijkstra |
| **CH Query** | **1.2 us/op** | Reusable query engine, touched-list reset |
| **Speedup** | **3.7×** | CH vs bidirectional Dijkstra |

CH preprocesses the graph into a hierarchy of shortcuts. Queries search only upward in rank from both endpoints. Speedup grows with graph size and path length — road networks with millions of nodes see 100-1000×.

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

## perf-v3 Optimizations (branch: perf-v3)

### AOF Persistence: Async vs Sync (`redis-benchmark`, P=16 and P=1)

| Benchmark | main (sync AOF) | perf-v3 (async AOF) | Δ |
|---|---|---|---|
| **SET P=16** | 722K | **808K** | **+12%** |
| **GET P=16** | 649K | **797K** | **+23%** |
| **SET P=1** | 20.7K | **53.5K** | **+158%** |
| **GET P=1** | 37.6K | **49.7K** | **+32%** |

io_uring linked write→fsync chain keeps the worker thread unblocked during AOF flushes. 2.5x SET throughput at P=1 — the biggest win.

### MGET Bulk Fetch (100 keys, `redis-benchmark`)

| Pipeline | Throughput | Notes |
|---|---|---|
| P=1 | 46K rps | Real CKV lookups with SeqLock reads |
| P=16 | 352K rps | Staging buffer: 1 memcpy vs 300 appendSlice |
| P=32 | 467K rps | |
| P=64 | 505K rps | |
| P=128 | 491K rps | TCP saturation limit |

MGET was broken in reactor mode on main (returned nil — read from empty plain KVStore). Now correctly routes through ConcurrentKV.

### Graph Traversal — RESP Serialization + LIMIT

| Operation (x200) | main | perf-v3 | Δ |
|---|---|---|---|
| TRAVERSE depth=5 | 113ms | 104ms | -8% |
| **TRAVERSE depth=10** | **2185ms** | **1158ms** | **-47%** |
| **TRAVERSE d=10 LIMIT 100** | **2244ms** | **145ms** | **-94%** |
| PATH | 101ms | 44ms | **-56%** |

`bufPrint` replaces `w.print` format engine in all RESP serialization. Batch response buffer for TRAVERSE. `GRAPH.TRAVERSE ... LIMIT N` for early BFS exit (p99: 222ms → 2.8ms).

### What Changed (perf-v3)

| Optimization | Impact |
|---|---|
| io_uring recv/send | Replace poll+syscall with async completions for TCP I/O |
| IORING_SETUP_SQPOLL | Kernel poll thread eliminates submit syscalls |
| Async AOF write+fsync | io_uring linked SQE chain, worker stays unblocked |
| O_DIRECT for AOF | Bypass page cache, page-aligned staging buffer |
| Per-worker AOF shards | Eliminate cross-worker mutex contention |
| RESP bufPrint | Replace format engine with bufPrint in all serialization |
| MGET hot path | ConcurrentKV bulk lookup with staging buffer |
| MSET hot path | ConcurrentKV batch write |
| CommandHandler CKV routing | All KV commands work in reactor mode (was broken) |
| CKV inline delete fix | Don't free inline_buf pointers (not heap-allocated) |
| TRAVERSE LIMIT | Early BFS exit, caps serialization cost |
| Parallel HNSW rebuild | Per-field threads at startup |
| Parallel BFS frontier | Thread-local bitsets, merge with OR |

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
zig build bench-graph -Doptimize=ReleaseFast
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
| Flat-array Dijkstra | O(1) indexed dist/parent vs HashMap overhead |
| Contraction Hierarchies | Preprocessed shortcut overlay, 3x faster weighted path queries |
| CSR adjacency | Cache-friendly graph traversal |
| Zero-copy RESP parse | No memcpy for complete commands |
| Comptime dispatch | O(1) command routing |
| AOF group commit | 1 write() per tick instead of per command |
| Tombstone DEL | 25ns flag vs 140ns full remove |
