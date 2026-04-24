# Deployment

[Back to README](../README.md) | [Configuration](configuration.md) | [Security](security.md) | [Clustering](clustering.md)

---

## Build

```bash
# Debug build
zig build

# Release build (recommended for production)
zig build -Doptimize=ReleaseFast

# Binary location
./zig-out/bin/vex
```

---

## Production Checklist

```bash
# 1. Create config file
cat > /etc/vex/vex.conf << 'EOF'
port 6380
host 0.0.0.0
reactor
workers 4
data-dir /var/lib/vex
requirepass YOUR_SECRET_HERE
maxmemory 2gb
maxmemory-policy allkeys-lru
maxclients 10000
tls-cert /etc/vex/cert.pem
tls-key /etc/vex/key.pem
loglevel info
EOF

# 2. Generate TLS certificates
openssl req -x509 -newkey rsa:2048 -keyout /etc/vex/key.pem -out /etc/vex/cert.pem \
  -days 365 -nodes -subj '/CN=vex.internal'

# 3. Create data directory
mkdir -p /var/lib/vex
chown vex:vex /var/lib/vex

# 4. Build release binary
zig build -Doptimize=ReleaseFast
cp zig-out/bin/vex /usr/local/bin/vex

# 5. Run
VEX_CONFIG=/etc/vex/vex.conf /usr/local/bin/vex
```

---

## Systemd Service

```ini
[Unit]
Description=Vex KV + Graph Database
After=network.target

[Service]
Type=simple
User=vex
Group=vex
ExecStart=/usr/local/bin/vex --config /etc/vex/vex.conf
Restart=always
RestartSec=5
LimitNOFILE=65536
Environment=VEX_CONFIG=/etc/vex/vex.conf

[Install]
WantedBy=multi-user.target
```

```bash
# Install
sudo cp vex.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable vex
sudo systemctl start vex

# Check status
sudo systemctl status vex
sudo journalctl -u vex -f
```

---

## Docker

### Single Node

```dockerfile
FROM alpine:latest
COPY zig-out/bin/vex /usr/local/bin/vex
EXPOSE 6380
CMD ["vex", "--reactor", "--host", "0.0.0.0"]
```

```bash
docker build -t vex .
docker run -p 6380:6380 -v vex-data:/data vex --reactor --data-dir /data
```

### Docker Compose (Single Node)

```yaml
version: '3.8'
services:
  vex:
    build: .
    ports:
      - "6380:6380"
    volumes:
      - vex-data:/data
      - ./vex.conf:/etc/vex/vex.conf:ro
    command: ["--config", "/etc/vex/vex.conf"]
    environment:
      VEX_CONFIG: /etc/vex/vex.conf

volumes:
  vex-data:
```

### Docker Compose (3-Node Cluster)

```bash
docker compose -f docker-compose.cluster.yml up --build -d
```

See [Clustering](clustering.md) for cluster configuration details.

---

## Tuning

### File Descriptors

Each connection uses one fd. Set `LimitNOFILE` high enough:

```bash
# Check current limit
ulimit -n

# Set for current session
ulimit -n 65536
```

### Workers

Workers auto-detect from CPU cores (capped at 8). For machines with many cores:

```bash
# Use all cores
zig build run -- --reactor --workers 16

# Benchmark to find optimal count
# More workers = more parallel GETs, but more lock contention on SETs
```

### Memory

```bash
# Set maxmemory to ~80% of available RAM
# Leave room for graph engine, OS, and allocator overhead
--maxmemory 12gb --maxmemory-policy allkeys-lru
```

### Persistence

For maximum write throughput:
```bash
--no-persistence  # Disable AOF entirely
```

For durability with performance:
```bash
# Default: AOF group commit (batch writes per tick)
# Periodic BGSAVE via application timer or cron
```

---

## Monitoring

```
redis-cli -p 6380 INFO
```

Returns sections:
- **Server**: version, engine type
- **Keyspace**: key count, TTL count, tombstones, selected DB
- **Graph**: node count, edge count, types, delta edges, compact status
- **Persistence**: AOF enabled, last save time
- **Cluster**: mutation sequence number
