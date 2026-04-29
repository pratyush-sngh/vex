# Configuration

[Back to README](../README.md) | [Commands](commands.md) | [Security](security.md) | [Deployment](deployment.md)

---

Vex can be configured via CLI flags, config files, or environment variables.

## Precedence Order (highest to lowest)

1. **CLI flags** -- always win
2. **`--config <path>`** -- explicit config file
3. **`VEX_CONFIG` env var** -- path to config file
4. **`./vex.conf`** -- default config file in current directory (silently skipped if missing)
5. **Built-in defaults**

---

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port`, `-p` | 6380 | Listen port |
| `--host`, `-h` | 0.0.0.0 | Bind address |
| `--reactor` | off | Enable multi-reactor mode (recommended for production) |
| `--workers N` | auto (CPU cores, max 8) | Worker threads for reactor mode |
| `--data-dir`, `-d` | ./data | Persistence directory |
| `--no-persistence` | off | Disable AOF/snapshot entirely |
| `--requirepass` | none | Password for AUTH |
| `--maxclients` | 10000 | Max concurrent connections |
| `--max-client-buffer` | 1048576 | Max unparsed data per connection (bytes) |
| `--maxmemory` | 0 (unlimited) | Memory limit. Supports `kb`/`mb`/`gb` suffixes |
| `--maxmemory-policy` | noeviction | Eviction policy: `noeviction` or `allkeys-lru` |
| `--tls-cert` | none | TLS certificate file (PEM format) |
| `--tls-key` | none | TLS private key file (PEM format) |
| `--log-level` | info | Log verbosity: `debug`, `info`, `warn`, `error` |
| `--config` | none | Path to config file |
| `--cluster-config` | none | Path to cluster config file |
| `--profile` | off | Enable latency profiling |
| `--profile-every N` | 100000 | Print profile every N commands |
| `--keys-mode` | strict | KEYS command mode: `strict` (disabled for large DBs) or `autoscan` |
| `--engine-threads N` | auto | Thread count for scaled mode |
| `--unixsocket path` | none | Unix socket path for connections (in addition to TCP) |

### Examples

```bash
# Minimal
zig build run -- --reactor --port 6380

# Production
zig build run -- --reactor --port 6380 \
  --requirepass secret \
  --maxmemory 2gb --maxmemory-policy allkeys-lru \
  --tls-cert cert.pem --tls-key key.pem \
  --log-level info

# Benchmarking
zig build run -- --reactor --port 7379 --no-persistence --workers 8
```

---

## Config File

**Format:** one `key value` pair per line, `#` for comments, blank lines ignored.

```conf
# /etc/vex/vex.conf

# Network
port 6380
host 0.0.0.0
reactor
workers 4

# Persistence
data-dir /var/lib/vex

# Security
requirepass mysecretpassword
tls-cert /etc/vex/cert.pem
tls-key /etc/vex/key.pem

# Memory
maxmemory 512mb
maxmemory-policy allkeys-lru
maxclients 10000

# Logging
loglevel info
```

### Config Key Reference

| Config Key | CLI Equivalent | Notes |
|------------|---------------|-------|
| `port` | `--port` | |
| `host` or `bind` | `--host` | Both aliases work |
| `data-dir` or `dir` | `--data-dir` | Both aliases work |
| `requirepass` | `--requirepass` | |
| `maxclients` | `--maxclients` | |
| `max-client-buffer` | `--max-client-buffer` | Bytes |
| `maxmemory` | `--maxmemory` | Supports `kb`/`mb`/`gb` suffixes |
| `maxmemory-policy` | `--maxmemory-policy` | `noeviction` or `allkeys-lru` |
| `reactor` | `--reactor` | Boolean flag (presence = enabled) |
| `workers` | `--workers` | |
| `log-level` or `loglevel` | `--log-level` | Both aliases work |
| `tls-cert` | `--tls-cert` | |
| `tls-key` | `--tls-key` | |
| `keys-mode` | `--keys-mode` | `strict` or `autoscan` |
| `engine-threads` | `--engine-threads` | |
| `unixsocket` | `--unixsocket` | |
| `profile` | `--profile` | Boolean flag |
| `profile-every` | `--profile-every` | |

Unknown keys are silently ignored for forward compatibility.

### Config File Loading

Vex automatically loads `./vex.conf` from the current working directory on startup. No flag needed -- just place the file and run:

```bash
echo "port 6380\nreactor\nworkers 4" > vex.conf
zig build run
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `VEX_CONFIG` | Path to config file. Loaded after `./vex.conf`, before `--config` flag |

```bash
# Use env var for config
VEX_CONFIG=/etc/vex/production.conf zig-out/bin/vex --reactor

# Env var + CLI override (CLI wins)
VEX_CONFIG=/etc/vex/base.conf zig-out/bin/vex --port 7380
```

---

## Memory Size Format

The `--maxmemory` flag and `maxmemory` config key accept human-readable sizes:

| Input | Bytes |
|-------|-------|
| `1024` | 1,024 |
| `64kb` | 65,536 |
| `256mb` | 268,435,456 |
| `1gb` | 1,073,741,824 |
| `256MB` | 268,435,456 (case-insensitive) |

See [Memory Management](memory.md) for eviction policy details.
