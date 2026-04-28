# Vector Search Benchmarks — Design

[Back to README](../README.md) | [Vector Search](vector-search.md) | [Benchmarks](benchmarks.md)

---

## Competitors

| Database | Version | Why Compare |
|----------|---------|-------------|
| **Redis + RediSearch** | 8.0 + RediSearch 2.x | Same RESP protocol. Direct drop-in comparison. Industry standard for caching + vector search |
| **Qdrant** | latest | Most popular open-source vector DB. Rust. HNSW. REST/gRPC. Strong community |
| **Weaviate** | latest | Popular for RAG pipelines. HNSW. REST/gRPC. Often used with LangChain/LlamaIndex |

### Why Not Others

| Database | Reason to Skip |
|----------|---------------|
| Pinecone | SaaS only — can't run locally for fair latency comparison |
| Milvus | Overkill for <1M vectors, complex deployment (etcd + MinIO + Milvus) |
| ChromaDB | Python-only, not production-grade, no RESP protocol |
| pgvector | SQL overhead makes latency comparison unfair; different use case |

---

## Benchmark Categories

### 1. Pure Vector Search Latency (VECSEARCH vs FT.SEARCH vs /search)

**What**: Single vector query latency for K nearest neighbors.

| Parameter | Values |
|-----------|--------|
| Dataset | 10K, 50K, 100K vectors |
| Dimensions | 384 (MiniLM), 768 (MPNet), 1536 (OpenAI) |
| K | 5, 10, 50 |
| Concurrency | 1, 8, 32 clients |

**Metric**: p50, p99 latency (microseconds), queries/second

**Commands per DB:**

```bash
# Vex
GRAPH.VECSEARCH embedding <query_bytes> K 10

# Redis + RediSearch
FT.SEARCH idx "*=>[KNN 10 @embedding $query_vec]" PARAMS 2 query_vec <bytes> DIALECT 2

# Qdrant
POST /collections/docs/points/search
{"vector": [...], "limit": 10}

# Weaviate
POST /v1/graphql
{Get { Document(nearVector: {vector: [...]}, limit: 10) { title }}}
```

### 2. Combined RAG Latency (GRAPH.RAG vs Multi-Hop Pipeline)

**What**: The killer benchmark. One `GRAPH.RAG` call vs the equivalent multi-step pipeline.

**Vex (1 command):**
```
GRAPH.RAG embedding <query> K 5 DEPTH 1 DIR OUT
→ returns: 5 nodes + scores + properties + neighbors
```

**Multi-system pipeline (3+ commands):**
```
Step 1: Qdrant search → 5 nearest IDs + scores          (~1-5ms)
Step 2: Redis MGET → fetch metadata for 5 nodes          (~0.5ms)
Step 3: Neo4j/manual → traverse 1-hop from each result   (~2-10ms)
Total: ~3-15ms + 3 network round-trips
```

**Redis-only pipeline (2 commands):**
```
Step 1: FT.SEARCH with vector → 5 results + metadata     (~1-3ms)
Step 2: No graph traversal available (RedisGraph discontinued)
Total: ~1-3ms but NO graph expansion
```

**Metric**: End-to-end latency for the full RAG context retrieval. Vex should win by 10-100x on the combined pipeline because it's one in-process call vs multiple network hops.

### 3. Insert Throughput (SETVEC vs index creation)

**What**: How fast can we load vectors?

| Parameter | Values |
|-----------|--------|
| Vectors | 10K, 100K batch insert |
| Dimensions | 768 |
| Pipeline depth | 1, 50, 100 |

**Commands:**
```bash
# Vex (per vector)
GRAPH.ADDNODE doc:N document
GRAPH.SETVEC doc:N embedding <768_f32_bytes>

# Redis
HSET doc:N embedding <bytes>  # (with pre-created FT index)

# Qdrant
PUT /collections/docs/points  # batch of 100
```

**Metric**: vectors/second, total load time

### 4. Memory Efficiency

**What**: RSS comparison for same dataset.

| Dataset | Vex (f16 mmap) | Redis (f32 in-memory) | Qdrant (scalar quantization) |
|---------|---------------|----------------------|------------------------------|
| 10K @ 768d | ? MB | ? MB | ? MB |
| 100K @ 768d | ? MB | ? MB | ? MB |

**Metric**: RSS (resident set size) from `docker stats` after loading vectors.

### 5. Recall@K (Quality)

**What**: Verify Vex's HNSW finds the same results as brute-force exact search.

| K | Expected Recall |
|---|----------------|
| 1 | > 99% |
| 10 | > 95% |
| 50 | > 90% |

**Method**: Insert 10K vectors. For 1000 random queries, compare Vex HNSW results against brute-force exact cosine search. Report recall = |HNSW ∩ exact| / K.

---

## Test Environment

### Docker Compose

```yaml
services:
  vex:
    image: ghcr.io/pratyush-sngh/vex:latest
    cpuset: "0-3"
    mem_limit: 4g
    command: ["--reactor", "--workers", "4", "--no-persistence"]
    ports: ["6380:6380"]

  redis:
    image: redis/redis-stack:latest  # includes RediSearch
    cpuset: "4-7"
    mem_limit: 4g
    ports: ["6379:6379"]

  qdrant:
    image: qdrant/qdrant:latest
    cpuset: "8-11"
    mem_limit: 4g
    ports: ["6333:6333"]

  weaviate:
    image: semitechnologies/weaviate:latest
    cpuset: "12-15"
    mem_limit: 4g
    ports: ["8080:8080"]
    environment:
      QUERY_DEFAULTS_LIMIT: 100
      PERSISTENCE_DATA_PATH: /var/lib/weaviate
```

Each database gets **4 dedicated CPU cores + 4GB RAM**, CPU-pinned to prevent interference. Same methodology as the existing KV benchmarks.

### Benchmark Client

Go tool at `tools/vector-bench/main.go`:

```go
// Phases:
// 1. Generate random vectors (or load pre-computed embeddings)
// 2. Load vectors into all databases
// 3. Run search benchmark (concurrent queries, measure latency)
// 4. Run RAG benchmark (Vex GRAPH.RAG vs multi-hop pipeline)
// 5. Measure memory (docker stats)
// 6. Compute recall (brute-force comparison)

flags:
  -vectors    10000      // number of vectors to load
  -dim        768        // vector dimension
  -k          10         // K nearest neighbors
  -queries    1000       // number of search queries
  -c          16         // concurrent clients
  -runs       5          // median of N runs
  -warmup     100        // warmup queries before measurement
  -rag-depth  1          // graph expansion depth for RAG benchmark
```

### Dataset Options

| Dataset | Vectors | Dims | Source |
|---------|---------|------|--------|
| Random | 10K-100K | 768 | Random unit vectors (for perf benchmarks) |
| ANN-Benchmarks sift-128 | 1M | 128 | Standard ANN benchmark dataset |
| GloVe-200 | 1.2M | 200 | Word embeddings |
| Custom embeddings | 10K | 384/768 | Run sentence-transformers on Wikipedia snippets |

For initial benchmarks, **random vectors** are sufficient for latency/throughput. Use real embeddings for recall measurement.

---

## Expected Results

Based on architecture analysis:

### Pure Vector Search (p50 latency)

| DB | 10K vectors | 100K vectors | Why |
|----|------------|-------------|-----|
| **Vex** | ~50 us | ~100 us | In-process HNSW, no serialization |
| Redis+RediSearch | ~200 us | ~500 us | RESP overhead + module dispatch |
| Qdrant | ~500 us | ~1 ms | REST/gRPC serialization + HTTP overhead |
| Weaviate | ~1 ms | ~2 ms | GraphQL parsing + HTTP overhead |

### GRAPH.RAG vs Multi-Hop Pipeline

| Approach | Latency | Network Hops |
|----------|---------|-------------|
| **Vex GRAPH.RAG** | ~0.2 ms | 1 (single RESP command) |
| Qdrant + Redis + traversal | ~5-15 ms | 3+ |
| Redis FT.SEARCH (no graph) | ~1-3 ms | 1 (but no expansion) |

### Memory (100K @ 768d)

| DB | Expected RSS |
|----|-------------|
| **Vex (f16 mmap)** | ~30 MB (HNSW only, vectors on disk) |
| Redis (f32) | ~350 MB |
| Qdrant (scalar quant) | ~200 MB |
| Weaviate (f32) | ~400 MB |

---

## Benchmark Outputs

The tool should produce:

1. **Latency table** (p50, p99, max) for each operation × each DB
2. **Throughput chart** (queries/sec vs concurrency)
3. **Memory table** (RSS after load)
4. **Recall@K table** (for each DB)
5. **RAG comparison table** (single-command vs multi-hop)

Output format: Markdown table (for README) + JSON (for charts).

---

## Running Benchmarks

```bash
# Start all databases
docker compose -f docker-compose.vector-bench.yml up --build -d

# Run benchmark
cd tools/vector-bench
go run . -vectors 100000 -dim 768 -k 10 -c 16 -runs 5

# Stop
docker compose -f docker-compose.vector-bench.yml down -v
```

---

## What Makes Vex Win

| Advantage | Impact |
|-----------|--------|
| **In-process HNSW** | No serialization/deserialization overhead for distance computation |
| **RESP protocol** | Lower overhead than REST/gRPC/GraphQL |
| **f16 mmap** | 2x less memory than f32, OS manages hot/cold paging |
| **GRAPH.RAG** | Single command replaces 3+ network hops. Unique — no other DB has this |
| **Zero-copy graph expand** | BFS traversal on CSR adjacency is ~0.05ms, same process as vector search |
| **Lazy init** | Zero overhead when vectors not used. Doesn't slow down KV-only workloads |

The story: Vex isn't just a faster vector database — it's the only database where "find similar documents and explore their relationships" is a single sub-millisecond command.
