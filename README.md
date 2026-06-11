# Vex

A high-performance KV + Graph database written in Zig. Drop-in Redis replacement: 20-40% faster per instance on pipelined workloads, and up to 2.7x Redis throughput unpipelined once concurrency exceeds ~12 connections. Same ops, same clients, same horizontal scaling model -- fewer instances for the same throughput.

## Why Vex?

**Same scaling model as Redis, better per-instance performance.**

Redis is single-threaded. To scale, you add more instances. Vex does the same -- but each instance uses 4-8 cores efficiently via multi-reactor architecture with lock-free reads. You need 20-40% fewer instances for the same throughput.

| | Redis | Vex | Dragonfly |
|---|---|---|---|
| Sweet spot | 1 core | 4-8 cores | 32-64 cores |
| Scale model | Add instances | Add instances | Bigger machine |
| K8s / Docker | Small pods | Small pods | Huge pod |
| Failure blast radius | 1 instance | 1 instance | Everything |
| Protocol | RESP | RESP (compatible) | RESP (compatible) |

- **20-40% faster than Redis** on pipelined workloads with equal resources (4 cores, `redis-benchmark`, median of 30 runs)
- **Up to 2.7x Redis throughput unpipelined** (the default for most Redis clients): +30% at 16 connections, +166% at 128 (SET, 4 workers); parity ±13% below 12 connections where both servers are RTT-bound
- **Beats Dragonfly** at 4 cores (+16% to +201%) -- shared-nothing routing overhead loses to striped locks at moderate core counts
- **22x faster shortest path than Memgraph** via bidirectional BFS + CSR adjacency + Contraction Hierarchies
- **Redis-compatible** -- works with `redis-cli`, redis-py, Jedis, go-redis, ioredis, any Redis client
- **Built-in graph engine** -- TRAVERSE, PATH, WPATH (CH-accelerated), NEIGHBORS on the same data store
- **Zero dependencies** -- pure Zig standard library, single binary
- **Vector search + GRAPH.RAG** -- HNSW ANN search on graph nodes, semantic search → graph traversal in one command
- **Production features** -- TLS, MULTI/EXEC, pub/sub, WATCH, LRU eviction, BGSAVE, clustering with automatic failover

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
| **[Clustering](docs/clustering.md)** | Leader/follower replication, epoch mechanism, VEX.PROMOTE, consistency model |
| **[Observability](docs/observability.md)** | INFO, SLOWLOG, LATENCY, CLIENT LIST, DEBUG/MEMORY/CONFIG, JSON logs, redis_exporter |
| **[Separation of Concerns](docs/separation-of-concerns.md)** | How vex / vex-sentinel / sidecars are split. Mechanism vs policy. |
| **[Benchmarks](docs/benchmarks.md)** | KV vs Redis (pipelined + unpipelined), graph vs Memgraph, internal engine benchmarks |
| **[Unpipelined Command Grids](docs/unpipelined-command-grids.md)** | Per-command vex-vs-Redis deltas across workers × connections |
| **[Deployment](docs/deployment.md)** | Production checklist, systemd, Docker, tuning |
| **[Vector Search & GRAPH.RAG](docs/vector-search.md)** | HNSW vector search, f16 mmap storage, RAG pipeline examples |
| **[Vector Benchmarks](docs/vector-benchmarks.md)** | Benchmark design: Vex vs Redis+RediSearch vs Qdrant vs Weaviate |
| **[LLM Ecosystem](docs/llm-ecosystem.md)** | How Vex fits into LLM infrastructure: GraphRAG, semantic cache, agent memory, MCP |
| **[GraphRAG](docs/graphrag.md)** | Enhanced vector search + knowledge graph traversal for RAG pipelines |
| **[Semantic Cache](docs/semantic-cache.md)** | Cache LLM responses by query meaning, not exact match |
| **[Agent Memory](docs/agent-memory.md)** | Persistent memory primitives for LLM agents with decay and relationships |
| **[MCP Server](docs/mcp-server.md)** | Model Context Protocol support -- LLMs use Vex as a tool directly |
| **[Testing](docs/testing.md)** | 168 tests, coverage table, test patterns |

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
zig build test                                     # Run tests (168 tests)
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
| LPUSH | 1.02M | **1.27M** | **+24%** | 3.03M | **7.94M** | **+162%** |
| HSET | 879K | **1.12M** | **+27%** | 3.49M | **8.11M** | **+132%** |
| RPUSH | 1.05M | **1.34M** | **+27%** | 3.90M | **8.57M** | **+120%** |
| ZADD | 891K | **1.18M** | **+32%** | 3.33M | **6.98M** | **+109%** |
| SADD | 1.12M | **1.34M** | **+20%** | 4.17M | **7.50M** | **+79%** |
| INCR | 958K | **1.31M** | **+37%** | 4.13M | **6.17M** | **+49%** |
| SET | 1.08M | **1.22M** | **+13%** | 3.62M | **4.59M** | **+27%** |
| GET | 1.15M | **1.34M** | **+17%** | 5.68M | **7.14M** | **+26%** |
| LPOP | 1.52M | **1.64M** | **+8%** | 6.00M | **6.82M** | **+13%** |
| RPOP | 1.54M | **1.65M** | **+7%** | 6.00M | **7.32M** | **+22%** |

Vex wins **10/10 TCP** (+7% to +37%), **10/10 UDS** (+13% to +162%). At P=100 c=32 UDS: ZADD +236%, LPUSH +224%, HSET +178%. Full results: [Benchmarks](docs/benchmarks.md)

### KV unpipelined (one command per round-trip — the default for most clients)

SET vs Redis 8.0.3, vex `--workers 4`, AWS c5a.2xlarge (8 vCPU), 50k ops x 3 runs:

| Connections | 4 | 8 | 16 | 32 | 64 | 128 |
|---|---|---|---|---|---|---|
| Vex Δ vs Redis | −13% | −4% | **+30%** | **+109%** | **+138%** | **+166%** |

Below ~12 connections both servers are RTT-bound and effectively tied (vex wins +13-38% at c≤2, dips at exactly c=4, parity by c=8). From c=16 up, Redis saturates its single thread (~110k ops/s) while vex keeps scaling to ~300k. Per-command grids across w={1,2,4,6,8} x c={1..128}: [Benchmarks](docs/benchmarks.md)

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

# Vector search + graph expansion (RAG)
127.0.0.1:6380> GRAPH.ADDNODE doc:1 document
(integer) 0
127.0.0.1:6380> GRAPH.ADDNODE topic:ai topic
(integer) 1
127.0.0.1:6380> GRAPH.ADDEDGE doc:1 topic:ai about
(integer) 0
127.0.0.1:6380> GRAPH.SETVEC doc:1 embedding <f32_bytes>
OK
127.0.0.1:6380> GRAPH.RAG embedding <query_bytes> K 5 DEPTH 1 DIR OUT
1) 1) "doc:1"
   2) "0.9523"
   3) 1) "title"  2) "Attention Is All You Need"
   4) 1) "topic:ai"
```

See [Vector Search & GRAPH.RAG](docs/vector-search.md) for full RAG pipeline examples with Python.

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
| **Vector Search** | GRAPH.SETVEC/GETVEC/VECSEARCH + GRAPH.RAG (search + traverse in one call) |
| **GraphRAG** | GRAPH.RAG (subgraph returns) + GRAPH.COOCCUR (auto entity linking) |
| **Semantic Cache** | CACHE.SEMSET/SEMGET -- cache LLM responses by query meaning |
| **Agent Memory** | MEMORY.STORE/RECALL/RELATE/CONTEXT/DECAY -- persistent agent memory |
| **MCP Server** | Native Model Context Protocol -- LLMs use Vex as a tool directly |
| **Transactions** | MULTI/EXEC/DISCARD + WATCH/UNWATCH optimistic locking |
| **Pub/Sub** | SUBSCRIBE/PUBLISH/UNSUBSCRIBE/PSUBSCRIBE/PUNSUBSCRIBE |
| **Persistence** | Atomic snapshot + AOF with group commit + `appendfsync` (always/everysec/no) + STOP-WRITE on disk full |
| **TLS** | OpenSSL via dlopen -- no build dependency |
| **Memory Limits** | --maxmemory with noeviction or allkeys-lru (enforced in ConcurrentKV too) |
| **Auth** | --requirepass with constant-time comparison |
| **Observability** | SLOWLOG, LATENCY, CLIENT LIST, INFO (50 fields), DEBUG, MEMORY, runtime CONFIG SET. Field names mirror Redis 7. |
| **Client Compat** | CONFIG GET/SET, CLIENT ID/LIST/SETNAME, OBJECT, TIME, RESET, DEBUG, MEMORY |
| **Config File** | Auto-load `vex.conf` + `VEX_CONFIG` env + `--config` flag |
| **Logging** | Text or JSON format, file or stderr, 4 levels |
| **Clustering** | Leader/follower replication, epoch-based split-brain protection, non-blocking broadcast, per-follower bounded outbox, true seq-precise lag, atomic full-sync |
| **Multi-DB** | 16 logical databases (SELECT 0-15) |

---

## Architecture

```
   Clients (redis-cli, redis-py, ioredis, ...) ─── RESP ──┐
                                                          │
                  Accept Thread (main)                    │
                  /    |    |    \                        │
             Worker0  W1   W2   W3   -- N event-loop threads
             (kqueue) ...            -- kqueue/epoll/io_uring
             /  |  \
          conn conn conn             -- non-blocking I/O + slow-client backpressure
                |
       ConcurrentKV (+ maxmemory eviction)   -- 256-stripe rwlock
       GraphEngine                           -- CSR + bidirectional BFS
       PubSubRegistry                        -- shared subscriber map
       AOF (group commit + appendfsync)      -- batched persistence + STOP-WRITE
       atomic_io                             -- tmp+fsync+rename+dir-fsync
       observability (WorkerStats, SLOWLOG,  -- INFO, CLIENT LIST,
                      LATENCY, ClientReg)       DEBUG, MEMORY, CONFIG

   Cluster mode (optional):
       leader ──┬─→ follower 1 (per-follower bounded outbox + drain thread)
                ├─→ follower 2
                └─→ follower N
       epoch (vex.epoch)  ←─ persisted, monotonic across leader promotions
       VEX.PROMOTE / VEX.STATUS admin commands  ←─ for vex-sentinel
```

Sidecars (separate processes, not in vex binary):
- **`redis_exporter`** for Prometheus metrics (works today, field names mirror Redis 7)
- **`vex-sentinel`** for failover orchestration (planned — Zig, same monorepo, `sentinel/` folder)
- **log shippers** (Vector / Fluentbit / promtail) consume JSON-formatted logs

Deep dive: [Architecture](docs/architecture.md). For the data-plane / control-plane split: [Separation of Concerns](docs/separation-of-concerns.md).

---

## Source Layout

```
src/                            # vex (the data-plane binary)
├── main.zig                    # Entry point, CLI, config loading
├── config.zig                  # Config file parser
├── log.zig                     # Logger: text/JSON, file or stderr
├── server/
│   ├── tcp.zig                 # Accept loop, reactor mode
│   ├── worker.zig              # Event loop worker + pub/sub + transactions
│   ├── event_loop.zig          # kqueue/epoll/io_uring abstraction
│   ├── resp.zig                # RESP v2/v3 protocol
│   └── tls.zig                 # TLS (OpenSSL via dlopen)
├── engine/
│   ├── kv.zig                  # KV store + LRU eviction (single-thread)
│   ├── concurrent_kv.zig       # 256-stripe rwlock KV + maxmemory eviction
│   ├── list.zig                # List data type (deque)
│   ├── hash.zig                # Hash data type (field maps)
│   ├── set.zig                 # Set data type (unique members)
│   ├── sorted_set.zig          # Sorted set (score-ordered)
│   ├── graph.zig               # CSR graph engine + vector integration
│   ├── query.zig               # BFS, Dijkstra, traversal
│   ├── vector_store.zig        # f32 vector storage (per node, per field)
│   ├── hnsw.zig                # HNSW approximate nearest neighbor index
│   └── rag.zig                 # GRAPH.RAG executor (search + expand)
├── command/
│   └── handler.zig             # Command dispatch + BGSAVE + admin (VEX.*)
├── cluster/
│   ├── replication.zig         # Leader/follower wire, epoch, non-blocking broadcast
│   └── protocol.zig            # VX frame protocol (v2 with epoch + ack frames)
├── observability/              # NEW — operator surface
│   ├── stats.zig               # WorkerStats counters + global atomics
│   ├── cmd_table.zig           # Comptime command name → index, write classifier
│   ├── event_stats.zig         # LATENCY monitor event rings
│   └── clients.zig             # CLIENT LIST registry
└── storage/
    ├── snapshot.zig            # Binary snapshot (CRC-32)
    ├── aof.zig                 # AOF + group commit + appendfsync + STOP-WRITE
    └── atomic_io.zig           # NEW — tmp+fsync+rename+dir-fsync helpers
```

**Planned**: `sentinel/` (Zig binary for cluster orchestration), `tests/chaos/` (bash/Python chaos tests). See [Separation of Concerns](docs/separation-of-concerns.md).

---

## Changelog

### v0.8.0 — Production Hardening (Observability + Stability)

**Observability (Redis-compatible operator surface):**
- `INFO` expanded to ~50 fields across 11 sections (Server, Clients, Memory, Keyspace, Graph, Persistence, CPU, Replication, Cluster, Stats, Commandstats). Field names mirror Redis 7 — `redis_exporter` works against vex unmodified.
- `SLOWLOG GET / LEN / RESET` with per-worker bounded rings.
- `LATENCY LATEST / HISTORY / DOCTOR / RESET` for rare slow events (fsync, snapshot, eviction).
- `CLIENT LIST / INFO` aggregated across workers via a global client registry.
- `DEBUG OBJECT / SLEEP`, `MEMORY USAGE / STATS`.
- `CONFIG GET *` returns 13 known knobs; runtime-mutable: `log-level`, `latency-monitor-threshold`, `appendfsync`.
- Logger: file output + JSON format (`log-file`, `log-format`). All `std.debug.print` in server code now routed through the Logger.

**Stability:**
- Atomic persistence: snapshot save, AOF rewrite, HNSW serialize, vector store save all use tmp+fsync+rename+dir-fsync. `kill -9` mid-write preserves the previous version.
- `appendfsync` config: `always` / `everysec` (default; background thread) / `no`. Bounded data loss on crash.
- Disk-full STOP-WRITE state: ENOSPC sets a process flag; write commands return `-MISCONF`. Reads continue. Operator clears via `CONFIG SET appendfsync no`.
- ConcurrentKV maxmemory enforcement: per-stripe sample-LRU eviction + `MaxMemoryReached` error.
- Slow-client backpressure: `max-client-buffer` enforced on output too. Slow consumers get closed instead of OOMing the worker.
- Stripe-lock spin-loop replaced with exponential backoff + 5s timeout.
- Connection-limit cmpxchg loop (no over-admit by N when workers race).
- Non-blocking replication broadcast: per-follower bounded outbox + drain thread. One slow follower can't stall the broadcast.
- Cluster epoch mechanism: monotonic, persisted to `vex.epoch`, carried in heartbeats. Followers reject stale-epoch frames. Old leaders self-demote on higher epoch.
- `VEX.PROMOTE <epoch>` / `VEX.STATUS` admin commands. (`vex-sentinel` will drive them — planned.)
- Follower `repl_ack` frame: leaders compute true seq-precise lag per follower in `INFO Replication`.
- Atomic snapshot + AOF coordination on follower full-sync (truncate-then-atomic-install).

**Separation of concerns clarified:**
- vex is the data plane only. Cluster orchestration policy moves to `vex-sentinel` (planned). Metrics export is `redis_exporter` (works today) or native `/metrics` via a Zig Prom library (later). Chaos testing belongs in `tests/chaos/`. See [Separation of Concerns](docs/separation-of-concerns.md).

### v0.7.1
- HNSW index persistence (`.vhi` files — skip rebuild on cold start)
- Fix vector persistence (`.vvf` files now saved during SAVE/BGSAVE)
- Fix AOF flush in scaled mode (writes were buffered but never flushed to disk)
- Fix prop_mask rebuild on snapshot load
- VVF bounds validation for corruption detection
- Migrate to Zig 0.17
- Centralize version string

### v0.6.0 -- Vector Search, GRAPH.RAG & Performance
GRAPH.SETVEC/GETVEC/VECSEARCH for storing and searching embeddings on graph nodes. GRAPH.RAG combines vector ANN search + graph BFS expansion in a single command — purpose-built for agentic AI and RAG pipelines. HNSW index (M=16, ef=200/50), cosine similarity, graph-native NodeId results. io_uring recv/send for TCP I/O, SQPOLL + async AOF fsync + Direct I/O. Batch commands (MGET/MSET/HMGET/HMSET/HGETALL), RESP serialization optimization, parallel BFS frontier expansion, parallel vector field load/save.

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

### v0.7 -- LLM Ecosystem ([details](docs/llm-ecosystem.md))
- `GRAPH.RAG` v2 -- subgraph returns (nodes + edges + scores, not flat list)
- `GRAPH.COOCCUR` -- auto-create edges between entities sharing context
- `CACHE.SEMSET/SEMGET/SEMINVAL/SEMCLEAR/SEMSTATS` -- semantic LLM response cache
- `MEMORY.STORE/RECALL/RELATE/CONTEXT/DECAY` -- agent memory with temporal decay
- Native MCP server (`--mcp` flag) -- LLMs use Vex as a tool via Model Context Protocol
- Ecosystem: [langchain-vex](https://github.com/pratyush-sngh/langchain-vex), [llama-index-vex](https://github.com/pratyush-sngh/llama-index-vex)

### v0.8 -- Partitioned Graph & Graph Query
- Hash-partition graph nodes across machines
- Ghost nodes for 1-hop boundary cache
- BSP BFS for cross-partition traversals
- Distributed Dijkstra
- Consistent hash ring with vnodes
- `GRAPH.MATCH` — pattern matching (subgraph queries)
- `GRAPH.PAGERANK` — iterative PageRank
- `GRAPH.COMPONENTS` — connected components (union-find)
- `GRAPH.DEGREE key [IN|OUT]` — node degree count
- `GRAPH.COMMON from to` — common neighbors

### v0.9 -- Engine Internals
- Custom concurrent hashmap (replace Zig std HashMap for thread-safe resize)
- Dual encoding for small collections (ziplist for lists/sets < 128 items)
- Sorted set skip list (O(log n) ZRANGE/ZRANK)
- Streams (`XADD`/`XREAD`/`XRANGE`/`XLEN`)
- Persistence for lists, hashes, sets, sorted sets (snapshot + AOF)

### v1.0 -- DPDK, Scripting & Query
- DPDK kernel bypass networking (optional, Linux)
- Full io_uring event loop with connection lifecycle management (accept, close)
- Lua scripting (`EVAL`/`EVALSHA`)
- Graph secondary indexes on properties
- Cypher query language subset

---

## License

MIT
