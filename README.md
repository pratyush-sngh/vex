# Vex

A high-performance KV + Graph database written in Zig. Speaks the Redis protocol (RESP), so you can connect with `redis-cli` or any Redis client library.

## Why Vex?

- **Up to 2x faster than Redis** -- multi-reactor with rwlock stripes, pipelined workloads hit 2.46M GET cmd/s
- **Built-in graph engine** -- 60x faster BFS traversals via CSR adjacency, bitset-accelerated algorithms
- **Redis-compatible** -- works with every Redis client library in every language
- **Zero dependencies** -- pure Zig standard library, single binary

## Performance

### Pipelined KV: Vex vs Redis 8.0 (Docker)

Real Redis clients pipeline commands (batch multiple per TCP write). This is where Vex's multi-core architecture shines:

| Benchmark | Redis cmd/s | Vex cmd/s | Speedup |
|---|---|---|---|
| PIPE-SET(100) c=16 | 1.18M | **2.25M** | **+91%** |
| PIPE-GET(50) c=32 | 1.45M | **2.46M** | **+70%** |
| PIPE-GET(100) c=16 | 1.52M | **2.96M** | **+96%** |

### Single-command KV (no pipeline)

| Concurrency | Vex SET | Redis SET | Vex GET | Redis GET |
|---|---|---|---|---|
| c=1 | **7,223** | 6,064 (+19%) | **7,079** | 6,679 (+6%) |
| c=10 | 28,676 | **29,615** | **30,601** | 30,221 (+1%) |
| c=32 | 49,080 | **53,707** (-9%) | **50,266** | 48,824 (+3%) |

At c=1: Vex is faster (engine speed advantage). At c=32+: Redis's single-threaded model has zero coordination overhead. Pipeline to see Vex's multi-core advantage.

### Pipeline Scaling (c=1, single connection)

| Pipeline size | Redis cmd/s | Vex cmd/s | Speedup |
|---|---|---|---|
| p=1 | 7,104 | 5,775 | -19% |
| p=10 | 64,800 | **65,681** | +1% |
| p=50 | 277,345 | **288,415** | +4% |
| p=100 | 468,300 | **505,450** | +8% |

Even on a single connection, Vex wins once pipelining amortizes the per-command overhead.

### Graph Engine (50K nodes / 500K edges)

| Operation | Time | Notes |
|---|---|---|
| BFS Traverse (depth 4) | **64 us** | 60x faster than naive adjacency lists |
| Shortest Path | **146 us** | Bitset-accelerated BFS |
| Neighbors | **<0.1 us** | Zero-copy CSR slice return |
| Memory | **19 MB** | 4.3x less than per-entity HashMap model |

Redis has no graph operations. Vex provides BFS traversal, shortest path (unweighted + Dijkstra), and neighbor queries natively over RESP.

### KV Engine Internals (100K ops, no network)

| Operation | Latency |
|---|---|
| GET (hit) | 24 ns |
| SET (insert) | 66 ns |
| DEL (tombstone) | 35 ns |
| SET (reuse tombstone) | 41 ns |

## Quick Start

```bash
zig build                                          # Build
zig build run                                      # Run (port 6380, ./data/)
zig build run -- --reactor --workers 4            # Reactor mode (recommended)
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
   GraphEngine                     -- CSR adjacency, SoA layout, bitset tracking
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
- Compressed Sparse Row adjacency: contiguous neighbor arrays, prefetcher-friendly
- DynamicBitSet visited set: 125KB for 1M nodes (fits L2 cache) vs 2MB HashMap
- TypeMask bitmask filtering: single AND per edge, skip entire nodes via type summary masks
- String interning: type strings stored once, referenced by u16 ID
- Shared PropertyStore: one HashMap for all entities (zero overhead for no-prop entities)

**Networking:**
- Zero-copy read: parse RESP directly from stack read buffer (no memcpy to heap)
- Direct-write-first: skip enableWrite/disableWrite syscalls for small responses
- Head-index accumulator: advance pointer, never memmove (Redis-style qb_pos)
- Comptime dispatch: switch on (cmd.len, first_byte), pre-built RESP response literals
- TCP_NODELAY on all sockets, auto-detected worker count

### Source Layout

```
src/
├── main.zig                # Entry point, arg parsing, signal handling
├── server/
│   ├── tcp.zig             # Accept loop, reactor mode, thread-per-conn mode
│   ├── event_loop.zig      # Platform-abstracted poll (epoll/kqueue/io_uring)
│   ├── worker.zig          # Multi-connection event loop worker
│   ├── resp.zig            # RESP v2 protocol parser
│   └── shard_router.zig    # Key-to-shard routing, MPSC queues (for future distributed)
├── engine/
│   ├── kv.zig              # KV store with TTL, tombstone DEL, cached clock
│   ├── concurrent_kv.zig   # 256-stripe rwlock KV (parallel reads)
│   ├── graph.zig           # CSR graph engine (SoA, bitflags, delta buffer)
│   ├── query.zig           # BFS, shortest path, Dijkstra (bitset-accelerated)
│   ├── string_intern.zig   # Type deduplication (u16 IDs, bitmask filtering)
│   ├── property_store.zig  # Shared sparse property storage
│   └── pool_arena.zig      # Slab allocator with background arena refill
├── command/
│   ├── handler.zig         # Full command dispatcher (KV + graph + persistence)
│   └── comptime_dispatch.zig  # Compile-time command table and RESP literals
├── perf/
│   └── span.zig            # Latency profiler
└── storage/
    ├── snapshot.zig         # Binary snapshot with CRC-32 (format v2)
    └── aof.zig              # Append-only file + BGREWRITEAOF
```

## Benchmarking

```bash
# Redis comparison (Docker, pipelined)
docker compose -f docker-compose.compare.yml up --build -d
cd tools/compare-client
go run . -n 2000 -c 16 -warmup 500 -runs 5 -timeout 60s -pipeline 100
docker compose -f docker-compose.compare.yml down -v

# Standard benchmark (no pipeline)
go run . -n 20000 -c 32 -warmup 3000 -runs 5 -timeout 30s

# Internal KV engine benchmark
zig build bench-kv -Doptimize=ReleaseFast
```

## Commands

### Key-Value (Redis-compatible)

| Command | Description |
|---------|-------------|
| `PING [message]` | Health check |
| `SET key value [EX seconds\|PX ms]` | Set a key with optional TTL |
| `GET key` | Get a key's value |
| `DEL key [key ...]` | Delete keys |
| `EXISTS key [key ...]` | Check key existence |
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
| `GRAPH.PATH from to [MAXDEPTH n]` | Shortest unweighted path (BFS) |
| `GRAPH.WPATH from to` | Shortest weighted path (Dijkstra) |
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

## License

MIT
