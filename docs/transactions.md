# Transactions (MULTI/EXEC)

[Back to README](../README.md) | [Commands](commands.md) | [Pub/Sub](pubsub.md)

---

## Overview

Vex supports Redis-compatible transactions using `MULTI`/`EXEC`/`DISCARD`. Commands between `MULTI` and `EXEC` are queued and executed atomically as a batch.

---

## Commands

| Command | Description |
|---------|-------------|
| `MULTI` | Start a transaction. Returns `+OK` |
| `EXEC` | Execute all queued commands. Returns array of results |
| `DISCARD` | Discard all queued commands. Returns `+OK` |

---

## Usage

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

### Discard

```
127.0.0.1:6380> MULTI
OK
127.0.0.1:6380> SET key1 "will be discarded"
QUEUED
127.0.0.1:6380> DISCARD
OK
127.0.0.1:6380> GET key1
(nil)
```

---

## How It Works

1. **MULTI**: initializes an empty command queue (`tx_queue`) on the connection
2. **Commands**: each command is copied (args are duplicated since originals are freed after parsing) and appended to the queue. The server responds `+QUEUED`
3. **EXEC**: acquires the engine lock, executes all queued commands in sequence, returns an array of results, releases the lock, clears the queue
4. **DISCARD**: frees all queued commands and clears the queue

### Atomicity

All commands in the transaction execute under a single engine lock acquisition. No other command from any other connection can interleave:

```
Without MULTI:                    With MULTI/EXEC:
  Client A: SET x 1                 Client A: MULTI
  Client B: SET x 2                 Client A: SET x 1 → QUEUED
  Client A: SET y 1                 Client A: SET y 1 → QUEUED
  Client B: SET y 2                 Client A: EXEC ← both run atomically
  # x=2, y=2 (interleaved)         # x=1, y=1 (guaranteed)
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| `EXEC` without `MULTI` | Returns `-ERR EXEC without MULTI` |
| `DISCARD` without `MULTI` | Returns `-ERR DISCARD without MULTI` |
| Nested `MULTI` | Returns `-ERR MULTI calls can not be nested` |
| Command error inside transaction | The individual command returns its error in the EXEC response array. Other commands still execute |
| Connection close during MULTI | Queued commands are freed, transaction is abandoned |
| Out of memory during queueing | Returns `-ERR out of memory`, command is not queued |

---

## Implementation Details

### Command Storage

Each queued command copies its arguments into owned memory:
```zig
const TxCommand = struct {
    args: [][]u8,  // owned copies of each argument
};
```

This is necessary because the RESP parser's data is freed after each `processOneCommand` call.

### Execution

During `EXEC`, commands are dispatched through the same path as normal commands:
1. Hot-path ConcurrentKV commands (GET, SET, DEL, etc.) go through `executeHotFast`
2. Other commands go through `CommandHandler.execute`

The engine mutex is held for the entire batch, not per-command.

---

## Limitations

- **Single-shard only**: in reactor mode, all keys in a transaction must hash to the same worker. Cross-shard transactions are not supported
- **No WATCH**: optimistic locking (`WATCH`/`UNWATCH`) is not yet implemented. Planned for v0.4
- **No nested transactions**: `MULTI` inside `MULTI` returns an error
- **No MULTI in pub/sub mode**: transactions and pub/sub are mutually exclusive
- **Max queue size**: limited only by available memory. No hard cap on queued commands
