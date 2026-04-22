# Vex

A high-performance KV + Graph database written in Zig. Speaks the Redis protocol (RESP), so you can connect with `redis-cli` or any Redis client library. Multi-reactor architecture with CSR graph engine.

## Why Vex?

- **Competitive with Redis** -- multi-reactor event loop, tombstone deletes, cached clocks, direct-write-first networking
- **60x faster graph traversals** -- CSR (Compressed Sparse Row) adjacency, bitset visited sets, bitmask type filtering
- **Graph operations built-in** -- nodes, edges, BFS traversal, shortest path (BFS + Dijkstra)
- **4.3x less graph memory** -- SoA layout, interned types, shared property store (no per-entity HashMaps)
- **Redis-compatible wire protocol** -- works with every Redis client in every language
- **Zero dependencies** -- pure Zig standard library, single binary

## Performance

### KV: Vex vs Redis 8.0 (Docker, 6 workers)

| Concurrency | Vex SET | Redis SET | Vex GET | Redis GET |
|---|---|---|---|---|
| c=1 | **6,506** | 5,579 | 5,413 | **5,455** |
| c=32 | **51,907** | 49,805 | 48,066 | **48,978** |
| c=64 | 57,838 | **59,769** | **57,111** | 55,236 |
| c=128 | 64,191 | **67,906** | **73,475** | 54,492 |

GET at c=128: **+35% faster** than Redis. SET at c=1: **+17% faster**.

### Graph Engine (internal benchmarks, 50K nodes / 500K edges)

| Operation | Time | Notes |
|---|---|---|
| BFS Traverse (depth 4) | 64 us | CSR + bitset visited + head-index dequeue |
| Shortest Path | 146 us | Bitset-accelerated BFS |
| Neighbors | <0.1 us | Zero-copy CSR slice return |
| Memory | 19 MB | vs ~84 MB with naive adjacency lists |

### KV Engine (internal benchmarks, 100K ops)

| Operation | Time |
|---|---|
| GET (hit) | 24 ns/op |
| SET (insert) | 66 ns/op |
| SET (update) | 74 ns/op |
| DEL (tombstone) | 35 ns/op |
| SET (reuse tombstone) | 41 ns/op |

## Quick Start

```bash
zig build                                          # Build
zig build run                                      # Run (port 6380, ./data/)
zig build run -- --reactor --workers 4            # 4 worker threads (recommended)
zig build run -- --reactor --workers 4 --port 7379 --no-persistence
zig build test                                     # Run tests
```

## Architecture

```
              Accept Thread (main)
              /    |    |    \
         Worker0  W1   W2   W3     -- N event-loop threads
         (epoll)  ...              -- epoll on Linux, kqueue on macOS, io_uring
         /  |  \
      conn conn conn               -- non-blocking I/O, many conns per worker
            |
   ConcurrentKV (256-stripe locks) -- tombstone DEL, cached clock, getOrPut
   GraphEngine  (CSR + delta)      -- SoA layout, bitset alive/visited, type masks
   AOF          (thread-safe)      -- persistence
```

### Engine Design

**KV optimizations:**
- Tombstone DEL (flag-based, ~35ns) with periodic compaction
- Cached clock per event-loop tick (eliminates clock_gettime per GET)
- `getOrPut` single-hash SET (was double-hash: getPtr + put)
- `ttl_count` fast path: skip expiry checks when no keys have TTL
- Compact Entry: `i64` expires_at (8B) instead of `?i64` (16B)

**Graph engine (CSR + SoA + bitflags):**
- Compressed Sparse Row adjacency: contiguous neighbor arrays, prefetcher-friendly
- Struct-of-Arrays layout: node keys, type IDs, alive bits in separate flat arrays
- DynamicBitSet visited set: 125KB for 1M nodes (fits L2), vs 2MB HashMap
- TypeMask bitmask filtering: single AND per edge vs string comparison
- Per-node type summary mask: skip entire nodes when no edges match filter
- String interning: "service" stored once, referenced by u16 ID
- Shared PropertyStore: one HashMap for all entities (zero overhead for no-prop entities)
- Delta buffer with periodic compaction into base CSR

**Networking optimizations:**
- Head-index accumulator (no memmove per command, Redis-style qb_pos)
- Direct-write-first (skip enableWrite/disableWrite syscalls for small responses)
- Batch flush (one write() per read(), not per command)
- Precomputed DB prefixes (comptime, zero runtime formatting)
- Fast command dispatch (switch on cmd.len + first byte)
- TCP_NODELAY on all accepted sockets

```
src/
├── main.zig                # Entry point, arg parsing, persistence recovery
├── server/
│   ├── tcp.zig             # Accept loop, legacy thread-per-conn, reactor mode
│   ├── event_loop.zig      # Platform-abstracted poll (epoll/kqueue/io_uring)
│   ├── worker.zig          # Multi-connection event loop worker
│   └── resp.zig            # RESP v2 protocol parser
├── engine/
│   ├── kv.zig              # Hash map KV store with TTL, tombstone DEL
│   ├── concurrent_kv.zig   # 256-stripe thread-safe KV store
│   ├── graph.zig           # CSR graph engine (SoA, bitflags, delta buffer)
│   ├── query.zig           # BFS traversal, shortest path, Dijkstra
│   ├── string_intern.zig   # Type string deduplication (u16 IDs, bitmask)
│   ├── property_store.zig  # Shared sparse property storage
│   └── pool_arena.zig      # Slab allocator with background arena refill
├── command/
│   └── handler.zig         # Command dispatcher (KV + graph + persistence)
├── perf/
│   └── span.zig            # Latency profiler
└── storage/
    ├── snapshot.zig         # Binary snapshot save/load with CRC-32
    └── aof.zig              # Append-only file for write-ahead logging
```

## Benchmarking

```bash
# Redis comparison (Docker)
docker compose -f docker-compose.compare.yml up --build -d
cd tools/compare-client
go run . -n 20000 -c 32 -warmup 1000 -runs 5 -timeout 50s
docker compose -f docker-compose.compare.yml down -v

# Internal KV benchmark
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
| `INFO` | Server information |

### Graph Operations

| Command | Description |
|---------|-------------|
| `GRAPH.ADDNODE key type` | Create a node |
| `GRAPH.GETNODE key` | Get node details |
| `GRAPH.DELNODE key` | Delete a node and its edges |
| `GRAPH.SETPROP key prop value` | Set a node property |
| `GRAPH.ADDEDGE from to type [weight]` | Create a directed edge |
| `GRAPH.DELEDGE edge_id` | Delete an edge |
| `GRAPH.NEIGHBORS key [OUT\|IN\|BOTH]` | Get direct neighbors |
| `GRAPH.TRAVERSE key [DEPTH n] [DIR d] [EDGETYPE t] [NODETYPE t]` | BFS traversal |
| `GRAPH.PATH from to [MAXDEPTH n]` | Shortest unweighted path |
| `GRAPH.WPATH from to` | Shortest weighted path (Dijkstra) |
| `GRAPH.STATS` | Node and edge counts |

## Persistence

Snapshot + AOF persistence (similar to Redis RDB+AOF).

- **Startup**: loads snapshot (`vex.zdb`), replays AOF (`vex.aof`)
- **Runtime**: mutating commands appended to AOF
- **SAVE**: writes snapshot, truncates AOF

```bash
zig build run -- --data-dir /var/lib/vex      # enable persistence
zig build run -- --no-persistence              # disable (benchmarking)
```

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | 6380 | Listen port |
| `--host` | 0.0.0.0 | Bind address |
| `--reactor` | off | Enable multi-reactor mode |
| `--workers N` | 4 | Number of worker threads (reactor mode) |
| `--data-dir` | ./data | Persistence directory |
| `--no-persistence` | off | Disable AOF/snapshot |
| `--profile` | off | Enable latency profiling |
| `--profile-every N` | 100000 | Print profile every N commands |

## License

MIT
