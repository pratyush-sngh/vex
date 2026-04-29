# Memory Management

[Back to README](../README.md) | [Configuration](configuration.md) | [Commands](commands.md)

---

## Overview

```bash
zig build run -- --reactor --maxmemory 512mb --maxmemory-policy allkeys-lru
```

When `--maxmemory` is set, Vex tracks memory usage and enforces the limit before each `SET` operation.

---

## Eviction Policies

| Policy | Behavior |
|--------|----------|
| `noeviction` (default) | Return `-OOM` error when SET would exceed memory limit |
| `allkeys-lru` | Evict keys with oldest access time until under limit |

### noeviction

The safe default. Writes fail with an error when memory is full, but no data is lost:

```
127.0.0.1:6380> SET newkey value
(error) ERR out of memory
```

### allkeys-lru

Approximate LRU eviction. Before each `SET`, if memory usage exceeds `maxmemory`:

1. Sample 5 random keys from the store
2. Find the one with the oldest `last_access` timestamp
3. Evict it (tombstone delete)
4. Repeat until memory usage is under the limit

This is the same algorithm Redis uses (`maxmemory-policy allkeys-lru` with sample size 5).

---

## Memory Size Format

The `--maxmemory` flag accepts human-readable sizes:

| Input | Bytes |
|-------|-------|
| `1024` | 1,024 |
| `64kb` | 65,536 |
| `256mb` | 268,435,456 |
| `1gb` | 1,073,741,824 |
| `256MB` | 268,435,456 (case-insensitive) |

Config file equivalent:
```conf
maxmemory 512mb
maxmemory-policy allkeys-lru
```

---

## Access Tracking

The `last_access` timestamp on each entry is updated on:

| Operation | Updates last_access? |
|-----------|---------------------|
| `SET` | Yes (set to current time) |
| `GET` | Yes |
| `EXISTS` | Yes |
| `DEL` | No (entry is tombstoned) |
| `TTL` | No |
| `EXPIRE` | No |

The clock is cached per event loop tick (`updateClock()`) to avoid `clock_gettime` syscalls on every operation. This means access times have tick-level granularity (~100ms in typical workloads), which is sufficient for LRU approximation.

---

## Memory Estimation

Memory usage is estimated as:

```
total = sum over all live (non-tombstoned) entries:
    key.len + value.len + sizeof(Entry)
```

Where `Entry` is:
```
struct Entry {
    value: []const u8,    // 16 bytes (ptr + len)
    expires_at: i64,      //  8 bytes
    last_access: i64,     //  8 bytes
    flags: EntryFlags,    //  1 byte (packed struct)
}
// Total: ~33 bytes per entry (+ padding)
```

This is an approximation -- it doesn't account for:
- HashMap internal overhead (bucket arrays, metadata)
- Allocator overhead (alignment, headers)
- Graph engine memory

For precise memory control, set `maxmemory` to ~80% of available RAM.

---

## Vector Store Memory

Vector embeddings use a separate memory model from the KV store:

- **On-disk vectors** (mmap'd `.vvf` files) do **not** count against `maxmemory` — they are managed by the OS page cache
- **Write buffer**: new vectors are held in an f32 in-memory buffer until the next SAVE/BGSAVE, which flushes them to f16 `.vvf` files
- **HNSW index**: the index structure (neighbor lists, layers) is held in memory — roughly ~1KB per vector for M=16
- **Scratch buffers**: two f32 buffers per vector field for f16→f32 conversion during search queries

---

## ConcurrentKV (Reactor Mode)

In reactor mode, the `ConcurrentKV` (256-stripe rwlock) also tracks `last_access`:
- **SET/setPrealloc**: sets `last_access` under write lock
- **GET**: cannot update `last_access` under read lock (would require write lock, defeating parallelism)

This means in reactor mode, LRU tracking is based on write access patterns only. This is a pragmatic tradeoff: updating `last_access` on every GET would require upgrading read locks to write locks, destroying the parallel-read advantage.
