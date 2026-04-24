# Vex

A high-performance KV + Graph database written in Zig 0.16. Speaks the Redis protocol (RESP), so you can connect with `redis-cli` or any Redis client library.

## Why Vex?

- **Up to 34% faster than Redis** on pipelined KV workloads with equal resources (3.00M GET cmd/s)
- **18x faster shortest path than Memgraph** via bidirectional BFS + CSR adjacency
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

```bash
zig build                                          # Build
zig build run                                      # Run (port 6380, ./data/)
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

Workers auto-detect from CPU core count (capped at 8). See [Configuration](docs/configuration.md) for all options.

---

## Benchmarks

All benchmarks run in Docker with **equal, isolated resources**: 4 CPU cores + 4GB RAM per container, CPU-pinned (`cpuset`) to prevent cross-container interference. Vex capped at 4 reactor workers. Median of 5 runs, 1000 warmup ops discarded. See [Benchmarks](docs/benchmarks.md) for full methodology.

### KV: Vex vs Redis 8.0 (pipelined, c=16)

| Command | Redis | Vex | Speedup |
|---|---|---|---|
| PIPE-SET(100) | 1.82M cmd/s | **2.33M cmd/s** | **+28%** |
| PIPE-GET(100) | 2.40M cmd/s | **2.99M cmd/s** | **+25%** |
| PIPE-INCR(100) | 2.44M cmd/s | **2.58M cmd/s** | **+6%** |
| PIPE-EXISTS(100) | 2.45M cmd/s | **2.88M cmd/s** | **+18%** |
| PIPE-DEL(100) | 2.09M cmd/s | **2.69M cmd/s** | **+29%** |

Single-command (SET, GET, DEL, EXISTS, INCR, APPEND, MSET, MGET): tied at ~41K ops/s -- network-bound.

### Graph: Vex vs Memgraph (10K nodes / 50K edges)

| Operation | Memgraph | Vex | Speedup |
|---|---|---|---|
| Shortest Path | 4,029 us | **213 us** | **19x faster** |
| AddNode | 176.5 us | **137.6 us** | **+22%** |
| AddEdge | 190.8 us | **138.2 us** | **+28%** |
| Traverse (depth 3) | 283 us | **263 us** | **+7%** |
| Neighbors | 255 us | **138 us** | **+46%** |

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
| **KV Commands** | SET/GET/DEL/MGET/MSET/INCR/DECR/APPEND/EXPIRE/PERSIST + 15 more |
| **Graph Commands** | ADDNODE/ADDEDGE/TRAVERSE/PATH/WPATH/NEIGHBORS + 6 more |
| **Transactions** | MULTI/EXEC/DISCARD -- atomic batch execution under engine lock |
| **Pub/Sub** | SUBSCRIBE/PUBLISH/UNSUBSCRIBE -- cross-worker shared registry |
| **Persistence** | Snapshot (CRC-32) + AOF with group commit + BGSAVE |
| **TLS** | OpenSSL via dlopen -- no build dependency |
| **Memory Limits** | --maxmemory with noeviction or allkeys-lru |
| **Auth** | --requirepass with constant-time comparison |
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

### v0.3.0 -- Production Hardening
TLS, MULTI/EXEC, pub/sub, LRU eviction, BGSAVE, AOF group commit, config files, structured logging, automatic failover. [Full details](docs/commands.md)

### v0.2.0 -- Distributed KV + Graph Read Replicas
Leader/follower replication, full sync, heartbeat lag tracking, write forwarding. [Clustering docs](docs/clustering.md)

### v0.1.0 -- Initial Release
Redis-compatible KV + graph DB with multi-reactor architecture.

---

## Roadmap

### v0.4 -- Partitioned Graph
- Hash-partition graph nodes across machines
- Ghost nodes for 1-hop boundary cache
- BSP BFS for cross-partition traversals
- Distributed Dijkstra
- Consistent hash ring with vnodes

### Future
- Graph secondary indexes on properties
- Cypher query language subset
- `WATCH` for optimistic locking
- io_uring batched read/write (Linux)
- Lua scripting (`EVAL`)
- Streams (`XADD`/`XREAD`)

---

## License

MIT
