# Next Steps: Vector Search Branch

## What's Done

- `worktree-vector-search` branch pushed to GitHub with 6 commits
- GRAPH.SETVEC/GETVEC/VECSEARCH/RAG commands working (161 tests passing)
- f16 quantization + mmap-backed .vvf files
- Dual-tier VectorStore (write buffer → mmap)
- Lazy init (zero cost when vectors unused)
- Persistence wired into SAVE/BGSAVE/startup/shutdown
- Docs: vector-search.md, vector-benchmarks.md
- Benchmark tool built: tools/vector-bench/main.go (compiles, not yet run)

## What's Left

### 1. Smoke Test the Benchmark Tool

```bash
cd /Users/pratyushsingh/fundsindia/personal_project/zigraph/.claude/worktrees/vector-search

# Build Vex
zig build -Doptimize=ReleaseFast

# Start Vex
./zig-out/bin/vex --reactor --port 16390 --no-persistence --workers 4 &

# Run small benchmark (1K vectors, quick)
cd tools/vector-bench
go run . -vectors 1000 -dim 768 -k 10 -c 4 -runs 3 -vex localhost:16390

# Run full benchmark (10K vectors)
go run . -vectors 10000 -dim 768 -k 10 -c 16 -runs 5 -vex localhost:16390

# Run with recall check
go run . -vectors 10000 -dim 768 -k 10 -c 1 -runs 1 -recall -vex localhost:16390

# Stop Vex
kill %1
```

### 2. Run Comparative Benchmarks (Docker)

Create `docker-compose.vector-bench.yml` with Vex + Redis+RediSearch + Qdrant + Weaviate, all CPU-pinned. Then extend the Go benchmark tool to also benchmark:
- Redis: FT.CREATE + FT.SEARCH with vector fields
- Qdrant: REST API /collections/points/search
- Weaviate: GraphQL nearVector queries

### 3. Merge to Main

```bash
git checkout main
git merge worktree-vector-search
git push origin main
```

### 4. Tag Release

```bash
git tag v0.6.0
git push origin v0.6.0
# Triggers GitHub Actions → Docker image build
```

### 5. Update ReviewGraph Roadmap

The Vex prerequisites in `/Users/pratyushsingh/fundsindia/ReviewGraph/VECTOR-SEARCH-ROADMAP.md` are now all met:
- [x] Vector search commands (GRAPH.SETVEC/VECSEARCH/RAG)
- [x] Snapshot persistence (.vvf files)
- [x] f16 quantization
- [x] mmap for vector data

Can start Phase 1 of the ReviewGraph integration (embed on ingest + graphclient interface).
