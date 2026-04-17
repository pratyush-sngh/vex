# Vex

A key-value store with graph database capabilities, written in Zig with zero dependencies. Speaks the Redis protocol (RESP), so you can connect using `redis-cli` or any Redis client library.

## Why Vex?

- **Redis-compatible wire protocol** -- works with every Redis client in every language
- **Graph operations built-in** -- nodes, edges, traversals, shortest path (BFS + Dijkstra)
- **Zero dependencies** -- pure Zig standard library, no external crates/packages
- **Single binary** -- compiles to a small, fast native executable
- **Designed for Zig 0.16.0** -- ready for `std.Io` async when the release lands

## Quick Start

```bash
# Build
zig build

# Run (default port 6380, data in ./data/)
zig build run

# Run on custom port with custom data directory
zig build run -- --port 7379 --data-dir /var/lib/vex

# Enable KEYS auto-switch behavior on large DBs
zig build run -- --keys-mode autoscan

# Scaled mode (default): one node, local engine threads (currently single-writer behavior)
zig build run -- --mode scaled --engine-threads 1

# Cluster mode: requires cluster config path
zig build run -- --mode cluster --engine-threads 2 --cluster-config ./cluster.json

# Run tests
zig build test
```

## Redis vs Vex Comparison (Docker + Go client)

Run both servers side-by-side and benchmark identical RESP workloads.

### 1) Start both containers

```bash
docker compose -f docker-compose.compare.yml up --build -d
```

Services (host ports chosen so they do not collide with a typical local Redis / vex dev server):
- `redis` on `127.0.0.1:16379` (maps to container `6379`)
- `vex` on `127.0.0.1:16380` (maps to container `6380`)

### 2) Run comparison client

```bash
cd tools/compare-client
GO111MODULE=on go run . -n 5000
# Parallel mode (8 workers / connections per scenario)
GO111MODULE=on go run . -n 5000 -c 8
# More stable comparisons: warmup + repeated runs + optional run order swap
GO111MODULE=on go run . -n 5000 -c 8 -warmup 500 -runs 3
GO111MODULE=on go run . -n 5000 -c 8 -warmup 500 -runs 3 -vex-first
```

Full regression matrix (compose up, wait for ports, several `n` / `-c` combinations):

```bash
./scripts/run-compare-benchmark.sh
```

What it runs:
- On both Redis and Vex: `FLUSHDB`, `SET`, `GET`, `DEL`
- On Vex only: `GRAPH.ADDNODE`, `GRAPH.ADDEDGE`
- Reports: min, p50, p95, p99, mean, max, and ops/s (median across `-runs`)

Optional server-side profiling (for bottleneck breakdown):

```bash
zig build run -- --profile --profile-every 100000
```

Scaling mode flags:
- `--mode scaled|cluster` (default: `scaled`)
- `--engine-threads <N>` (default: `1`)
- `--cluster-config <path>` (required in `cluster` mode)

Current `scaled` behavior:
- `--engine-threads > 1` enables hash-based queue routing for single-key KV commands (`SET`, `GET`, `TTL`, and single-key `DEL`/`EXISTS`).
- Routed through coordinator lane (`engine 0`): `SELECT` and all `GRAPH.*` commands.
- `FLUSHDB` is broadcast across shard lanes (single reply).
- Commands outside this subset currently return `ERR unsupported command in scaled multi-engine mode`.

### 3) Stop containers

```bash
docker compose -f docker-compose.compare.yml down
```

Connect with redis-cli (to the compose vex instance):

```bash
redis-cli -p 16380
```

## Commands

### Key-Value (Redis-compatible)

| Command | Description |
|---------|-------------|
| `PING [message]` | Health check |
| `SET key value [EX seconds]` | Set a key |
| `GET key` | Get a key's value |
| `DEL key [key ...]` | Delete keys |
| `EXISTS key [key ...]` | Check key existence |
| `KEYS pattern` | List keys matching glob pattern (guarded for large DBs) |
| `SCAN cursor [MATCH pattern] [COUNT n]` | Incremental key scan (preferred over `KEYS`) |
| `TTL key` | Get remaining TTL in seconds |
| `DBSIZE` | Number of keys |
| `FLUSHDB` | Delete all keys |
| `FLUSHALL` | Delete all keys and graph data across all DBs |
| `SELECT index` | Switch logical DB (`0`-`15`) |
| `MOVE key db` | Move key to another DB if destination key does not exist |
| `INFO` | Server information |
| `SAVE` | Foreground snapshot + AOF truncate |
| `LASTSAVE` | Unix timestamp of last successful snapshot |

### Redis compatibility notes

- Vex supports Redis-style logical DB selection via `SELECT`, with database indexes `0..15` (16 DBs).
- Each client connection maintains its own selected DB.
- Graph commands are DB-scoped too (node keys are namespaced by selected DB internally).
- `KEYS` behavior is configurable:
  - `--keys-mode strict` (default): error on large DB and advise `SCAN`
  - `--keys-mode autoscan`: automatically perform an internal scan and return the key list
- Multi-db commands still not implemented:
  - `SWAPDB`

### Graph Operations

| Command | Description |
|---------|-------------|
| `GRAPH.ADDNODE key type` | Create a node with a unique key and type label |
| `GRAPH.GETNODE key` | Get node details (key, type, properties) |
| `GRAPH.DELNODE key` | Delete a node and all its edges |
| `GRAPH.SETPROP key prop value` | Set a property on a node |
| `GRAPH.ADDEDGE from to type [weight]` | Create a directed edge between nodes |
| `GRAPH.DELEDGE edge_id` | Delete an edge by its ID |
| `GRAPH.NEIGHBORS key [OUT\|IN\|BOTH]` | Get direct neighbors |
| `GRAPH.TRAVERSE key [DEPTH n] [DIR OUT\|IN\|BOTH] [EDGETYPE t] [NODETYPE t]` | BFS traversal |
| `GRAPH.PATH from to [MAXDEPTH n]` | Unweighted shortest path (BFS) |
| `GRAPH.WPATH from to` | Weighted shortest path (Dijkstra) |
| `GRAPH.STATS` | Node and edge counts |

## Example Session

```
redis-cli -p 6380

# Key-Value
127.0.0.1:6380> SET greeting "hello world"
OK
127.0.0.1:6380> GET greeting
"hello world"

# Build a service dependency graph
127.0.0.1:6380> GRAPH.ADDNODE service:auth service
(integer) 0
127.0.0.1:6380> GRAPH.ADDNODE service:user service
(integer) 1
127.0.0.1:6380> GRAPH.ADDNODE service:payment service
(integer) 2
127.0.0.1:6380> GRAPH.ADDNODE db:postgres database
(integer) 3

127.0.0.1:6380> GRAPH.ADDEDGE service:auth service:user calls
(integer) 0
127.0.0.1:6380> GRAPH.ADDEDGE service:user db:postgres reads_from
(integer) 1
127.0.0.1:6380> GRAPH.ADDEDGE service:payment service:user calls 2.5
(integer) 2

# Query the graph
127.0.0.1:6380> GRAPH.NEIGHBORS service:user BOTH
1) "service:auth"
2) "service:payment"
3) "db:postgres"

127.0.0.1:6380> GRAPH.PATH service:auth db:postgres
1) "service:auth"
2) "service:user"
3) "db:postgres"

127.0.0.1:6380> GRAPH.TRAVERSE service:auth DEPTH 3 DIR OUT
1) "service:auth"
2) "service:user"
3) "db:postgres"

127.0.0.1:6380> GRAPH.STATS
1) "nodes"
2) (integer) 4
3) "edges"
4) (integer) 3
```

## Persistence

Vex supports both **snapshot** and **append-only file (AOF)** persistence, similar to Redis RDB+AOF.

### How it works

1. **On startup**: loads the latest snapshot (`vex.zdb`), then replays the AOF (`vex.aof`) to recover any commands since the last snapshot.
2. **During operation**: every mutating command (SET, DEL, GRAPH.ADDNODE, etc.) is appended to the AOF in binary format.
3. **On SAVE**: writes a full binary snapshot, then truncates the AOF (since all state is now in the snapshot).

### Files

| File | Description |
|------|-------------|
| `data/vex.zdb` | Binary snapshot (full state dump with CRC-32 integrity check) |
| `data/vex.aof` | Append-only log of mutating commands |

### Configuration

```bash
# Custom data directory (default: ./data/)
zig build run -- --data-dir /var/lib/vex
```

### Snapshot format

Binary format: magic header (`ZGDB`) + version + timestamp, then KV entries, graph nodes (with properties), graph edges (with properties), adjacency lists, and a CRC-32 footer for corruption detection.

## Architecture

```
src/
├── main.zig              # Entry point, arg parsing, persistence recovery
├── server/
│   ├── tcp.zig           # TCP accept loop, per-client threads
│   └── resp.zig          # RESP v2 protocol parser + serializer
├── engine/
│   ├── kv.zig            # Hash map key-value store with TTL
│   ├── graph.zig         # Graph engine (nodes, edges, adjacency lists)
│   └── query.zig         # BFS traversal, shortest path, Dijkstra
├── command/
│   └── handler.zig       # Command dispatcher (KV + graph + persistence)
└── storage/
    ├── snapshot.zig       # Binary snapshot save/load with CRC-32
    └── aof.zig            # Append-only file for write-ahead logging
```

**Design principles:**

- **Single-threaded command processing** (Redis model) -- no locks needed on data structures
- **Dense internal IDs** for nodes -- O(1) lookup by index
- **Forward + reverse adjacency lists** -- efficient traversal in both directions
- **Tombstone deletion** -- stable node IDs across deletions
- **Lazy TTL eviction** -- expired keys cleaned up on access
- **Dual persistence** -- binary snapshots + append-only file for durability

## Scaling Approach (Design)

Current deployment is single-node. The planned scaling model is incremental:

1. **Top-level split (first step)**:
   - `router` (protocol + routing)
   - `kv` engine
   - `graph` engine
   Each has separate ownership and can run as separate processes later.

2. **Independent scaling paths**:
   - Router: stateless horizontal scaling.
   - KV: future hash/slot partitioning and replicas.
   - Graph: start as single partition, add dedicated scaling strategy later.

3. **Future cluster primitives** (not implemented yet):
   - slot/partition ownership map
   - versioned routing config (epoch)
   - replication and failover roles
   - rebalance/migration workflow

This design keeps single-node simplicity now while preserving a path to horizontal scale.

See architectural decision record: `docs/adr/0001-top-level-partitioning-and-scaling.md`.

## Roadmap

- [x] Persistence (AOF / snapshot)
- [ ] `std.Io` async server (Zig 0.16.0 -- io_uring / kqueue backend)
- [ ] Pub/Sub for graph change notifications
- [ ] Cypher-like query language
- [ ] Replication
- [ ] Web UI for graph visualization

## License

MIT
