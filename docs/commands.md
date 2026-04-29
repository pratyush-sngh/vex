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
| `SETNX key value` | Set if not exists. Returns 1 if set, 0 if already exists |
| `SETEX key seconds value` | Set with expiry in seconds |
| `GETEX key [EX s\|PX ms\|EXAT t\|PXAT t\|PERSIST]` | Get with TTL modification |
| `GETSET key value` | Set new value, return old value |
| `GETDEL key` | Get value and delete the key |
| `PTTL key` | Remaining TTL in milliseconds. `-1` = no expiry, `-2` = key missing |
| `PEXPIRE key milliseconds` | Set TTL in milliseconds |
| `STRLEN key` | Length of string value |
| `TYPE key` | Returns the type of a key (string, list, hash, set, zset) |
| `ECHO message` | Echo the given message |
| `QUIT` | Close the connection |
| `RANDOMKEY` | Return a random key from the keyspace |
| `RENAME key newkey` | Rename a key |
| `RENAMENX key newkey` | Rename only if newkey does not exist |
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

## List Commands

| Command | Description |
|---------|-------------|
| `LPUSH key value [value ...]` | Push values to the head of a list |
| `RPUSH key value [value ...]` | Push values to the tail of a list |
| `LPOP key` | Remove and return the head element |
| `RPOP key` | Remove and return the tail element |
| `LLEN key` | Length of a list |
| `LINDEX key index` | Get element at index |
| `LRANGE key start stop` | Get range of elements (0-based, inclusive) |
| `LSET key index value` | Set element at index |
| `LREM key count value` | Remove count occurrences of value |

---

## Hash Commands

| Command | Description |
|---------|-------------|
| `HSET key field value [field value ...]` | Set field(s) in a hash |
| `HGET key field` | Get the value of a hash field |
| `HDEL key field [field ...]` | Delete field(s) from a hash |
| `HMSET key field value [field value ...]` | Set multiple fields (same as HSET) |
| `HMGET key field [field ...]` | Get values of multiple fields |
| `HGETALL key` | Get all fields and values |
| `HLEN key` | Number of fields in a hash |
| `HKEYS key` | Get all field names |
| `HVALS key` | Get all field values |
| `HEXISTS key field` | Check if a field exists. Returns 1 or 0 |
| `HINCRBY key field increment` | Increment integer value of a field |

---

## Set Commands

| Command | Description |
|---------|-------------|
| `SADD key member [member ...]` | Add members to a set |
| `SREM key member [member ...]` | Remove members from a set |
| `SMEMBERS key` | Get all members |
| `SISMEMBER key member` | Check membership. Returns 1 or 0 |
| `SCARD key` | Number of members in a set |
| `SUNION key [key ...]` | Union of multiple sets |
| `SINTER key [key ...]` | Intersection of multiple sets |
| `SDIFF key [key ...]` | Difference of multiple sets |

---

## Sorted Set Commands

| Command | Description |
|---------|-------------|
| `ZADD key score member [score member ...]` | Add members with scores |
| `ZREM key member [member ...]` | Remove members |
| `ZCARD key` | Number of members |
| `ZRANK key member` | Rank of member (0-based, by ascending score) |
| `ZSCORE key member` | Score of a member |
| `ZINCRBY key increment member` | Increment the score of a member |
| `ZCOUNT key min max` | Count members with scores in range |
| `ZRANGE key start stop [WITHSCORES]` | Get members by rank range |

---

## Transactions (MULTI/EXEC)

See [Transactions](transactions.md) for full details.

| Command | Description |
|---------|-------------|
| `MULTI` | Start a transaction. All subsequent commands are queued |
| `EXEC` | Execute all queued commands atomically. Returns array of results |
| `DISCARD` | Discard all queued commands and exit transaction mode |
| `WATCH key [key ...]` | Optimistic locking. Marks keys to watch for changes before EXEC |
| `UNWATCH` | Clear all watched keys |

---

## Pub/Sub

See [Pub/Sub](pubsub.md) for full details.

| Command | Description |
|---------|-------------|
| `SUBSCRIBE channel [channel ...]` | Subscribe to one or more channels |
| `UNSUBSCRIBE [channel ...]` | Unsubscribe from channels (all if no args) |
| `PUBLISH channel message` | Publish a message. Returns subscriber count |
| `PSUBSCRIBE pattern [pattern ...]` | Subscribe to channels matching glob patterns |

---

## Connection & Server Commands

| Command | Description |
|---------|-------------|
| `CLIENT SETNAME name` | Set the connection name |
| `CLIENT GETNAME` | Get the connection name |
| `CLIENT ID` | Get the connection's numeric ID |
| `CLIENT LIST` | List all connections on this worker |

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
| `GRAPH.UPSERT_NODE key type [prop value ...]` | Create or update a node with metadata |
| `GRAPH.UPSERT_EDGE from to type [WEIGHT w] [prop value ...]` | Create or update an edge with metadata |
| `GRAPH.INGEST json` | Bulk ingest nodes and edges from JSON |
| `GRAPH.LIST_BY_TYPE type [LIMIT n]` | List node keys by type |
| `GRAPH.IMPACT key [DEPTH n] [DIR d]` | Impact analysis — find all affected nodes |
| `GRAPH.PATHS from type [MAXDEPTH n]` | Find all paths to nodes of a given type |
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

## Graph — Vector Search & RAG

See [Vector Search](vector-search.md) for full details.

| Command | Description |
|---------|-------------|
| `GRAPH.SETVEC key field vector` | Set a vector on a node (space-separated floats) |
| `GRAPH.GETVEC key field` | Get the vector stored on a node |
| `GRAPH.VECSEARCH field K vector` | Find K nearest neighbors by cosine similarity |
| `GRAPH.RAG field K depth vector` | Vector search + graph BFS expansion in one query |

### Vector Search Examples

```
127.0.0.1:6380> GRAPH.ADDNODE doc:1 document
(integer) 0
127.0.0.1:6380> GRAPH.SETVEC doc:1 embedding 0.1 0.2 0.3 0.4
OK
127.0.0.1:6380> GRAPH.VECSEARCH embedding 3 0.1 0.2 0.3 0.4
1) "doc:1"
2) "0.9999"
127.0.0.1:6380> GRAPH.RAG embedding 3 2 0.1 0.2 0.3 0.4
1) "doc:1"
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
