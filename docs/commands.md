# Command Reference

[Back to README](../README.md) | [Configuration](configuration.md) | [Persistence](persistence.md) | [Security](security.md)

---

## Key-Value Commands (Redis-compatible)

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
| `TTL key` | Remaining TTL in seconds. `-1` = no expiry, `-2` = key missing |
| `KEYS pattern` | List keys matching glob (`*`, `?`). Disabled for large DBs in strict mode |
| `SCAN cursor [MATCH pattern] [COUNT n]` | Incremental key scan (safe for large DBs) |
| `DBSIZE` | Number of live keys in current DB |
| `SELECT index` | Switch logical DB (0-15). Keys are namespaced per DB |
| `FLUSHDB` | Delete all keys in current DB |
| `FLUSHALL` | Delete all keys and graph data across all DBs |
| `MOVE key db` | Move key to another DB. Preserves TTL |
| `INFO` | Server stats: keyspace, graph, persistence, cluster |
| `COMMAND` | Command metadata (Redis compatibility) |
| `AUTH password` | Authenticate. Required when `--requirepass` is set |

### Examples

```
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
127.0.0.1:6380> MSET k1 v1 k2 v2 k3 v3
OK
127.0.0.1:6380> MGET k1 k2 k3
1) "v1"
2) "v2"
3) "v3"
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

## Transactions (MULTI/EXEC)

See [Transactions](transactions.md) for full details.

| Command | Description |
|---------|-------------|
| `MULTI` | Start a transaction. All subsequent commands are queued |
| `EXEC` | Execute all queued commands atomically. Returns array of results |
| `DISCARD` | Discard all queued commands and exit transaction mode |

---

## Pub/Sub

See [Pub/Sub](pubsub.md) for full details.

| Command | Description |
|---------|-------------|
| `SUBSCRIBE channel [channel ...]` | Subscribe to one or more channels |
| `UNSUBSCRIBE [channel ...]` | Unsubscribe from channels (all if no args) |
| `PUBLISH channel message` | Publish a message. Returns subscriber count |

---

## Graph Operations

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

### Graph Examples

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

---

## Persistence Commands

See [Persistence](persistence.md) for full details.

| Command | Description |
|---------|-------------|
| `SAVE` | Foreground snapshot: blocks all commands while writing `vex.zdb` |
| `BGSAVE` | Background snapshot: spawns a thread, non-blocking |
| `BGREWRITEAOF` | Compact AOF: serialize current state to new file, atomic rename |
| `LASTSAVE` | Unix timestamp (seconds) of last successful snapshot |
