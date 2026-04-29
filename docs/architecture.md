# Architecture

[Back to README](../README.md) | [Commands](commands.md) | [Persistence](persistence.md)

---

## System Overview

```
              Accept Thread (main)
              /    |    |    \
         Worker0  W1   W2   W3     -- N event-loop threads (auto-detected)
         (kqueue) ...              -- io_uring (SQPOLL) on Linux, kqueue on macOS
         /  |  \
      conn conn conn               -- non-blocking I/O per worker
            |
   ┌────────┴────────┐
   │  ConcurrentKV   │             -- 256-stripe rwlock (parallel reads, exclusive writes)
   │  GraphEngine    │             -- CSR adjacency, SoA layout, auto-compact
   │  VectorStore    │             -- HNSW index, f16 mmap, cosine ANN search
   │  Collections    │             -- List, Hash, Set, SortedSet stores
   │  PubSubRegistry │             -- shared cross-worker subscriber map
   │  AOF (group)    │             -- buffered WAL, async io_uring fsync on Linux
   └─────────────────┘
```

### Two Execution Modes

| Mode | Flag | How it works |
|------|------|-------------|
| **Thread-per-client** | (default) | Blocking accept loop. One OS thread per connection. Commands dispatched to engine thread via lock-free MPMC ring buffer |
| **Reactor** | `--reactor` | N event-loop workers with non-blocking I/O. Connections distributed round-robin. Uses ConcurrentKV for parallel reads. **Recommended for production** |

---

## Why It's Fast

### ConcurrentKV (256-stripe rwlock)

The KV store is split into 256 independent stripes, each with its own `pthread_rwlock`:

- **GET** takes a read lock -- multiple workers read the same stripe in parallel, zero blocking
- **SET** takes a write lock -- exclusive, but lock held only ~20ns (HashMap pointer swap)
- Key+value are allocated **OUTSIDE** the lock, stale data freed **OUTSIDE** the lock
- Cached clock per event-loop tick (no `clock_gettime` syscall per GET)
- Cache-line aligned stripes (64B alignment) prevent false sharing between CPU cores
- Stripe selection: `wyhash(key) & 0xFF`

### Graph Engine (CSR + SoA + bitflags)

- **Compressed Sparse Row** adjacency with auto-compact from delta buffer
- **Bidirectional BFS** for shortest path (explores sqrt(N) instead of N nodes)
- **Frontier-based BFS** traverse (process entire levels with bitset frontiers)
- **DynamicBitSet** visited set: 125KB for 1M nodes (fits L2 cache)
- **SoA layout**: node keys, type IDs, property masks are separate arrays (CPU cache friendly)
- TypeMask bitmask filtering, string interning (u16 IDs), shared PropertyStore

### Vector Search (HNSW + mmap)

- **HNSW index** (M=16, ef_construction=200, ef_search=50) for approximate nearest neighbor
- **Dual-tier storage**: f32 write buffer for new vectors, f16 mmap `.vvf` files for bulk data
- **Lazy initialization**: VectorStore is null until the first `GRAPH.SETVEC` — zero overhead when unused
- **GRAPH.RAG**: single command combining vector ANN search + graph BFS expansion
- **Cosine similarity** with f16→f32 conversion on the query path
- **Parallel field save/load**: per-field threads for HNSW rebuild on startup and BGSAVE

### Collection Stores

- **ListStore**: doubly-linked list with O(1) push/pop, O(n) index access
- **HashStore**: per-key field→value maps (HSET/HGET/HGETALL)
- **SetStore**: unordered unique member sets (SADD/SREM/SMEMBERS/SINTER/SUNION/SDIFF)
- **SortedSetStore**: score-ordered members (ZADD/ZRANGE/ZRANK/ZSCORE)

### Networking

- **Zero-copy read**: parse RESP directly from stack read buffer (no memcpy for complete commands)
- **Direct-write-first**: attempt immediate `write()` before registering for epoll WRITE events
- **Head-index accumulator**: advance pointer instead of memmove (compacts only at 32KB)
- **Comptime dispatch**: switch on `(cmd.len, first_byte)` for O(1) command routing, pre-built RESP literals
- **TCP_NODELAY** on all sockets
- **TLS handshake** before event loop registration (no half-open connections)

### Persistence

- **AOF group commit**: buffer all writes in memory, single `write()` per tick; async io_uring fsync on Linux
- **Direct I/O** (Linux): O_DIRECT AOF writes bypass page cache, 4KB-aligned staging buffer
- **Per-worker AOF shards**: each reactor worker gets its own AOF file, reducing mutex contention
- **BGSAVE**: background thread with read locks (non-blocking)
- **Tombstone DEL**: ~25ns (flag set) vs ~140ns (full remove + free)

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
│   ├── vector_store.zig    # Dual-tier vector store (f32 write buffer + f16 mmap)
│   ├── hnsw.zig            # HNSW approximate nearest neighbor index
│   ├── rag.zig             # RAG: vector search + graph BFS expansion
│   ├── list.zig            # List data structure (LPUSH/RPUSH/LPOP/RPOP/LRANGE)
│   ├── hash.zig            # Hash data structure (HSET/HGET/HDEL/HGETALL)
│   ├── set.zig             # Set data structure (SADD/SREM/SMEMBERS/SINTER)
│   └── sorted_set.zig      # Sorted set (ZADD/ZREM/ZRANGE/ZSCORE/ZRANK)
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

## Event Loop

Platform-abstracted with automatic selection:

| Platform | Backend | Notes |
|----------|---------|-------|
| macOS | kqueue | EVFILT_READ + EVFILT_WRITE |
| Linux | io_uring + SQPOLL | Kernel poll thread, async recv/send/AOF write+fsync |
| Linux (fallback 1) | io_uring | poll_add one-shot with re-arming |
| Linux (fallback 2) | epoll | Edge-triggered (EPOLLET) |

The event loop supports:
- `addFd(fd, data)`: register for read events
- `removeFd(fd)`: unregister
- `enableWrite(fd, data)`: add to write event set (for partial writes)
- `disableWrite(fd, data)`: remove from write event set
- `poll(events, timeout_ms)`: wait for events
- `notify()`: wake up from another thread (via pipe on macOS, eventfd on Linux)

---

## Connection Lifecycle

```
TCP accept
    │
    ▼
TCP_NODELAY set
    │
    ▼
TLS handshake (if --tls-cert/--tls-key)
    │
    ├── Fail: close fd
    │
    ▼
Connection limit check (--maxclients)
    │
    ├── Over limit: write error, close fd
    │
    ▼
Connection struct allocated
    │
    ▼
fd added to event loop (read events)
    │
    ▼
[event loop tick]
    ├── readable: handleRead → parse RESP → dispatchCommand
    │       ├── AUTH gate (if --requirepass)
    │       ├── Pub/sub commands
    │       ├── MULTI/EXEC transaction queue
    │       ├── Hot-path (ConcurrentKV direct)
    │       └── Slow-path (CommandHandler under kv_mutex)
    │
    ├── writable: directFlush (partial write completion)
    │
    ├── hup/err: closeConn
    │
    └── [end of tick]: aof.flush() (group commit)
```
