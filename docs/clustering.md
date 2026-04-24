# Clustering

[Back to README](../README.md) | [Configuration](configuration.md) | [Deployment](deployment.md)

---

## Overview

Vex supports leader/follower replication for read scaling and data safety. One leader accepts all writes and broadcasts mutations to followers via a binary VX protocol.

---

## Quick Start

```bash
# Start a 3-node cluster
docker compose -f docker-compose.cluster.yml up --build -d

# Write to leader (port 16380)
redis-cli -p 16380 SET hello world

# Read from any follower (replicated)
redis-cli -p 16381 GET hello    # "world"
redis-cli -p 16382 GET hello    # "world"

# Writes on followers are forwarded to leader automatically
redis-cli -p 16381 SET fromfollower value
redis-cli -p 16380 GET fromfollower  # "value" (on leader)
redis-cli -p 16382 GET fromfollower  # "value" (replicated)
```

---

## Cluster Configuration

Create a `cluster.conf` file:

```
node 1 leader 10.0.0.1:6380
node 2 follower 10.0.0.2:6380
node 3 follower 10.0.0.3:6380
self 1
```

Each node runs with:
```bash
zig build run -- --reactor --cluster-config cluster.conf
```

The `self` line identifies which node this instance is. The role (leader/follower) determines behavior.

---

## Leader/Follower Replication

### Leader Behavior
- Accepts all write commands directly
- Broadcasts every mutation to connected followers via binary VX protocol on port + 10000
- Provides full snapshots to new followers on connect
- Sends heartbeats every 5s with `mutation_seq` for lag tracking

### Follower Behavior
- Serves read commands locally (no leader round-trip for GET, EXISTS, etc.)
- Forwards write commands to leader transparently (client sees the response as if local)
- Receives mutation stream from leader and replays locally
- Requests full sync (snapshot) on initial connection

### Write Forwarding

When a follower receives a write command:
1. Encodes the command as a binary `write_forward` frame
2. Sends it to the leader via a persistent TCP connection
3. Leader executes the command, sends RESP response back
4. Follower returns the response to the client

The client doesn't know it's connected to a follower -- writes work transparently.

---

## Automatic Failover

When the leader's heartbeat times out (default 15s):

1. Each follower detects the timeout independently
2. The **highest-priority follower** (lowest node ID) promotes itself:
   - Closes forwarding connection to old leader
   - Starts a new `ReplicationLeader` on its replication port
   - Accepts follower connections
   - Begins broadcasting mutations
3. Other followers:
   - Detect leader loss
   - Probe all cluster nodes to find the new leader
   - Reconnect and request full sync

```
Before failover:          After failover:
  Node 1 (LEADER) ──X     Node 2 (NEW LEADER)
  Node 2 (follower)        Node 3 (follower → reconnects to Node 2)
  Node 3 (follower)
```

Failover is automatic -- no manual intervention required.

### Priority

Leader election uses **lowest node ID wins**. In the config:
```
node 1 leader 10.0.0.1:6380    # priority 1 (highest)
node 2 follower 10.0.0.2:6380  # priority 2
node 3 follower 10.0.0.3:6380  # priority 3
```

If Node 1 dies, Node 2 (lowest surviving ID) becomes the new leader.

---

## Replication Protocol (VX)

Binary frame-based protocol on port + 10000:

| Frame Type | Direction | Content |
|------------|-----------|---------|
| `repl_request` | Follower → Leader | Request replication stream from seq N |
| `mutation` | Leader → Follower | Encoded write command to replay |
| `heartbeat` | Leader → Follower | `mutation_seq` + timestamp |
| `write_forward` | Follower → Leader | Write command for leader to execute |
| `write_response` | Leader → Follower | RESP response to forwarded write |
| `full_sync` | Leader → Follower | Complete snapshot data |

### Frame Format

```
TYPE (1 byte)
LENGTH (u32, 4 bytes, little-endian)
PAYLOAD (LENGTH bytes)
```

---

## Consistency Model

| Property | Guarantee |
|----------|-----------|
| Read consistency on leader | Strong (read-your-own-writes) |
| Read consistency on followers | Eventual (replication lag) |
| Write ordering | Total order (leader serializes all writes) |
| Replication lag | Typically < 1 heartbeat interval (5s) |
| Split-brain protection | Highest-priority wins. Rejoining old leaders become followers |

### Replication Lag Tracking

Each heartbeat carries `mutation_seq` (monotonic counter of write operations). Followers track:
- `leader_seq`: last known leader mutation count
- `local_seq`: local mutation count
- Lag = `leader_seq - local_seq`

---

## Monitoring

```
127.0.0.1:6380> INFO
# Cluster
graph_mutation_seq:12345
```

---

## Limitations

- **No sharding**: all data lives on all nodes (full replication)
- **No quorum writes**: writes succeed on leader alone, then replicate async
- **Single leader**: only one leader at a time (no multi-master)
- **Eventual consistency**: followers may serve stale reads during replication lag
- **No read replicas for graph**: graph queries on followers use local state which may lag
