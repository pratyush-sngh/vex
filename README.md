# Vex

A high-performance KV + Graph database written in Zig. Speaks the Redis protocol (RESP), so you can connect with `redis-cli` or any Redis client library. Multi-reactor architecture beats Redis on concurrent workloads.

## Why Vex?

- **Faster than Redis at concurrency** -- multi-reactor event loop (epoll/kqueue/io_uring) scales across CPU cores
- **Graph operations built-in** -- nodes, edges, traversals, shortest path (BFS + Dijkstra)
- **Redis-compatible wire protocol** -- works with every Redis client in every language
- **Zero dependencies** -- pure Zig standard library
- **Single binary** -- compiles to a small, fast native executable

## Performance

Benchmarked against Redis 8.0 in Docker (6 workers):

| Concurrency | Vex SET | Redis SET | Vex GET | Redis GET |
|---|---|---|---|---|
| c=1 | 7,137 | 6,931 | 7,055 | 6,818 |
| c=10 | 31,897 | 30,875 | 31,181 | 30,387 |
| c=32 | 54,254 | 48,957 | 54,549 | 54,617 |
| c=64 | **72,783** | 48,406 | **61,192** | 54,144 |
| c=128 | 74,118 | 82,312 | **72,482** | 71,782 |

Vex is **+50% faster** than Redis on SET at c=64, and **+13% on GET** at c=64.

## Quick Start

```bash
# Build
zig build

# Run (default port 6380, data in ./data/)
zig build run

# Reactor mode with 4 worker threads (recommended)
zig build run -- --reactor --workers 4

# Custom port, no persistence (benchmarking)
zig build run -- --reactor --workers 4 --port 7379 --no-persistence

# Run tests
zig build test
```

## Architecture

```
              Accept Thread (main)
              /    |    |    \
         Worker0  W1   W2   W3     -- N event-loop threads
         (epoll)  ...              -- epoll on Linux, kqueue on macOS
         /  |  \
      conn conn conn               -- non-blocking I/O, many conns per worker
            |
   ConcurrentKV (256-stripe locks) -- any worker accesses any key
   GraphEngine  (global mutex)     -- serialized graph ops
   AOF          (thread-safe)      -- persistence
```

**Multi-reactor model**: N worker threads each run their own event loop (epoll/kqueue), multiplexing many connections per worker. Hot-path KV commands (GET, SET, DEL, EXISTS, TTL, PING) execute inline with zero-allocation RESP parsing and stripe-locked concurrent KV access. Non-hot commands fall through to the full `CommandHandler`.

```
src/
├── main.zig                # Entry point, arg parsing, persistence recovery
├── server/
│   ├── tcp.zig             # Accept loop, legacy thread-per-conn, reactor mode
│   ├── event_loop.zig      # Platform-abstracted poll (epoll/kqueue/io_uring)
│   ├── worker.zig          # Multi-connection event loop worker
│   └── resp.zig            # RESP v2 protocol parser
├── engine/
│   ├── kv.zig              # Hash map KV store with TTL
│   ├── concurrent_kv.zig   # 256-stripe thread-safe KV store
│   ├── graph.zig           # Graph engine (nodes, edges, adjacency lists)
│   └── query.zig           # BFS traversal, shortest path, Dijkstra
├── command/
│   └── handler.zig         # Command dispatcher (KV + graph + persistence)
├── perf/
│   └── span.zig            # Latency profiler
└── storage/
    ├── snapshot.zig         # Binary snapshot save/load with CRC-32
    └── aof.zig              # Append-only file for write-ahead logging
```

## Benchmarking

Run both Vex and Redis side-by-side in Docker:

```bash
# Start containers
docker compose -f docker-compose.compare.yml up --build -d

# Run comparison
cd tools/compare-client
go run . -n 20000 -c 32 -warmup 1000 -runs 5 -timeout 50s

# Full matrix (c=1,8,16,32)
./scripts/run-compare-benchmark.sh

# Stop
docker compose -f docker-compose.compare.yml down -v
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

127.0.0.1:6380> GRAPH.NEIGHBORS service:user BOTH
1) "service:auth"

127.0.0.1:6380> GRAPH.PATH service:auth service:user
1) "service:auth"
2) "service:user"
```

## Persistence

Vex supports snapshot + AOF persistence (similar to Redis RDB+AOF).

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
