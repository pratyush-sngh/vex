# Architecture

[Back to README](../README.md) | [Commands](commands.md) | [Persistence](persistence.md)

---

## System Overview

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

### Networking

- **Zero-copy read**: parse RESP directly from stack read buffer (no memcpy for complete commands)
- **Direct-write-first**: attempt immediate `write()` before registering for epoll WRITE events
- **Head-index accumulator**: advance pointer instead of memmove (compacts only at 32KB)
- **Comptime dispatch**: switch on `(cmd.len, first_byte)` for O(1) command routing, pre-built RESP literals
- **TCP_NODELAY** on all sockets
- **TLS handshake** before event loop registration (no half-open connections)

### Persistence

- **AOF group commit**: buffer all writes in memory, single `write()` syscall per event loop tick
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

## Event Loop

Platform-abstracted with automatic selection:

| Platform | Backend | Notes |
|----------|---------|-------|
| macOS | kqueue | EVFILT_READ + EVFILT_WRITE |
| Linux | io_uring | poll_add one-shot with re-arming |
| Linux (fallback) | epoll | Edge-triggered (EPOLLET) |

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
