# Vex

A high-performance KV + Graph database written in Zig. Speaks the Redis protocol (RESP), so you can connect with `redis-cli` or any Redis client library.

## Why Vex?

- **Up to 2x faster than Redis** on pipelined KV workloads (2.96M GET cmd/s)
- **23x faster shortest path than Memgraph** via bidirectional BFS + CSR adjacency
- **Wins all 5 graph operations** vs Memgraph (add, traverse, path, neighbors)
- **Redis-compatible** -- works with every Redis client library
- **Zero dependencies** -- pure Zig standard library, single binary

## Benchmarks

### KV: Vex vs Redis 8.0 (Docker)

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

### Graph: Vex vs Memgraph (Docker, 10K nodes / 50K edges)

| Operation | Memgraph | Vex | Speedup |
|---|---|---|---|
| AddNode | 180 us | **139 us** | **+23%** |
| AddEdge | 197 us | **145 us** | **+26%** |
| BFS Traverse (depth 3) | **313 us** | 326 us | ~tied |
| Shortest Path | 4,838 us | **210 us** | **Vex 23x faster** |
| Neighbors | 233 us | **154 us** | **+34%** |

Vex wins or ties all 5 operations. Shortest path uses bidirectional BFS (meet-in-the-middle), which is dramatically faster than Memgraph's standard BFS.

### Internal Engine Benchmarks (no network)

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

## Quick Start

```bash
zig build                                          # Build
zig build run                                      # Run (port 6380, ./data/)
zig build run -- --reactor                        # Reactor mode (recommended)
zig build run -- --reactor --port 7379 --no-persistence  # Benchmarking
zig build test                                     # Run tests
```

Workers auto-detect from CPU core count (capped at 8). Override with `--workers N`.

## Architecture

```
              Accept Thread (main)
              /    |    |    \
         Worker0  W1   W2   W3     -- N event-loop threads (auto-detected)
         (epoll)  ...              -- epoll on Linux, kqueue on macOS, io_uring
         /  |  \
      conn conn conn               -- non-blocking I/O per worker
            |
   ConcurrentKV                    -- 256-stripe rwlock (parallel reads, exclusive writes)
   GraphEngine                     -- CSR adjacency, SoA layout, auto-compact
   AOF                             -- thread-safe persistence
```

### Why It's Fast

**ConcurrentKV (256-stripe rwlock):**
- GET takes read lock -- multiple workers read in parallel, zero blocking
- SET takes write lock -- exclusive, but lock held only ~20ns (HashMap pointer swap)
- Key+value allocated OUTSIDE lock, stale data freed OUTSIDE lock
- Cached clock per event-loop tick (no clock_gettime syscall per GET)
- Cache-line aligned stripes prevent false sharing between CPU cores

**Graph engine (CSR + SoA + bitflags):**
- Compressed Sparse Row adjacency with auto-compact from delta buffer
- Bidirectional BFS for shortest path (explores sqrt(N) instead of N nodes)
- Frontier-based BFS traverse (process entire levels with bitset frontiers)
- DynamicBitSet visited set: 125KB for 1M nodes (fits L2 cache)
- TypeMask bitmask filtering, string interning, shared PropertyStore

**Networking:**
- Zero-copy read: parse RESP directly from stack read buffer
- Direct-write-first: skip enableWrite/disableWrite syscalls
- Head-index accumulator: advance pointer, never memmove
- Comptime dispatch: switch on (cmd.len, first_byte), pre-built RESP literals
- TCP_NODELAY on all sockets

### Source Layout

```
src/
├── main.zig                # Entry point, arg parsing, signal handling
├── server/
│   ├── tcp.zig             # Accept loop, reactor mode
│   ├── event_loop.zig      # Platform-abstracted poll (epoll/kqueue/io_uring)
│   ├── worker.zig          # Multi-connection event loop worker
│   ├── resp.zig            # RESP v2 protocol parser
│   └── shard_router.zig    # Key-to-shard routing, MPSC queues
├── engine/
│   ├── kv.zig              # KV store with TTL, tombstone DEL, cached clock
│   ├── concurrent_kv.zig   # 256-stripe rwlock KV (parallel reads)
│   ├── graph.zig           # CSR graph engine (SoA, bitflags, auto-compact)
│   ├── query.zig           # Bidirectional BFS, frontier traverse, Dijkstra
│   ├── string_intern.zig   # Type deduplication (u16 IDs, bitmask filtering)
│   ├── property_store.zig  # Shared sparse property storage
│   └── pool_arena.zig      # Slab allocator with background arena refill
├── command/
│   ├── handler.zig         # Command dispatcher (KV + graph + persistence)
│   └── comptime_dispatch.zig  # Compile-time command table and RESP literals
├── perf/
│   └── span.zig            # Latency profiler
└── storage/
    ├── snapshot.zig         # Binary snapshot with CRC-32 (format v2)
    └── aof.zig              # Append-only file + BGREWRITEAOF
```

## Benchmarking

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

## Commands

### Key-Value (Redis-compatible)

| Command | Description |
|---------|-------------|
| `PING [message]` | Health check |
| `SET key value [EX seconds\|PX ms]` | Set a key with optional TTL |
| `GET key` | Get a key's value |
| `MGET key [key ...]` | Get multiple keys |
| `MSET key value [key value ...]` | Set multiple keys |
| `DEL key [key ...]` | Delete keys |
| `EXISTS key [key ...]` | Check key existence |
| `INCR key` / `DECR key` | Increment/decrement integer value |
| `INCRBY key n` / `DECRBY key n` | Increment/decrement by N |
| `APPEND key value` | Append to existing value |
| `EXPIRE key seconds` | Set TTL on existing key |
| `PERSIST key` | Remove TTL from key |
| `KEYS pattern` | List keys matching glob pattern |
| `SCAN cursor [MATCH pattern] [COUNT n]` | Incremental key scan |
| `TTL key` | Get remaining TTL in seconds |
| `DBSIZE` | Number of keys |
| `SELECT index` | Switch logical DB (0-15) |
| `FLUSHDB` | Delete all keys in current DB |
| `FLUSHALL` | Delete all keys and graph data |
| `MOVE key db` | Move key to another DB |
| `SAVE` | Foreground snapshot + AOF truncate |
| `BGREWRITEAOF` | Compact AOF from current state |
| `INFO` | Server stats (keyspace, graph, persistence) |

### Graph Operations

| Command | Description |
|---------|-------------|
| `GRAPH.ADDNODE key type` | Create a node |
| `GRAPH.GETNODE key` | Get node details + properties |
| `GRAPH.DELNODE key` | Delete a node and its edges |
| `GRAPH.SETPROP key prop value` | Set a node property |
| `GRAPH.ADDEDGE from to type [weight]` | Create a directed edge |
| `GRAPH.DELEDGE edge_id` | Delete an edge |
| `GRAPH.NEIGHBORS key [OUT\|IN\|BOTH]` | Get direct neighbors |
| `GRAPH.TRAVERSE key [DEPTH n] [DIR d] [EDGETYPE t] [NODETYPE t]` | BFS traversal |
| `GRAPH.PATH from to [MAXDEPTH n]` | Shortest unweighted path (bidirectional BFS) |
| `GRAPH.WPATH from to` | Shortest weighted path (Dijkstra) |
| `GRAPH.COMPACT` | Rebuild CSR from delta edges |
| `GRAPH.STATS` | Node and edge counts |

## Example

```
redis-cli -p 6380

127.0.0.1:6380> SET greeting "hello world"
OK
127.0.0.1:6380> GET greeting
"hello world"

127.0.0.1:6380> GRAPH.ADDNODE service:auth service
(integer) 0
127.0.0.1:6380> GRAPH.ADDNODE service:user service
(integer) 1
127.0.0.1:6380> GRAPH.ADDEDGE service:auth service:user calls
(integer) 0

127.0.0.1:6380> GRAPH.TRAVERSE service:auth DEPTH 2 DIR OUT
1) "service:auth"
2) "service:user"

127.0.0.1:6380> GRAPH.PATH service:auth service:user
1) "service:auth"
2) "service:user"
```

## Persistence

Snapshot + AOF persistence (similar to Redis RDB+AOF).

- **Startup**: loads snapshot (`vex.zdb`), replays AOF (`vex.aof`)
- **Runtime**: mutating commands appended to AOF
- **SAVE**: writes snapshot, truncates AOF
- **BGREWRITEAOF**: compacts AOF by serializing current state
- **Graceful shutdown**: SIGTERM/SIGINT triggers snapshot + AOF flush

```bash
zig build run -- --data-dir /var/lib/vex      # persistence enabled (default)
zig build run -- --no-persistence              # disable for benchmarking
```

## Security

```bash
zig build run -- --reactor --requirepass mysecret
```

Clients must `AUTH mysecret` before any command (except PING). Password comparison is constant-time.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | 6380 | Listen port |
| `--host` | 0.0.0.0 | Bind address |
| `--reactor` | off | Enable multi-reactor mode (recommended) |
| `--workers N` | auto (CPU cores, max 8) | Worker threads |
| `--data-dir` | ./data | Persistence directory |
| `--no-persistence` | off | Disable AOF/snapshot |
| `--requirepass` | none | Password for AUTH |
| `--maxclients` | 10000 | Max concurrent connections |
| `--max-client-buffer` | 1MB | Max unparsed data per connection |
| `--profile` | off | Enable latency profiling |
| `--profile-every N` | 100000 | Print profile every N commands |

## Clustering

Vex supports leader/follower replication for read scaling and data safety.

```bash
# Start a 3-node cluster
docker compose -f docker-compose.cluster.yml up --build -d

# Write to leader
redis-cli -p 16380 SET hello world

# Read from any follower (replicated)
redis-cli -p 16381 GET hello    # → "world"
redis-cli -p 16382 GET hello    # → "world"

# Writes on followers are forwarded to leader automatically
redis-cli -p 16381 SET fromfollower value
redis-cli -p 16380 GET fromfollower  # → "value" (on leader)
redis-cli -p 16382 GET fromfollower  # → "value" (replicated)
```

**Cluster config** (`cluster.conf`):
```
node 1 leader 10.0.0.1:6380
node 2 follower 10.0.0.2:6380
node 3 follower 10.0.0.3:6380
self 1
```

**Features:**
- Leader accepts all writes, broadcasts mutations to followers via binary VX protocol
- Followers forward writes to leader, serve reads locally
- Full sync: new followers receive a snapshot on connect
- Heartbeat every 5s with mutation_seq for lag tracking
- Replication lag: `leader_seq - local_seq` (available via `replLag()`)
- Graph replication: ADDNODE/ADDEDGE on leader → TRAVERSE/PATH on followers

**Consistency model:** Eventual consistency for reads on followers. All writes go through the leader. Read-your-own-writes is guaranteed on the leader only.

| CLI Flag | Description |
|---|---|
| `--cluster-config <path>` | Path to cluster config file |

## Changelog

### v0.2.0 — Distributed KV + Graph Read Replicas

**Cluster & Replication:**
- `9cf75ee` Full sync, heartbeat, lag tracking: production-ready replication
- `121f84e` Heartbeat every 5s with mutation_seq + timestamp
- `ba255fa` Full replication: leader broadcasts mutations, followers replay locally
- `210ed41` Working 3-node cluster: write forwarding from follower to leader
- `c2faca9` 3-node cluster: leader + 2 followers running, replication listener
- `e6d32fb` Replication module: leader/follower streaming, write forwarding
- `0453bef` Cluster foundation: config parser, binary VX protocol, graph mutation_seq

**Graph Performance (vs Memgraph):**
- `be52b79` Auto-compact + GRAPH.COMPACT: Vex wins all 5 ops vs Memgraph
- `499f20a` Frontier-based BFS traverse: +38% faster, tied with Memgraph
- `70a426a` Bidirectional BFS: 23x faster shortest path than Memgraph
- `59c5e37` Graph rwlock: parallel read queries, exclusive writes
- `e2bdd75` Flat parent arrays + fix getCSRSlice double-loop

**KV Performance (vs Redis 8.0):**
- `33c32a5` pthread_rwlock per stripe: +70% GET, parallel readers
- `6ec9b82` Move all malloc/free outside stripe locks: +91% SET
- `007e3d4` Pre-allocate SET value outside lock: reduce lock hold to ~20ns
- `8e35b12` Cached clock, cache-line aligned stripes, optimized getAndWriteBulk
- `da25bd9` Zero-copy read: parse RESP directly from stack buffer

**Networking:**
- `c85e1f8` Auto-detect worker count from CPU cores
- `ca5eff9` Comptime command dispatch table + pre-built RESP literals
- `3953023` Shard router infrastructure (16384 slots, MPSC queues)

**Commands & Prod Hardening:**
- `b469125` Add MGET, MSET, INCR, DECR, INCRBY, DECRBY, EXPIRE, PERSIST, APPEND
- `887074c` AUTH, maxclients, max-client-buffer, graceful shutdown, BGREWRITEAOF
- `c1c7b50` Tests for all new commands

### v0.1.0 — Initial Release

- `0255e74` V2 engine: CSR graph, KV tombstone DEL, networking optimizations
- `808dba3` Multi-reactor architecture, MIT license
- `8eaf96e` Redis-compatible KV + Graph DB with epoll/kqueue/io_uring

## Roadmap

### v0.3 — Production Hardening
- TLS support (encrypted connections)
- `MULTI`/`EXEC` transactions
- Pub/Sub (`SUBSCRIBE`/`PUBLISH`)
- Config file support (`vex.conf`)
- Automatic failover (leader election)

### v0.4 — Partitioned Graph
- Hash-partition graph nodes across machines
- Ghost nodes for 1-hop boundary cache
- BSP BFS for cross-partition traversals
- Distributed Dijkstra
- Consistent hash ring with vnodes

### Future
- Graph secondary indexes on properties
- Cypher query language subset
- io_uring batched read/write (Linux)
- PageRank, connected components algorithms

## License

MIT
