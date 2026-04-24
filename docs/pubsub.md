# Pub/Sub

[Back to README](../README.md) | [Commands](commands.md) | [Transactions](transactions.md)

---

## Overview

Vex supports Redis-compatible publish/subscribe messaging. Clients can subscribe to channels and receive messages published by other clients in real time.

---

## Commands

| Command | Description |
|---------|-------------|
| `SUBSCRIBE channel [channel ...]` | Subscribe to one or more channels |
| `UNSUBSCRIBE [channel ...]` | Unsubscribe from specific channels, or all if no args |
| `PUBLISH channel message` | Publish a message to a channel. Returns subscriber count |

---

## Usage

### Subscriber (Terminal 1)

```
127.0.0.1:6380> SUBSCRIBE news alerts
1) "subscribe"
2) "news"
3) (integer) 1
1) "subscribe"
2) "alerts"
3) (integer) 1
# ... waiting for messages ...

# When a message arrives:
1) "message"
2) "news"
3) "breaking: vex 0.3 released"
```

### Publisher (Terminal 2)

```
127.0.0.1:6380> PUBLISH news "breaking: vex 0.3 released"
(integer) 1

127.0.0.1:6380> PUBLISH alerts "server load high"
(integer) 1

127.0.0.1:6380> PUBLISH nonexistent "nobody listening"
(integer) 0
```

### Unsubscribe

```
# Unsubscribe from specific channel
127.0.0.1:6380> UNSUBSCRIBE news
1) "unsubscribe"
2) "news"
3) (integer) 0

# Unsubscribe from all channels
127.0.0.1:6380> UNSUBSCRIBE
1) "unsubscribe"
2) (nil)
3) (integer) 0
```

---

## Pub/Sub Mode

When a client sends `SUBSCRIBE`, it enters **pub/sub mode**. In this mode:

- Only `SUBSCRIBE`, `UNSUBSCRIBE`, and `PING` commands are accepted
- All other commands return an error: `ERR only (P)SUBSCRIBE / (P)UNSUBSCRIBE / PING / QUIT allowed in this context`
- The client exits pub/sub mode when it unsubscribes from all channels

---

## Architecture

### Shared Registry

All workers share a single `PubSubRegistry` protected by a mutex:

```
Worker 0  ─┐
Worker 1  ─┤── PubSubRegistry (mutex + HashMap<channel, []fd>)
Worker 2  ─┤
Worker 3  ─┘
```

- **SUBSCRIBE**: adds the connection's fd to the channel's subscriber list
- **UNSUBSCRIBE**: removes the fd from the channel's list
- **PUBLISH**: copies the subscriber fd list under lock, then writes to each fd outside the lock
- **Connection close**: auto-unsubscribes from all channels

### Cross-Worker Delivery

When a client on Worker 0 publishes to a channel with subscribers on Worker 2:

1. Worker 0 acquires the registry mutex, copies the fd list
2. Worker 0 releases the mutex
3. Worker 0 writes the RESP message to each subscriber fd
   - If the subscriber is on the same worker: appends to its write buffer
   - If on a different worker: direct `write()` to the fd (the event loop will handle the rest)

### Message Format (RESP)

Published messages are delivered as RESP push arrays:

```
*3\r\n
$7\r\nmessage\r\n
$<channel_len>\r\n<channel>\r\n
$<message_len>\r\n<message>\r\n
```

---

## Behavior Details

| Behavior | Description |
|----------|-------------|
| Duplicate subscribe | Ignored. Subscribing to the same channel twice has no effect |
| Subscribe to multiple channels | Each channel gets its own subscribe confirmation |
| Connection close | Auto-unsubscribes from all channels |
| Publish to empty channel | Returns `(integer) 0`, no error |
| Auth in pub/sub mode | Not allowed. Authenticate before subscribing |

---

## Limitations

- No pattern subscriptions (`PSUBSCRIBE`) yet
- No `PUBSUB` introspection command yet
- Messages are fire-and-forget (no persistence, no replay)
- Cross-worker delivery uses direct fd writes (may interleave with other responses under extreme load)
