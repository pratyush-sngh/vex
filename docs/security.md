# Security

[Back to README](../README.md) | [Configuration](configuration.md) | [Deployment](deployment.md)

---

## Authentication

```bash
zig build run -- --reactor --requirepass mysecret
```

When `--requirepass` is set, clients must authenticate with `AUTH <password>` before any command except `PING`.

```
127.0.0.1:6380> SET key value
(error) NOAUTH Authentication required.
127.0.0.1:6380> AUTH mysecret
OK
127.0.0.1:6380> SET key value
OK
```

### Implementation Details

- Password comparison uses **constant-time byte comparison** (`constantTimeEql`) to prevent timing attacks
- Per-connection `authenticated` flag -- set once, persists for connection lifetime
- Re-AUTH is allowed (Redis compatibility)
- `PING` always works without authentication (health checks)
- Config file: `requirepass mysecret`

---

## TLS Encryption

Vex supports TLS via OpenSSL, loaded at runtime using `dlopen`. This means:

- **No build-time dependency** on OpenSSL -- the binary compiles without it
- TLS is activated only when both `--tls-cert` and `--tls-key` are provided
- If OpenSSL is not available at runtime, Vex falls back to plain TCP with a warning

### Quick Start

```bash
# Generate self-signed cert for testing
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 365 -nodes -subj '/CN=localhost'

# Start with TLS
zig build run -- --reactor --tls-cert cert.pem --tls-key key.pem

# Connect with redis-cli (TLS)
redis-cli -p 6380 --tls --cert cert.pem --key key.pem --cacert cert.pem
```

### Config File

```conf
tls-cert /etc/vex/cert.pem
tls-key /etc/vex/key.pem
```

### TLS Handshake Flow

```
Client TCP connect
       │
       ▼
  TCP_NODELAY set
       │
       ▼
  Socket set to BLOCKING mode
       │
       ▼
  SSL_accept() (OpenSSL handshake)
       │
       ├── Success: socket restored to NON-BLOCKING, added to event loop
       │
       └── Failure: connection closed immediately
```

1. Client connects via TCP
2. Socket is temporarily set to blocking mode for the handshake
3. OpenSSL `SSL_accept()` performs the TLS handshake
4. Socket is restored to non-blocking mode
5. Connection is added to the event loop
6. All subsequent reads use `SSL_read`, writes use `SSL_write`

### OpenSSL Loading

Vex loads OpenSSL at runtime using `dlopen`:

| Platform | Libraries Searched |
|----------|-------------------|
| macOS | `libssl.3.dylib`, `libssl.dylib` |
| Linux | `libssl.so.3`, `libssl.so` |

Both `libssl` and `libcrypto` are loaded. If either is not found, TLS initialization fails gracefully with `TlsNotAvailable`.

### Error Handling

| Error | Meaning |
|-------|---------|
| `TlsNotAvailable` | OpenSSL not found on system |
| `TlsCertLoadFailed` | Certificate file not found or invalid |
| `TlsKeyLoadFailed` | Key file not found or invalid |
| `TlsKeyMismatch` | Certificate and key don't match |

All TLS errors are logged as warnings. The server continues on plain TCP.

### Supported OpenSSL Versions

- OpenSSL 3.x (recommended)
- OpenSSL 1.1.x
- LibreSSL (macOS system library)

### Security Considerations

- TLS handshake happens **before** the connection enters the event loop -- no half-open TLS connections
- Failed handshakes are closed immediately (no resource leak)
- Only `TLS_server_method()` is used (modern TLS 1.2+ only)
- PEM format required for both cert and key files
