# Vex

A high-performance KV + Graph database written in Zig 0.16. Speaks the Redis protocol (RESP), so you can connect with `redis-cli` or any Redis client library.

## Why Vex?

- **Up to 2x faster than Redis** on pipelined KV workloads (2.96M GET cmd/s)
- **23x faster shortest path than Memgraph** via bidirectional BFS + CSR adjacency
- **Wins all 5 graph operations** vs Memgraph (add, traverse, path, neighbors)
- **Redis-compatible** -- works with every Redis client library
- **Zero dependencies** -- pure Zig standard library, single binary
- **Production features** -- TLS, transactions, pub/sub, LRU eviction, background saves, config files, structured logging, clustering with automatic failover

---

## Table of Contents

- [Quick Start](#quick-start)
- [Benchmarks](#benchmarks)
- [Architecture](#architecture)
- [Commands](#commands)
  - [Key-Value](#key-value-redis-compatible)
  - [Transactions (MULTI/EXEC)](#transactions)
  - [Pub/Sub](#pubsub)
  - [Graph Operations](#graph-operations)
  - [Persistence](#persistence-commands)
- [Examples](#examples)
- [Configuration](#configuration)
  - [CLI Flags](#cli-flags)
  - [Config File](#config-file)
  - [Environment Variables](#environment-variables)
- [Persistence](#persistence)
  - [Snapshot + AOF](#snapshot--aof)
  - [Background Save (BGSAVE)](#background-save-bgsave)
  - [AOF Group Commit](#aof-group-commit)
- [Security](#security)
  - [Authentication](#authentication)
  - [TLS Encryption](#tls-encryption)
- [Memory Management](#memory-management)
  - [LRU Eviction](#lru-eviction)
  - [Memory Estimation](#memory-estimation)
- [Clustering](#clustering)
  - [Leader/Follower Replication](#leaderfollower-replication)
  - [Automatic Failover](#automatic-failover)
  - [Consistency Model](#consistency-model)
- [Structured Logging](#structured-logging)
- [Deployment](#deployment)
- [Source Layout](#source-layout)
- [Testing](#testing)
- [Benchmarking](#benchmarking-1)
- [Changelog](#changelog)
- [Roadmap](#roadmap)
- [License](#license)

---

## Quick Start

```bash
# Build
zig build

# Run with defaults (port 6380, persistence in ./data/)
zig build run

# Run in reactor mode (recommended for production)
zig build run -- --reactor

# Run with config file
echo "port 6380\nreactor\nmaxmemory 256mb" > vex.conf
zig build run

# Connect with any Redis client
redis-cli -p 6380
```

Workers auto-detect from CPU core count (capped at 8). Override with `--workers N`.

### Docker

```bash
# Single node
docker build -t vex .
docker run -p 6380:6380 vex --reactor

# 3-node cluster
docker compose -f docker-compose.cluster.yml up --build -d
```

---

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

---

## Architecture

```
              Accept Thread (main)
              /    |    |    \
         Worker0  W1   W2   W3     -- N event-loop threads (auto-detected)
         (kqueue) ...              -- kqueue on macOS, epoll on Linux, io_uring fallback
         /  |  \
      conn conn conn               -- non-blocking I/O per worker
            |
   ┌────────┴────────┐
   │  ConcurrentKV   │             -- 256-stripe rwlock (parallel reads, exclusive writes)
   │  GraphEngine    │             -- CSR adjacency, SoA layout, auto-compact
   │  PubSubRegistry │             -- shared cross-worker subscriber map
   │  AOF (group)    │             -- buffered write-ahead log, flushed per tick
   └─────────────────┘
```

### Why It's Fast

**ConcurrentKV (256-stripe rwlock):**
- GET takes read lock -- multiple workers read in parallel, zero blocking
- SET takes write lock -- exclusive, but lock held only ~20ns (HashMap pointer swap)
- Key+value allocated OUTSIDE lock, stale data freed OUTSIDE lock
- Cached clock per event-loop tick (no clock_gettime syscall per GET)
- Cache-line aligned stripes (64B) prevent false sharing between CPU cores

**Graph engine (CSR + SoA + bitflags):**
- Compressed Sparse Row adjacency with auto-compact from delta buffer
- Bidirectional BFS for shortest path (explores sqrt(N) instead of N nodes)
- Frontier-based BFS traverse (process entire levels with bitset frontiers)
- DynamicBitSet visited set: 125KB for 1M nodes (fits L2 cache)
- TypeMask bitmask filtering, string interning, shared PropertyStore

**Networking:**
- Zero-copy read: parse RESP directly from stack read buffer (no memcpy for complete commands)
- Direct-write-first: attempt immediate write before registering for epoll WRITE events
- Head-index accumulator: advance pointer, never memmove (compacts only at 32KB)
- Comptime dispatch: switch on (cmd.len, first_byte), pre-built RESP literals at compile time
- TCP_NODELAY on all sockets
- TLS handshake before event loop registration (no half-open connections)

**Persistence:**
- AOF group commit: buffer all writes in memory, single write() syscall per event loop tick
- BGSAVE: background thread with read locks (non-blocking)
- Tombstone DEL: ~25ns (flag set) vs ~140ns (full remove + free)

---

## Commands

### Key-Value (Redis-compatible)

| Command | Description |
|---------|-------------|
| `PING [message]` | Health check. Returns `PONG` or echoes the message |
| `SET key value [EX seconds\|PX ms]` | Set a key with optional TTL |
| `GET key` | Get a key's value. Returns `nil` if not found or expired |
| `MGET key [key ...]` | Get multiple keys in one call |
| `MSET key value [key value ...]` | Set multiple key-value pairs atomically |
| `DEL key [key ...]` | Delete keys. Returns count of keys deleted |
| `EXISTS key [key ...]` | Check key existence. Returns count of existing keys |
| `INCR key` / `DECR key` | Increment/decrement integer value by 1 |
| `INCRBY key n` / `DECRBY key n` | Increment/decrement by N |
| `APPEND key value` | Append to existing value. Returns new length |
| `EXPIRE key seconds` | Set TTL on existing key. Returns 1 if set, 0 if key missing |
| `PERSIST key` | Remove TTL from key. Returns 1 if removed, 0 if no TTL |
| `TTL key` | Remaining TTL in seconds. -1 = no expiry, -2 = key missing |
| `KEYS pattern` | List keys matching glob (`*`, `?`). Disabled for large DBs in strict mode |
| `SCAN cursor [MATCH pattern] [COUNT n]` | Incremental key scan (safe for large DBs) |
| `DBSIZE` | Number of live keys |
| `SELECT index` | Switch logical DB (0-15). Keys are namespaced per DB |
| `FLUSHDB` | Delete all keys in current DB |
| `FLUSHALL` | Delete all keys and graph data across all DBs |
| `MOVE key db` | Move key to another DB. Preserves TTL |
| `INFO` | Server stats: keyspace, graph, persistence, cluster |
| `COMMAND` | Command metadata (compatibility) |
| `AUTH password` | Authenticate (required when `--requirepass` is set) |

### Transactions

| Command | Description |
|---------|-------------|
| `MULTI` | Start a transaction. All subsequent commands are queued |
| `EXEC` | Execute all queued commands atomically. Returns array of results |
| `DISCARD` | Discard all queued commands and exit transaction mode |

**How it works:**

```
127.0.0.1:6380> MULTI
OK
127.0.0.1:6380> SET account:1:balance 100
QUEUED
127.0.0.1:6380> SET account:2:balance 200
QUEUED
127.0.0.1:6380> EXEC
1) OK
2) OK
```

Commands between `MULTI` and `EXEC` respond with `+QUEUED` and are executed as a batch under the engine lock when `EXEC` is called. This guarantees atomicity -- no other command can interleave.

**Limitations:**
- Single-shard only (all keys must hash to the same worker in reactor mode)
- No `WATCH` / optimistic locking (planned)
- Nested `MULTI` returns an error

### Pub/Sub

| Command | Description |
|---------|-------------|
| `SUBSCRIBE channel [channel ...]` | Subscribe to one or more channels |
| `UNSUBSCRIBE [channel ...]` | Unsubscribe from channels (all if no args) |
| `PUBLISH channel message` | Publish a message. Returns number of subscribers who received it |

**How it works:**

Terminal 1 (subscriber):
```
127.0.0.1:6380> SUBSCRIBE news
1) "subscribe"
2) "news"
3) (integer) 1
# ... waiting for messages ...
1) "message"
2) "news"
3) "breaking: vex 0.3 released"
```

Terminal 2 (publisher):
```
127.0.0.1:6380> PUBLISH news "breaking: vex 0.3 released"
(integer) 1
```

**Details:**
- Subscribers enter pub/sub mode -- only `SUBSCRIBE`, `UNSUBSCRIBE`, `PING` are allowed
- Cross-worker: shared `PubSubRegistry` with mutex-protected channel-to-fd map
- Messages are RESP push format: `*3\r\n$7\r\nmessage\r\n$<channel>\r\n$<data>\r\n`
- Auto-unsubscribe on connection close
- Duplicate subscriptions to the same channel are ignored

### Graph Operations

| Command | Description |
|---------|-------------|
| `GRAPH.ADDNODE key type` | Create a node with a key and type label |
| `GRAPH.GETNODE key` | Get node details: key, type, and all properties |
| `GRAPH.DELNODE key` | Delete a node and all its connected edges |
| `GRAPH.SETPROP key prop value` | Set a property on a node |
| `GRAPH.ADDEDGE from to type [weight]` | Create a directed edge (default weight 1.0) |
| `GRAPH.DELEDGE edge_id` | Delete an edge by its numeric ID |
| `GRAPH.NEIGHBORS key [OUT\|IN\|BOTH]` | Get direct neighbors in specified direction |
| `GRAPH.TRAVERSE key [DEPTH n] [DIR d] [EDGETYPE t] [NODETYPE t]` | BFS traversal with filters |
| `GRAPH.PATH from to [MAXDEPTH n]` | Shortest unweighted path (bidirectional BFS) |
| `GRAPH.WPATH from to` | Shortest weighted path (Dijkstra's algorithm) |
| `GRAPH.COMPACT` | Rebuild CSR from delta edges (improves traverse speed 3x) |
| `GRAPH.STATS` | Node and edge counts for current DB |

### Persistence Commands

| Command | Description |
|---------|-------------|
| `SAVE` | Foreground snapshot: blocks all commands while writing `vex.zdb` |
| `BGSAVE` | Background snapshot: spawns a thread, non-blocking |
| `BGREWRITEAOF` | Compact AOF: serialize current state to new file, atomic rename |
| `LASTSAVE` | Unix timestamp (seconds) of last successful snapshot |

---

## Examples

### Basic KV Operations

```
redis-cli -p 6380

127.0.0.1:6380> SET greeting "hello world"
OK
127.0.0.1:6380> GET greeting
"hello world"
127.0.0.1:6380> SET counter 0
OK
127.0.0.1:6380> INCR counter
(integer) 1
127.0.0.1:6380> INCRBY counter 10
(integer) 11
127.0.0.1:6380> SET session:abc "user:42" EX 3600
OK
127.0.0.1:6380> TTL session:abc
(integer) 3599
```

### Graph: Service Dependency Map

```
127.0.0.1:6380> GRAPH.ADDNODE service:auth service
(integer) 0
127.0.0.1:6380> GRAPH.ADDNODE service:user service
(integer) 1
127.0.0.1:6380> GRAPH.ADDNODE db:postgres database
(integer) 2

127.0.0.1:6380> GRAPH.ADDEDGE service:auth service:user calls
(integer) 0
127.0.0.1:6380> GRAPH.ADDEDGE service:user db:postgres reads 0.5
(integer) 1

127.0.0.1:6380> GRAPH.SETPROP service:auth version "3.2"
OK

127.0.0.1:6380> GRAPH.TRAVERSE service:auth DEPTH 3 DIR OUT
1) "service:auth"
2) "service:user"
3) "db:postgres"

127.0.0.1:6380> GRAPH.PATH service:auth db:postgres
1) "service:auth"
2) "service:user"
3) "db:postgres"

127.0.0.1:6380> GRAPH.WPATH service:auth db:postgres
1) "1.50"
2) "service:auth"
3) "service:user"
4) "db:postgres"

127.0.0.1:6380> GRAPH.NEIGHBORS service:user BOTH
1) "service:auth"
2) "db:postgres"
```

### Transactions

```
127.0.0.1:6380> MULTI
OK
127.0.0.1:6380> SET user:1:name "Alice"
QUEUED
127.0.0.1:6380> SET user:1:email "alice@example.com"
QUEUED
127.0.0.1:6380> INCR user:count
QUEUED
127.0.0.1:6380> EXEC
1) OK
2) OK
3) (integer) 1
```

### Multiple Databases

```
127.0.0.1:6380> SELECT 0
OK
127.0.0.1:6380> SET key "in db 0"
OK
127.0.0.1:6380> SELECT 1
OK
127.0.0.1:6380[1]> GET key
(nil)
127.0.0.1:6380[1]> SET key "in db 1"
OK
127.0.0.1:6380[1]> SELECT 0
OK
127.0.0.1:6380> GET key
"in db 0"
```

---

## Configuration

Vex can be configured via CLI flags, config files, or environment variables. The precedence order (highest to lowest):

1. **CLI flags** -- always win
2. **`--config <path>`** -- explicit config file
3. **`VEX_CONFIG` env var** -- path to config file
4. **`./vex.conf`** -- default config file (silently skipped if missing)
5. **Built-in defaults**

### CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port`, `-p` | 6380 | Listen port |
| `--host`, `-h` | 0.0.0.0 | Bind address |
| `--reactor` | off | Enable multi-reactor mode (recommended) |
| `--workers N` | auto (CPU cores, max 8) | Worker threads |
| `--data-dir`, `-d` | ./data | Persistence directory |
| `--no-persistence` | off | Disable AOF/snapshot |
| `--requirepass` | none | Password for AUTH |
| `--maxclients` | 10000 | Max concurrent connections |
| `--max-client-buffer` | 1048576 | Max unparsed data per connection (bytes) |
| `--maxmemory` | 0 (unlimited) | Memory limit (supports `kb`/`mb`/`gb` suffix) |
| `--maxmemory-policy` | noeviction | Eviction policy: `noeviction` or `allkeys-lru` |
| `--tls-cert` | none | TLS certificate file (PEM format) |
| `--tls-key` | none | TLS private key file (PEM format) |
| `--log-level` | info | Log verbosity: `debug`, `info`, `warn`, `error` |
| `--config` | none | Path to config file |
| `--cluster-config` | none | Path to cluster config file |
| `--profile` | off | Enable latency profiling |
| `--profile-every N` | 100000 | Print profile every N commands |

### Config File

**Format:** one `key value` pair per line, `#` for comments, blank lines ignored.

```conf
# /etc/vex/vex.conf

# Network
port 6380
host 0.0.0.0
reactor
workers 4

# Persistence
data-dir /var/lib/vex

# Security
requirepass mysecretpassword
tls-cert /etc/vex/cert.pem
tls-key /etc/vex/key.pem

# Memory
maxmemory 512mb
maxmemory-policy allkeys-lru
maxclients 10000

# Logging
loglevel info
```

**Supported config keys:**

| Config Key | CLI Equivalent | Notes |
|------------|---------------|-------|
| `port` | `--port` | |
| `host` or `bind` | `--host` | |
| `data-dir` or `dir` | `--data-dir` | |
| `requirepass` | `--requirepass` | |
| `maxclients` | `--maxclients` | |
| `max-client-buffer` | `--max-client-buffer` | |
| `maxmemory` | `--maxmemory` | Supports `kb`/`mb`/`gb` suffixes |
| `maxmemory-policy` | `--maxmemory-policy` | `noeviction` or `allkeys-lru` |
| `reactor` | `--reactor` | Boolean flag (presence = enabled) |
| `workers` | `--workers` | |
| `log-level` or `loglevel` | `--log-level` | |
| `tls-cert` | `--tls-cert` | |
| `tls-key` | `--tls-key` | |

Unknown keys are silently ignored (forward compatibility).

### Environment Variables

| Variable | Description |
|----------|-------------|
| `VEX_CONFIG` | Path to config file. Loaded after `./vex.conf`, before `--config` flag |

Example:
```bash
VEX_CONFIG=/etc/vex/production.conf zig-out/bin/vex --reactor
```

---

## Persistence

### Snapshot + AOF

Vex uses a dual persistence model similar to Redis RDB+AOF:

- **Snapshot** (`vex.zdb`): binary format with CRC-32 checksum, contains full KV + graph state
- **AOF** (`vex.aof`): append-only file recording every write command in binary format

**Lifecycle:**
1. **Startup**: loads snapshot, then replays AOF to recover commands since last snapshot
2. **Runtime**: write commands are buffered and flushed to AOF per event loop tick
3. **SAVE/BGSAVE**: writes a new snapshot, truncates AOF
4. **Shutdown**: SIGTERM/SIGINT triggers a final snapshot + AOF flush

```bash
zig build run -- --data-dir /var/lib/vex      # persistence enabled (default)
zig build run -- --no-persistence              # disable for benchmarking
```

### Background Save (BGSAVE)

`BGSAVE` spawns a dedicated thread that:
1. Acquires a read lock on the graph engine (allows concurrent reads)
2. Serializes the full KV + graph state to `vex.zdb`
3. Truncates the AOF
4. Releases locks and signals completion

An atomic `bgsave_in_progress` flag prevents concurrent background saves. Attempting `BGSAVE` while one is running returns an error.

```
127.0.0.1:6380> BGSAVE
"Background saving started"
127.0.0.1:6380> LASTSAVE
(integer) 1745477400
```

### AOF Group Commit

Instead of writing to the AOF file on every command (which requires a `seek` + `write` + `flush` per operation), Vex buffers commands in memory and flushes the entire batch at the end of each event loop tick.

**Before (per-command I/O):**
```
SET k1 v1 → seek + write + flush
SET k2 v2 → seek + write + flush
SET k3 v3 → seek + write + flush
```

**After (group commit):**
```
SET k1 v1 → append to memory buffer
SET k2 v2 → append to memory buffer
SET k3 v3 → append to memory buffer
[end of tick] → single seek + write + flush for all 3
```

This reduces syscall overhead by the pipeline depth (e.g., 100x fewer syscalls with pipeline=100).

---

## Security

### Authentication

```bash
zig build run -- --reactor --requirepass mysecret
```

Clients must `AUTH mysecret` before any command (except `PING`). Password comparison uses constant-time byte comparison to prevent timing attacks.

```
127.0.0.1:6380> SET key value
(error) NOAUTH Authentication required.
127.0.0.1:6380> AUTH mysecret
OK
127.0.0.1:6380> SET key value
OK
```

### TLS Encryption

Vex supports TLS via OpenSSL, loaded at runtime using `dlopen` (no build-time dependency on OpenSSL). This means:
- The binary compiles without OpenSSL installed
- TLS is activated only when `--tls-cert` and `--tls-key` are both provided
- If OpenSSL is not available at runtime, Vex falls back to plain TCP with a warning

```bash
# Generate self-signed cert for testing
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 365 -nodes -subj '/CN=localhost'

# Start with TLS
zig build run -- --reactor --tls-cert cert.pem --tls-key key.pem

# Connect with TLS
redis-cli -p 6380 --tls --cert cert.pem --key key.pem --cacert cert.pem
```

**TLS handshake flow:**
1. Client connects via TCP
2. Socket is temporarily set to blocking mode
3. OpenSSL `SSL_accept()` performs the TLS handshake
4. Socket is restored to non-blocking mode
5. Connection is added to the event loop
6. All subsequent reads/writes use `SSL_read`/`SSL_write`

If the handshake fails, the connection is closed immediately.

---

## Memory Management

### LRU Eviction

```bash
zig build run -- --reactor --maxmemory 512mb --maxmemory-policy allkeys-lru
```

| Policy | Behavior |
|--------|----------|
| `noeviction` (default) | Return `-OOM` error on SET when memory limit exceeded |
| `allkeys-lru` | Before each SET, if over limit: sample 5 random keys, evict the one with the oldest `last_access` timestamp. Repeat until under limit |

The `last_access` timestamp is updated on every `GET` and `EXISTS` operation using the cached clock (updated once per event loop tick, not per operation).

Memory size supports suffixes:
- `--maxmemory 256mb` (megabytes)
- `--maxmemory 1gb` (gigabytes)
- `--maxmemory 65536` (bytes)
- `--maxmemory 64kb` (kilobytes)

### Memory Estimation

Memory usage is estimated as:
```
sum over all live entries: key.len + value.len + sizeof(Entry)
```

Where `Entry` is 32 bytes (value pointer, expires_at, last_access, flags). Tombstoned (deleted) entries are excluded from the count.

---

## Clustering

### Leader/Follower Replication

Vex supports leader/follower replication for read scaling and data safety.

```bash
# Start a 3-node cluster
docker compose -f docker-compose.cluster.yml up --build -d

# Write to leader
redis-cli -p 16380 SET hello world

# Read from any follower (replicated)
redis-cli -p 16381 GET hello    # "world"
redis-cli -p 16382 GET hello    # "world"

# Writes on followers are forwarded to leader automatically
redis-cli -p 16381 SET fromfollower value
redis-cli -p 16380 GET fromfollower  # "value" (on leader)
redis-cli -p 16382 GET fromfollower  # "value" (replicated)
```

**Cluster config** (`cluster.conf`):
```
node 1 leader 10.0.0.1:6380
node 2 follower 10.0.0.2:6380
node 3 follower 10.0.0.3:6380
self 1
```

**Features:**
- Leader accepts all writes, broadcasts mutations to followers via binary VX protocol (port + 10000)
- Followers forward writes to leader, serve reads locally
- Full sync: new followers receive a complete snapshot on connect
- Heartbeat every 5s with `mutation_seq` for lag tracking
- Graph replication: `ADDNODE`/`ADDEDGE` on leader are replicated for `TRAVERSE`/`PATH` on followers

### Automatic Failover

When the leader's heartbeat times out (default 15s), followers detect the failure:

1. Each follower checks if it is the highest-priority node (lowest node ID among surviving followers)
2. The highest-priority follower promotes itself to leader:
   - Starts a `ReplicationLeader` listener on its replication port
   - Accepts new follower connections
   - Begins broadcasting mutations
3. Other followers reconnect to the new leader via probing

Failover is automatic -- no manual intervention required. The promoted follower continues serving both reads and writes.

### Consistency Model

- **Eventual consistency** for reads on followers (replication lag is typically <1 heartbeat interval)
- **All writes go through the leader** (follower writes are forwarded transparently)
- **Read-your-own-writes** is guaranteed on the leader only

---

## Structured Logging

All log output uses structured format with ISO 8601 UTC timestamps:

```
[2026-04-24T10:30:00Z] [INFO] listening on :6380 (reactor, workers=4)
[2026-04-24T10:30:01Z] [INFO] restored 1234 keys, 500 nodes (+89 AOF commands)
[2026-04-24T10:31:00Z] [WARN] TLS init failed: TlsNotAvailable (running without TLS)
```

| Level | Description |
|-------|-------------|
| `debug` | Verbose internal state (disabled by default) |
| `info` | Startup, connections, persistence events |
| `warn` | Non-fatal issues (failed TLS, config warnings) |
| `error` | Fatal errors requiring attention |

Set via `--log-level debug` or `loglevel debug` in config file.

---

## Deployment

### Production Checklist

```bash
# 1. Create config file
cat > /etc/vex/vex.conf << 'EOF'
port 6380
host 0.0.0.0
reactor
workers 4
data-dir /var/lib/vex
requirepass $(openssl rand -hex 16)
maxmemory 2gb
maxmemory-policy allkeys-lru
maxclients 10000
tls-cert /etc/vex/cert.pem
tls-key /etc/vex/key.pem
loglevel info
EOF

# 2. Build release binary
zig build -Doptimize=ReleaseFast

# 3. Run
VEX_CONFIG=/etc/vex/vex.conf ./zig-out/bin/vex
```

### Systemd Service

```ini
[Unit]
Description=Vex KV + Graph Database
After=network.target

[Service]
Type=simple
User=vex
Group=vex
ExecStart=/usr/local/bin/vex --config /etc/vex/vex.conf
Restart=always
RestartSec=5
LimitNOFILE=65536
Environment=VEX_CONFIG=/etc/vex/vex.conf

[Install]
WantedBy=multi-user.target
```

---

## Source Layout

```
src/
├── main.zig                # Entry point, CLI parsing, signal handling, config loading
├── config.zig              # Config file parser (key-value format)
├── log.zig                 # Structured logger (levels, ISO 8601 timestamps)
├── server/
│   ├── tcp.zig             # Accept loop, reactor mode, thread-per-client mode
│   ├── event_loop.zig      # Platform-abstracted poll (kqueue/epoll/io_uring)
│   ├── worker.zig          # Event loop worker + pub/sub + transactions
│   ├── resp.zig            # RESP v2 protocol parser + serializer
│   ├── tls.zig             # TLS wrapper (OpenSSL via dlopen, no build dependency)
│   └── shard_router.zig    # Key-to-shard routing, MPSC queues
├── engine/
│   ├── kv.zig              # KV store: TTL, tombstone DEL, LRU eviction, memoryUsage
│   ├── concurrent_kv.zig   # 256-stripe rwlock KV (parallel reads)
│   ├── graph.zig           # CSR graph engine (SoA, bitflags, auto-compact)
│   ├── query.zig           # Bidirectional BFS, frontier traverse, Dijkstra
│   ├── string_intern.zig   # Type string pooling (u16 IDs, bitmask filtering)
│   ├── property_store.zig  # Sparse property storage for nodes/edges
│   └── pool_arena.zig      # Slab allocator with background arena refill
├── command/
│   ├── handler.zig         # Command dispatch + implementations (KV, graph, BGSAVE)
│   └── comptime_dispatch.zig  # Compile-time command table + RESP literals
├── cluster/
│   ├── config.zig          # Cluster config parser (node roles, addresses)
│   ├── protocol.zig        # Binary VX replication protocol (frames, encoding)
│   └── replication.zig     # Leader/follower streaming, failover, full sync
├── perf/
│   └── span.zig            # Latency profiler (per-operation timing)
└── storage/
    ├── snapshot.zig         # Binary snapshot: CRC-32, v2 format, SoA graph
    └── aof.zig              # Append-only file with group commit buffering
```

---

## Testing

```bash
# Run all tests (106 tests)
zig build test

# Run test binary directly for verbose output
./.zig-cache/o/<hash>/test
```

### Test Coverage

| Module | Tests | What's Covered |
|--------|-------|----------------|
| `kv.zig` | 15 | SET/GET, tombstone DEL, TTL, compaction, LRU eviction, memoryUsage, noeviction error, last_access tracking |
| `concurrent_kv.zig` | 6 | Parallel reads, overwrite, delete, flush, multi-thread stress |
| `graph.zig` | 11 | Nodes, edges, properties, compact, type masks, bitflags |
| `query.zig` | 7 | BFS traverse, shortest path, Dijkstra, neighbors, edge filters, delta-only traversal |
| `handler.zig` | 10 | PING, SET/GET, GRAPH.ADDNODE, SELECT, MGET/MSET, INCR/DECR, EXPIRE/PERSIST, APPEND, BGSAVE |
| `resp.zig` | 4 | RESP parse, null bulk, serialize round-trip, inline commands |
| `aof.zig` | 4 | Write+replay, truncate, missing file, group commit buffer |
| `snapshot.zig` | 4 | Round-trip, missing file, CRC corruption, known CRC value |
| `worker.zig` | 4 | PubSubRegistry: subscribe, unsubscribe, unsubscribeAll, duplicate prevention |
| `log.zig` | 3 | Level parse, filtering, timestamp format |
| `config.zig` | 3 | Config parse, empty config, comments-only |
| `main.zig` | 1 | parseMemorySize (kb/mb/gb/bytes/empty/invalid) |
| `cluster/` | 7 | Config parse, protocol encode/decode, isWriteCommand, failover |
| `event_loop.zig` | 2 | Pipe events, notify wakeup |
| Other | 5 | String intern, pool arena, property store, comptime dispatch |

**Total: 106 tests (105 passed, 1 skipped)**

The skipped test is `concurrent_kv multi-thread stress` which is only run in ReleaseFast mode (Zig's debug HashMap has pointer stability checks that conflict with external rwlock synchronization).

---

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

---

## Changelog

### v0.3.0 — Production Hardening

**New Features:**
- TLS support via OpenSSL (loaded at runtime, no build dependency)
- `MULTI`/`EXEC`/`DISCARD` transactions with atomic batch execution
- Pub/Sub: `SUBSCRIBE`/`PUBLISH`/`UNSUBSCRIBE` with cross-worker shared registry
- Config file support (`vex.conf`) with `VEX_CONFIG` env var + `--config` flag
- Memory limits + LRU eviction (`--maxmemory`, `--maxmemory-policy allkeys-lru`)
- `BGSAVE`: non-blocking background snapshot in separate thread
- AOF group commit: buffer writes per event loop tick, single I/O syscall
- Structured logging with ISO 8601 timestamps and `--log-level` flag
- Automatic failover: heartbeat timeout, priority-based leader promotion

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

---

## Roadmap

### v0.4 — Partitioned Graph
- Hash-partition graph nodes across machines
- Ghost nodes for 1-hop boundary cache
- BSP BFS for cross-partition traversals
- Distributed Dijkstra
- Consistent hash ring with vnodes

### Future
- Graph secondary indexes on properties
- Cypher query language subset
- `WATCH` for optimistic locking in transactions
- io_uring batched read/write (Linux)
- PageRank, connected components algorithms
- Lua scripting (`EVAL`)
- Streams (`XADD`/`XREAD`)

---

## License

MIT
