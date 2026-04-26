# Vex

A high-performance KV + Graph database written in Zig 0.16. Speaks the Redis protocol (RESP), so you can connect with `redis-cli` or any Redis client library.

## Why Vex?

- **Up to 2x faster than Redis** on same-machine workloads (`redis-benchmark` UDS: 7.81M GET rps vs 4.72M)
- **22x faster shortest path than Memgraph** via bidirectional BFS + CSR adjacency
- **Wins all 5 graph operations** vs Memgraph (add, traverse, path, neighbors)
- **Redis-compatible** -- works with every Redis client library
- **Zero dependencies** -- pure Zig standard library, single binary
- **Production features** -- TLS, transactions, pub/sub, LRU eviction, background saves, config files, structured logging, clustering with automatic failover

## Documentation

| Page | Description |
|------|-------------|
| **[Commands](docs/commands.md)** | Full command reference: KV, graph, transactions, pub/sub, persistence |
| **[Configuration](docs/configuration.md)** | CLI flags, config file format, environment variables, precedence |
| **[Architecture](docs/architecture.md)** | System design, why it's fast, source layout, event loop, connection lifecycle |
| **[Persistence](docs/persistence.md)** | Snapshot format, AOF, BGSAVE, group commit, durability guarantees |
| **[Security](docs/security.md)** | Authentication, TLS encryption, OpenSSL loading, handshake flow |
| **[Memory Management](docs/memory.md)** | maxmemory, LRU eviction, access tracking, memory estimation |
| **[Pub/Sub](docs/pubsub.md)** | SUBSCRIBE/PUBLISH/UNSUBSCRIBE, cross-worker delivery, pub/sub mode |
| **[Transactions](docs/transactions.md)** | MULTI/EXEC/DISCARD, atomicity, error handling, limitations |
| **[Clustering](docs/clustering.md)** | Leader/follower replication, automatic failover, consistency model |
| **[Benchmarks](docs/benchmarks.md)** | KV vs Redis, graph vs Memgraph, internal engine benchmarks |
| **[Deployment](docs/deployment.md)** | Production checklist, systemd, Docker, tuning |
| **[Testing](docs/testing.md)** | 107 tests, coverage table, test patterns |

---

## Quick Start

### Docker (easiest)

```bash
docker run -p 6380:6380 ghcr.io/pratyush-sngh/vex:latest --reactor
redis-cli -p 6380
```

### Build from Source

```bash
zig build                                          # Build
zig build run -- --reactor                        # Reactor mode (recommended)
zig build test                                     # Run tests (107 tests)
redis-cli -p 6380                                  # Connect
```

Or with a config file:
```bash
cat > vex.conf << 'EOF'
port 6380
reactor
workers 4
maxmemory 256mb
maxmemory-policy allkeys-lru
loglevel info
EOF
zig build run
```

Workers auto-detect from CPU core count (capped at 8). See [Configuration](docs/configuration.md) for all options, [Deployment](docs/deployment.md) for Docker details.

---

## Benchmarks

Benchmarked with **`redis-benchmark`** (industry standard). Docker containers with **equal, isolated resources**: 4 CPU cores + 4GB RAM each, CPU-pinned (`cpuset`). See [Benchmarks](docs/benchmarks.md) for full methodology, UDS results, and internal engine numbers.

### KV: Vex vs Redis 8.0 (`redis-benchmark`, P=50, c=16)

| Command | Redis TCP | Vex TCP | TCP Δ | Redis UDS | Vex UDS | UDS Δ |
|---|---|---|---|---|---|---|
| GET | 1.55M | **1.79M** | **+15%** | 4.72M | **7.81M** | **+66%** |
| SET | 1.52M | **1.71M** | **+13%** | 3.76M | **4.95M** | **+32%** |
| LPOP | 1.84M | **2.12M** | **+15%** | 3.05M | **5.56M** | **+82%** |
| HSET | 1.42M | **1.54M** | **+9%** | 3.65M | **4.72M** | **+29%** |
| SADD | 1.61M | **1.72M** | **+7%** | 4.39M | **5.88M** | **+34%** |

Single-command (no pipeline): tied at ~46K rps -- network-bound. UDS is 2-4x faster than TCP for both.

### Graph: Vex vs Memgraph (10K nodes / 50K edges)

| Operation | Memgraph | Vex | Speedup |
|---|---|---|---|
| Shortest Path | 4,524 us | **210 us** | **22x faster** |
| AddNode | 175.4 us | **138.1 us** | **+21%** |
| AddEdge | 185.9 us | **140.5 us** | **+24%** |
| Traverse (depth 3) | 334 us | **228 us** | **+32%** |
| Neighbors | 202 us | **130 us** | **+36%** |

Full benchmark data, single-command results, and methodology: [Benchmarks](docs/benchmarks.md)

---

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

127.0.0.1:6380> GRAPH.PATH service:auth service:user
1) "service:auth"
2) "service:user"

127.0.0.1:6380> MULTI
OK
127.0.0.1:6380> SET k1 v1
QUEUED
127.0.0.1:6380> SET k2 v2
QUEUED
127.0.0.1:6380> EXEC
1) OK
2) OK

127.0.0.1:6380> SUBSCRIBE news
1) "subscribe"
2) "news"
3) (integer) 1
```

---

## Features at a Glance

| Feature | Details |
|---------|---------|
| **Strings** | SET/GET/DEL/MGET/MSET/INCR/DECR/APPEND/EXPIRE/SETNX/GETSET + 20 more |
| **Lists** | LPUSH/RPUSH/LPOP/RPOP/LLEN/LRANGE/LINDEX/LSET/LREM |
| **Hashes** | HSET/HGET/HDEL/HGETALL/HLEN/HEXISTS/HMSET/HMGET/HKEYS/HVALS/HINCRBY |
| **Sets** | SADD/SREM/SMEMBERS/SISMEMBER/SCARD/SUNION/SINTER/SDIFF |
| **Sorted Sets** | ZADD/ZREM/ZRANGE/ZSCORE/ZRANK/ZCARD/ZINCRBY/ZCOUNT |
| **Graph** | ADDNODE/ADDEDGE/TRAVERSE/PATH/WPATH/NEIGHBORS + 6 more |
| **Transactions** | MULTI/EXEC/DISCARD + WATCH/UNWATCH optimistic locking |
| **Pub/Sub** | SUBSCRIBE/PUBLISH/UNSUBSCRIBE/PSUBSCRIBE/PUNSUBSCRIBE |
| **Persistence** | Snapshot (CRC-32) + AOF with group commit + BGSAVE |
| **TLS** | OpenSSL via dlopen -- no build dependency |
| **Memory Limits** | --maxmemory with noeviction or allkeys-lru |
| **Auth** | --requirepass with constant-time comparison |
| **Client Compat** | CONFIG GET/SET, CLIENT ID/LIST/SETNAME, OBJECT, TIME, RESET |
| **Config File** | Auto-load `vex.conf` + `VEX_CONFIG` env + `--config` flag |
| **Logging** | Structured ISO 8601 timestamps, 4 levels |
| **Clustering** | Leader/follower replication + automatic failover |
| **Multi-DB** | 16 logical databases (SELECT 0-15) |

---

## Architecture

```
              Accept Thread (main)
              /    |    |    \
         Worker0  W1   W2   W3     -- N event-loop threads
         (kqueue) ...              -- kqueue/epoll/io_uring
         /  |  \
      conn conn conn               -- non-blocking I/O
            |
   ConcurrentKV                    -- 256-stripe rwlock
   GraphEngine                     -- CSR + bidirectional BFS
   PubSubRegistry                  -- shared subscriber map
   AOF (group commit)              -- batched persistence
```

Deep dive: [Architecture](docs/architecture.md)

---

## Source Layout

```
src/
├── main.zig              # Entry point, CLI, config loading
├── config.zig            # Config file parser
├── log.zig               # Structured logger
├── server/
│   ├── tcp.zig           # Accept loop, reactor mode
│   ├── worker.zig        # Event loop worker + pub/sub + transactions
│   ├── event_loop.zig    # kqueue/epoll/io_uring abstraction
│   ├── resp.zig          # RESP v2 protocol
│   └── tls.zig           # TLS (OpenSSL via dlopen)
├── engine/
│   ├── kv.zig            # KV store + LRU eviction
│   ├── concurrent_kv.zig # 256-stripe rwlock KV
│   ├── list.zig          # List data type (deque)
│   ├── hash.zig          # Hash data type (field maps)
│   ├── set.zig           # Set data type (unique members)
│   ├── sorted_set.zig    # Sorted set (score-ordered)
│   ├── graph.zig         # CSR graph engine
│   └── query.zig         # BFS, Dijkstra, traversal
├── command/
│   └── handler.zig       # Command dispatch + BGSAVE
├── cluster/
│   └── replication.zig   # Leader/follower + failover
└── storage/
    ├── snapshot.zig       # Binary snapshot (CRC-32)
    └── aof.zig            # AOF with group commit
```

---

## Changelog

### v0.5.0 -- Sets & Sorted Sets
Sets (SADD/SREM/SMEMBERS/SISMEMBER/SCARD/SUNION/SINTER/SDIFF), Sorted Sets (ZADD/ZREM/ZRANGE/ZSCORE/ZRANK/ZCARD/ZINCRBY/ZCOUNT). All 5 Redis data types now supported.

### v0.4.0 -- Lists, Hashes & WATCH
Lists (LPUSH/RPUSH/LPOP/RPOP/LLEN/LRANGE/LINDEX/LSET/LREM), Hashes (HSET/HGET/HDEL/HGETALL/HLEN/HEXISTS/HMSET/HMGET/HKEYS/HVALS/HINCRBY), WATCH/UNWATCH optimistic locking. 30 Redis compatibility commands (CONFIG, CLIENT, COPY, UNLINK, PSUBSCRIBE, TIME, OBJECT, RESET, etc.).

### v0.3.0 -- Production Hardening
TLS, MULTI/EXEC, pub/sub, LRU eviction, BGSAVE, AOF group commit, config files, structured logging, automatic failover.

### v0.2.0 -- Distributed KV + Graph Read Replicas
Leader/follower replication, full sync, heartbeat lag tracking, write forwarding.

### v0.1.0 -- Initial Release
Redis-compatible KV + graph DB with multi-reactor architecture.

---

## Roadmap

### v0.6 -- Partitioned Graph
- Hash-partition graph nodes across machines
- Ghost nodes for 1-hop boundary cache
- BSP BFS for cross-partition traversals
- Distributed Dijkstra
- Consistent hash ring with vnodes

### v0.7 -- Performance & Internals
- Custom concurrent hashmap (replace Zig std HashMap for thread-safe resize under concurrent writes)
- Sorted set skip list (O(log n) ZRANGE/ZRANK instead of O(n log n) sort-per-query)
- Streams (`XADD`/`XREAD`/`XRANGE`/`XLEN`)
- Persistence for lists, hashes, sets, sorted sets (snapshot + AOF)
- io_uring batched read/write (Linux)

### v0.8 -- Scripting & Query
- Lua scripting (`EVAL`/`EVALSHA`)
- Graph secondary indexes on properties
- Cypher query language subset

---

## License

MIT
