# Persistence

[Back to README](../README.md) | [Commands](commands.md) | [Configuration](configuration.md) | [Deployment](deployment.md)

---

Vex uses a dual persistence model similar to Redis RDB+AOF.

## Overview

| Component | File | Description |
|-----------|------|-------------|
| Snapshot | `vex.zdb` | Binary format with CRC-32 checksum. Full KV + graph state |
| AOF | `vex.aof` | Append-only file. Every write command in binary format |

### Lifecycle

1. **Startup**: loads snapshot (`vex.zdb`), then replays AOF (`vex.aof`) to recover commands since last snapshot
2. **Runtime**: write commands are buffered in memory and flushed to AOF per event loop tick (group commit)
3. **SAVE/BGSAVE**: writes a new snapshot, truncates AOF
4. **BGREWRITEAOF**: compacts AOF by serializing current state to a new file, atomic rename
5. **Shutdown**: SIGTERM/SIGINT triggers a final snapshot + AOF flush

```bash
zig build run -- --data-dir /var/lib/vex      # persistence enabled (default)
zig build run -- --no-persistence              # disable for benchmarking
```

---

## Snapshot Format (v2)

Binary format with the following structure:

```
MAGIC ("ZGDB", 4 bytes)
VERSION (1 byte, currently 2)
TIMESTAMP (i64, milliseconds since epoch)
KV SECTION:
  count (u32)
  [key (length-prefixed) + value (length-prefixed) + has_ttl (u8) + expires_at (i64, if has_ttl)]*
TYPES SECTION:
  count (u16)
  [type_string (length-prefixed)]*
NODES SECTION:
  count (u32)
  [alive (u8) + key (length-prefixed) + type_id (u16) + prop_count (u32) + [prop_key + prop_value]*]*
EDGES SECTION:
  count (u32)
  [alive (u8) + from (u32) + to (u32) + type_id (u16) + weight (f64) + prop_count (u32) + [prop_key + prop_value]*]*
CRC-32 (u32, IEEE 802.3)
```

The CRC-32 checksum covers all bytes before it. If the checksum doesn't match on load, Vex reports `ChecksumMismatch` and refuses to load the corrupted snapshot.

---

## Background Save (BGSAVE)

`BGSAVE` spawns a dedicated thread to write the snapshot without blocking command processing.

**How it works:**
1. Atomically sets `bgsave_in_progress` flag (CAS-based, prevents concurrent saves)
2. Spawns a new thread
3. Thread acquires read lock on graph engine (allows concurrent reads, blocks writes)
4. Serializes full KV + graph state to `vex.zdb`
5. Truncates AOF
6. Releases locks, clears `bgsave_in_progress` flag

```
127.0.0.1:6380> BGSAVE
"Background saving started"

127.0.0.1:6380> BGSAVE
(error) ERR Background save already in progress

127.0.0.1:6380> LASTSAVE
(integer) 1745477400
```

**vs SAVE:** `SAVE` runs in the foreground and blocks all commands until the snapshot is complete. Use `BGSAVE` in production.

---

## AOF Group Commit

Instead of writing to the AOF file on every command, Vex buffers commands in memory and flushes the entire batch at the end of each event loop tick.

### Before (per-command I/O)

```
SET k1 v1 → seek + write + flush     (3 syscalls)
SET k2 v2 → seek + write + flush     (3 syscalls)
SET k3 v3 → seek + write + flush     (3 syscalls)
                                      Total: 9 syscalls
```

### After (group commit)

```
SET k1 v1 → append to memory buffer  (0 syscalls)
SET k2 v2 → append to memory buffer  (0 syscalls)
SET k3 v3 → append to memory buffer  (0 syscalls)
[end of tick] → seek + write + flush  (3 syscalls)
                                      Total: 3 syscalls
```

With pipeline depth of 100, this reduces syscall overhead by ~100x.

### Implementation

- `logCommand()` appends binary record to an in-memory `group_buf` (under mutex, no I/O)
- `flush()` writes entire buffer to AOF file in one `write()` syscall
- Worker calls `aof.flush()` at end of each event loop tick (after processing all commands from one `poll()`)
- Falls back to direct per-command writes when group buffer is not initialized (during AOF replay at startup)

### AOF Binary Record Format

Each record in the AOF is:

```
TIMESTAMP (i64, 8 bytes, little-endian, milliseconds since epoch)
ARG_COUNT (u16, 2 bytes, little-endian)
[ARG_LENGTH (u32, 4 bytes) + ARG_DATA (variable)]*
```

---

## BGREWRITEAOF

Compacts the AOF by serializing the current in-memory state:

1. Creates a temp file (`vex.aof.rewrite.tmp`)
2. Iterates all live KV entries and graph nodes/edges
3. Writes equivalent SET/GRAPH.ADDNODE/GRAPH.ADDEDGE commands
4. Atomically renames temp file over the current AOF

This eliminates redundant operations (e.g., 1000 SETs to the same key become 1 SET).

---

## Durability Guarantees

| Scenario | Data Loss |
|----------|-----------|
| Clean shutdown (SIGTERM) | None. Final snapshot + AOF flush |
| `SAVE` or `BGSAVE` + crash | Commands since last snapshot |
| Crash without recent save | Commands since last snapshot. AOF replayed on restart |
| AOF corruption | Partial replay. Vex stops at first corrupt record |
| Snapshot corruption | CRC mismatch detected, snapshot rejected. Falls back to empty state + AOF replay |

For maximum durability, ensure periodic `BGSAVE` (e.g., via cron or application-level timer).
