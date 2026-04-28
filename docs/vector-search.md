# Vector Search & GRAPH.RAG

[Back to README](../README.md) | [Commands](commands.md) | [Architecture](architecture.md)

---

## Overview

Vex integrates vector similarity search directly into the graph engine. Embeddings are stored as properties on graph nodes, and HNSW indexes enable sub-millisecond approximate nearest neighbor (ANN) search. The `GRAPH.RAG` command combines vector search with graph traversal in a single call — purpose-built for retrieval-augmented generation (RAG) pipelines.

**What makes this different from standalone vector databases:**

| | Pinecone + Redis + Neo4j | Vex |
|---|---|---|
| Vector search | API call (~50ms) | In-process HNSW (~0.1ms) |
| Fetch metadata | Redis GET x K (~5ms) | Same memory, zero-copy |
| Graph expand | Neo4j query (~20ms) | CSR traverse (~0.05ms) |
| **Total** | **~75ms, 3 network hops** | **~0.2ms, 1 command** |

---

## Commands

| Command | Type | Description |
|---------|------|-------------|
| `GRAPH.SETVEC node_key field <f32_bytes>` | Write | Store a vector embedding on a graph node |
| `GRAPH.GETVEC node_key field` | Read | Retrieve a node's vector as raw bytes |
| `GRAPH.VECSEARCH field <query_bytes> K n` | Read | ANN vector similarity search |
| `GRAPH.RAG field <query_bytes> K n [DEPTH d] [DIR d] [EDGETYPE t] [NODETYPE t]` | Read | Vector search + graph expand in one shot |

### GRAPH.SETVEC

Store a vector embedding on an existing graph node.

```
GRAPH.SETVEC <node_key> <field_name> <raw_f32_bytes>
```

- `node_key`: the graph node (must exist via `GRAPH.ADDNODE`)
- `field_name`: embedding field name (e.g., "text_embedding", "image_vec")
- `raw_f32_bytes`: vector as raw little-endian f32 bytes (length must be multiple of 4)

A node can have multiple vector fields (text embedding + image embedding, etc.). Each field maintains its own HNSW index. The first vector inserted for a field establishes its dimension — all subsequent vectors for that field must match.

Vectors are automatically **normalized to unit length** on insert (cosine similarity = dot product for unit vectors).

### GRAPH.GETVEC

Retrieve a stored vector as raw f32 bytes.

```
GRAPH.GETVEC <node_key> <field_name>
```

Returns the normalized vector as a bulk string of raw bytes, or `nil` if not set.

### GRAPH.VECSEARCH

Pure ANN vector search — find the K nearest nodes by cosine similarity.

```
GRAPH.VECSEARCH <field> <query_f32_bytes> K <n>
```

Returns an array of `[key, score, key, score, ...]` pairs, sorted by similarity (highest first).

```
127.0.0.1:6380> GRAPH.VECSEARCH embedding <query_bytes> K 5
 1) "doc:42"
 2) "0.9523"
 3) "doc:17"
 4) "0.9201"
 5) "doc:8"
 6) "0.8876"
```

### GRAPH.RAG

The flagship command. Vector search + graph expansion in one call.

```
GRAPH.RAG <field> <query_bytes> K <n> [DEPTH d] [DIR OUT|IN|BOTH] [EDGETYPE t] [NODETYPE t]
```

**Parameters:**
- `field`: vector field name to search
- `query_bytes`: query vector as raw f32 bytes
- `K n`: return top-n results
- `DEPTH d`: how many hops to expand from each result (default 1)
- `DIR`: expansion direction — `OUT`, `IN`, or `BOTH` (default `OUT`)
- `EDGETYPE t`: only expand through edges of this type
- `NODETYPE t`: only include nodes of this type in expansion

**Response format:**
```
*K                              # K results
  *4                            # each result: [key, score, props, neighbors]
    $<len> <node_key>           # matched node
    $<len> <score>              # cosine similarity (0-1)
    *N                          # properties (key-value pairs)
      $<len> <prop_key>
      $<len> <prop_value>
    *M                          # expanded neighbor keys
      $<len> <neighbor_key>
```

---

## Usage Example: RAG Pipeline

### 1. Build the Knowledge Graph

```
# Create document nodes
GRAPH.ADDNODE doc:transformer document
GRAPH.SETPROP doc:transformer title "Attention Is All You Need"
GRAPH.SETPROP doc:transformer year "2017"

GRAPH.ADDNODE doc:bert document
GRAPH.SETPROP doc:bert title "BERT: Pre-training of Deep Bidirectional Transformers"

GRAPH.ADDNODE author:vaswani person
GRAPH.ADDNODE topic:attention topic

# Create relationships
GRAPH.ADDEDGE doc:transformer author:vaswani authored_by
GRAPH.ADDEDGE doc:transformer topic:attention about
GRAPH.ADDEDGE doc:bert doc:transformer cites
```

### 2. Add Embeddings

From your application (Python example using redis-py):

```python
import redis
import numpy as np
from sentence_transformers import SentenceTransformer

model = SentenceTransformer('all-MiniLM-L6-v2')  # 384-dim
r = redis.Redis(port=6380)

# Encode and store
for doc_key, text in documents.items():
    embedding = model.encode(text).astype(np.float32)
    r.execute_command('GRAPH.SETVEC', doc_key, 'embedding', embedding.tobytes())
```

### 3. Query with GRAPH.RAG

```python
query = "How do transformer attention mechanisms work?"
query_vec = model.encode(query).astype(np.float32)

# One command: find similar docs + expand to related entities
results = r.execute_command(
    'GRAPH.RAG', 'embedding', query_vec.tobytes(),
    'K', '5', 'DEPTH', '1', 'DIR', 'OUT'
)

# results[0] = [b'doc:transformer', b'0.9523', [b'title', b'Attention Is All You Need', ...], [b'author:vaswani', b'topic:attention']]
# results[1] = [b'doc:bert', b'0.8876', [...], [b'doc:transformer']]

# Feed to LLM as context
context = format_rag_context(results)
llm_response = call_llm(query, context)
```

### 4. What the LLM Receives

From a single `GRAPH.RAG` command, the LLM gets:
- **doc:transformer** (similarity: 0.95) — title: "Attention Is All You Need", year: 2017
  - Related: author:vaswani (person), topic:attention (topic)
- **doc:bert** (similarity: 0.89) — title: "BERT: Pre-training..."
  - Related: doc:transformer (cites)

This is richer context than pure vector search — the graph relationships provide reasoning chains the LLM can follow.

---

## Architecture

### Vector Storage

Vectors are stored in `VectorStore`, which follows the same composite-key pattern as `PropertyStore`:

```
Key: (node_id:u32 << 16) | field_id:u16
Value: []f32 (owned, normalized to unit length)
```

- Field names are interned via `StringIntern` (u16 IDs, max 64 fields)
- Dimension per field is enforced (set on first insert, validated after)
- Vectors are pre-normalized on insert: cosine similarity = dot product

### HNSW Index

One HNSW index per vector field, implementing the standard algorithm (Malkov & Yashunin, 2018):

| Parameter | Value | Description |
|-----------|-------|-------------|
| M | 16 | Max connections per node per layer |
| M_max0 | 32 | Max connections at layer 0 |
| ef_construction | 200 | Search width during index build |
| ef_search | 50 | Search width during query |
| Distance | Cosine | 1 - dot_product (pre-normalized vectors) |
| Level gen | Geometric | floor(-ln(rand) / ln(M)) |

**Insert**: O(log N) — greedy descent from top layer, then beam search + connect at each layer

**Search**: O(log N) — greedy descent to layer 0, then ef-wide beam search, filter by `node_alive` bits

**Delete**: Lazy — dead nodes are skipped during search via the graph's `node_alive` DynamicBitSet. No neighbor rewiring needed.

### GRAPH.RAG Execution Pipeline

```
GRAPH.RAG embedding <query> K 5 DEPTH 1
         │
         ▼
  ┌─── Normalize query vector ───┐
  │    (copy + unit normalize)   │
  └──────────┬───────────────────┘
             ▼
  ┌─── HNSW Search ─────────────┐
  │    ef=50 beam search         │
  │    Filter by node_alive      │
  │    → 5 NodeIds + distances   │
  └──────────┬───────────────────┘
             ▼
  ┌─── Graph Expand (per result) ┐
  │    BFS traverse, DEPTH=1     │
  │    Reuses query.traverse()   │
  │    → neighbor NodeIds        │
  └──────────┬───────────────────┘
             ▼
  ┌─── Collect Properties ───────┐
  │    node_props.collectAll()   │
  │    Zero-copy from PropStore  │
  └──────────┬───────────────────┘
             ▼
       RESP response
```

### Storage: Dual-Tier with f16 Quantization

Vectors are stored on disk as **f16** (half precision) in `.vvf` files and backed by **mmap**. The OS manages hot/cold paging — frequently accessed vectors stay in RAM, cold vectors are on disk with zero RSS.

```
Write path:  GRAPH.SETVEC → normalize → heap f32 (write buffer)
Save path:   SAVE/BGSAVE → merge write buffer + mmap → sorted f16 .vvf → atomic rename
Read path:   getById() → check write buffer (f32) → binary search mmap (f16→f32 conversion)
```

**On-disk format (.vvf):**
```
Header (20 bytes): magic("VXVF") + version + dtype(f16) + dim + count
Data (sorted by node_id): [node_id:u32 + vector:[dim]f16]*
```

### Memory Usage

| Vectors | Dims | f32 heap (old) | f16 mmap (new) | HNSW | Total RSS |
|---------|------|---------------|----------------|------|-----------|
| 10K | 384 | 15 MB | 7.5 MB disk, ~0 cold | ~3 MB | ~3 MB cold |
| 10K | 768 | 30 MB | 15 MB disk, ~0 cold | ~3 MB | ~3 MB cold |
| 100K | 384 | 150 MB | 75 MB disk | ~30 MB | ~30 MB cold |
| 100K | 768 | 300 MB | 147 MB disk | ~30 MB | ~30 MB cold |
| 1M | 768 | 3 GB | 1.47 GB disk | ~300 MB | ~300 MB cold |

Hot vectors (being searched by HNSW) are paged in by the OS. Cold vectors have zero RSS. HNSW neighbor lists (~300 bytes/node) always stay in memory.

### Lazy Initialization

Vector infrastructure is **null by default** — zero memory overhead when vectors are not used. Initialized on first `GRAPH.SETVEC` call. If no `.vvf` files exist on startup, stays null.

---

## Persistence

Vectors are persisted in separate `.vvf` files (not in the main `.zdb` snapshot):

```
data/
├── vex.zdb              # KV + graph snapshot (unchanged)
├── vex.aof              # append-only log (unchanged)
└── vectors/
    ├── embedding.vvf    # mmap'd vector file for "embedding" field
    └── image_vec.vvf    # separate file per vector field
```

- **SAVE/BGSAVE**: writes .vvf files (merge write buffer + existing mmap → sorted f16 → atomic rename)
- **Startup**: mmap .vvf files → rebuild HNSW indices from stored vectors
- **Crash safety**: .vvf.tmp written first, atomic rename. Crash during save leaves old .vvf intact
- **Backward compatible**: no changes to .zdb format. Servers without vectors load fine

HNSW indices are **rebuilt from vectors on load** (~2-5s for 100K vectors). Not persisted separately.

---

## Concurrency

- `GRAPH.SETVEC` acquires the **graph write lock** (exclusive). Other graph reads/writes block.
- `GRAPH.GETVEC`, `GRAPH.VECSEARCH`, `GRAPH.RAG` acquire the **graph read lock** (shared). Multiple searches run in parallel.
- HNSW index is modified only during `SETVEC` (under write lock). Reads are lock-free.
- f16→f32 conversion uses **double scratch buffers** (alternated per access) for safe concurrent reference handling.

---

## Limitations

- **HNSW always in memory**: neighbor lists (~300 bytes/node) are not mmap'd. Fine for <1M vectors.
- **No HNSW parameter tuning at runtime**: M, ef_construction, ef_search are fixed. Compile-time config.
- **Lazy deletion only**: deleted nodes waste HNSW connections. Periodic rebuild planned.
- **Max 64 vector fields**: limited by StringIntern's u64 bitmask. Sufficient for practical use.
- **f16 precision**: ~3 decimal digits. Cosine distance error ~1e-3. Acceptable for ANN, not for exact match.

---

## Comparison with Other Vector Databases

| Feature | Redis (RediSearch) | Qdrant | Weaviate | Vex |
|---------|-------------------|--------|----------|-----|
| Vector search | HNSW or FLAT | HNSW | HNSW | HNSW |
| Graph traversal | No (RedisGraph discontinued) | No | No | Native CSR |
| Combined search+traverse | No | No | No | `GRAPH.RAG` |
| f16 quantization | No (f32 only) | Scalar/Product | No | f16 on disk |
| mmap vectors | No | Yes | No | Yes (.vvf files) |
| Protocol | RESP + FT.* | REST/gRPC | REST/gRPC | RESP (redis-cli) |
| Deployment | Server + module | Server/Cloud | Server/Cloud | Single binary |
| KV + Vectors + Graph | 3 separate systems | Vectors only | Vectors only | All in one process |
