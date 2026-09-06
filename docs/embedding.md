# Embedding proxy (`vex-embed`)

vex is a RESP KV + graph database with first-class vector storage and search
(`GRAPH.SETVEC`, `VECSEARCH`). It deliberately does **not** compute embeddings.
Turning text into a vector means calling an external model over HTTP, and a
blocking HTTP round-trip has no place on vex's microsecond-clean event loop.

`vex-embed` is an **optional, standalone process** that closes that gap without
compromising the server. It sits in front of vex as a transparent RESP proxy:
every command is forwarded byte-for-byte to vex, except one command it handles
itself by calling an embedding endpoint. Point your client at `vex-embed`
instead of vex and everything behaves identically — plus you gain `EMBED`.

```
client ──RESP──▶ vex-embed ──RESP──▶ vex
                    │
                    └──HTTP──▶ embedding endpoint (Ollama / OpenAI-compatible)
```

Because the blocking HTTP call lives in this separate process, vex's event loop
never stalls waiting on a model. Run zero, one, or many `vex-embed` instances;
they hold no state.

## Why a separate binary

- **Hot path stays clean.** No HTTP client, no TLS, no model latency anywhere
  near vex's command loop.
- **Independent lifecycle.** Restart, scale, or reconfigure embedding without
  touching the database.
- **Transparent.** Clients that never send `EMBED` can't tell the proxy is
  there; all other traffic is passed through unmodified.

## Running

```sh
zig build vex-embed          # build only
zig build run-vex-embed -- --embed-model nomic-embed-text
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--listen-port`    | `6390` | Port the proxy accepts clients on. |
| `--vex-host`       | `127.0.0.1` | Upstream vex host. |
| `--vex-port`       | `6380` | Upstream vex port. |
| `--embed-url`      | `http://localhost:11434/api/embeddings` | Embedding HTTP endpoint. |
| `--embed-model`    | `nomic-embed-text` | Model name sent in the request body. |
| `--embed-key`      | *(empty)* | Bearer token for OpenAI-compatible endpoints. |
| `--embed-provider` | `ollama` | `ollama` or `openai` — selects request/response shape. |
| `--log-level`      | `info` | `debug` \| `info` \| `warn` \| `error`. |

> The HTTP client speaks plain HTTP/1.1 over a blocking socket (the same
> networking primitive the rest of vex uses). `https://` embed URLs are not
> supported yet — front the proxy with a local Ollama or an in-cluster
> OpenAI-compatible gateway.

### Providers

- **Ollama** — `POST {"model":<model>,"prompt":<text>}` →
  `{"embedding":[float, ...]}`.
- **OpenAI-compatible** — `POST {"model":<model>,"input":<text>}` with
  `Authorization: Bearer <key>` → `{"data":[{"embedding":[float, ...]}]}`.

## The `EMBED` command

`EMBED <text>` is the one command `vex-embed` intercepts (it never reaches vex):

```
> EMBED "the quick brown fox"
<bulk string: raw little-endian f32 bytes>
```

The reply is a RESP bulk string containing the embedding as a packed buffer of
little-endian `f32` values — exactly the byte format vex's `GRAPH.SETVEC` and
`VECSEARCH` expect. A client embeds text and stores the vector in two steps:

```
EMBED "some document text"        # -> <vec bytes> from vex-embed
GRAPH.SETVEC mynode <vec bytes>   # -> forwarded straight through to vex
```

The command name is matched case-insensitively. On any failure (endpoint down,
non-2xx response, unparseable JSON) the proxy replies with a `-ERR vex-embed:
<reason>` RESP error rather than silently forwarding.

## Per-command auto-rewrite (`--auto-rewrite`)

Beyond the explicit two-step `EMBED` → `GRAPH.SETVEC` dance, the proxy can embed
text **inline**: start it with `--auto-rewrite` and a client passes a
`TEXT "<string>"` marker wherever a vector arg would go. The proxy embeds the
string and substitutes raw f32 bytes before forwarding — the client never builds
a vector itself.

```
# with --auto-rewrite:
GRAPH.VECSEARCH emb TEXT "what is vex" K 5     → GRAPH.VECSEARCH emb <f32> K 5
CACHE.SEMGET TEXT "how do I reset my password" → CACHE.SEMGET <f32>
MEMORY.STORE agent "likes Python" VEC TEXT "likes Python"
                                               → MEMORY.STORE agent "likes Python" VEC <f32>
```

- **Marker:** a `TEXT` arg followed by its string value; the pair is replaced by
  one bulk-string arg of little-endian f32 bytes. Multiple markers per command
  are each embedded. The `TEXT` match is case-insensitive.
- **Allowlist:** only `CACHE.SEMGET`/`SEMSET`, `GRAPH.VECSEARCH`/`RAG`/`SETVEC`,
  and `MEMORY.RECALL`/`STORE` are rewritten — so a literal `TEXT` argument in an
  ordinary command (e.g. `SET k TEXT`) is never mistaken for a marker.
- **Default off:** without `--auto-rewrite` the proxy stays byte-transparent
  (only `EMBED` is intercepted). On an embedding failure the client gets a
  `-ERR vex-embed: <reason>` and the command is not forwarded.

## Source layout

| File | Responsibility |
|------|----------------|
| `cmd/vex-embed/main.zig`        | Entrypoint: parse flags, start proxy, handle signals. |
| `cmd/vex-embed/config.zig`      | CLI flag parsing → `Config`. |
| `cmd/vex-embed/embedder.zig`    | HTTP embedding client + `floatsToBytes`. |
| `cmd/vex-embed/proxy.zig`       | Transparent RESP TCP proxy + `EMBED` interception. |
| `cmd/vex-embed/resp_detect.zig` | Head-of-stream `EMBED` command detection. |

```sh
zig build test-vex-embed     # run vex-embed unit tests
```
