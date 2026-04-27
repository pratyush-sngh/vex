package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"net"
	_ "os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ── Flags ───────────────────────────────────────────────────────────

var (
	flagVectors  = flag.Int("vectors", 10000, "number of vectors to load")
	flagDim      = flag.Int("dim", 768, "vector dimension")
	flagK        = flag.Int("k", 10, "K nearest neighbors")
	flagQueries  = flag.Int("queries", 1000, "search queries per run")
	flagC        = flag.Int("c", 16, "concurrent clients")
	flagRuns     = flag.Int("runs", 5, "median of N runs")
	flagWarmup   = flag.Int("warmup", 100, "warmup queries before measurement")
	flagRagDepth = flag.Int("rag-depth", 1, "graph expansion depth for RAG benchmark")
	flagPipeline = flag.Int("pipeline", 50, "pipeline depth for insert benchmark")
	flagVexAddr  = flag.String("vex", "localhost:6380", "Vex address")
	flagRecall   = flag.Bool("recall", false, "run recall benchmark (slow, compares vs brute force)")
	flagInsert   = flag.Bool("insert-only", false, "only run insert benchmark")
	flagSearch   = flag.Bool("search-only", false, "only run search benchmark")
)

// ── Stats ───────────────────────────────────────────────────────────

type stats struct {
	p50Us  float64
	p99Us  float64
	meanUs float64
	qps    float64
}

func summarize(samples []float64) stats {
	sort.Float64s(samples)
	n := len(samples)
	if n == 0 {
		return stats{}
	}
	var sum float64
	for _, v := range samples {
		sum += v
	}
	total := sum / 1000.0 // total ms
	return stats{
		p50Us:  samples[n/2],
		p99Us:  samples[int(float64(n)*0.99)],
		meanUs: sum / float64(n),
		qps:    float64(n) / (total / 1000.0), // queries per second
	}
}

func medianStats(all []stats) stats {
	n := len(all)
	if n == 0 {
		return stats{}
	}
	p50s := make([]float64, n)
	p99s := make([]float64, n)
	means := make([]float64, n)
	qpss := make([]float64, n)
	for i, s := range all {
		p50s[i] = s.p50Us
		p99s[i] = s.p99Us
		means[i] = s.meanUs
		qpss[i] = s.qps
	}
	sort.Float64s(p50s)
	sort.Float64s(p99s)
	sort.Float64s(means)
	sort.Float64s(qpss)
	return stats{
		p50Us:  p50s[n/2],
		p99Us:  p99s[n/2],
		meanUs: means[n/2],
		qps:    qpss[n/2],
	}
}

// ── Vector helpers ──────────────────────────────────────────────────

func randomUnitVector(dim int, rng *rand.Rand) []float32 {
	vec := make([]float32, dim)
	var norm float64
	for i := range vec {
		v := float32(rng.NormFloat64())
		vec[i] = v
		norm += float64(v * v)
	}
	inv := float32(1.0 / math.Sqrt(norm))
	for i := range vec {
		vec[i] *= inv
	}
	return vec
}

func vecToBytes(vec []float32) []byte {
	buf := make([]byte, len(vec)*4)
	for i, v := range vec {
		binary.LittleEndian.PutUint32(buf[i*4:], math.Float32bits(v))
	}
	return buf
}

func cosineDistance(a, b []float32) float64 {
	var dot float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
	}
	return 1.0 - dot
}

// ── RESP client ─────────────────────────────────────────────────────

type client struct {
	conn net.Conn
	r    *bufio.Reader
}

func newClient(addr string) (*client, error) {
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	return &client{conn: conn, r: bufio.NewReaderSize(conn, 64*1024)}, nil
}

func (c *client) close() { _ = c.conn.Close() }

func (c *client) sendRaw(data []byte) error {
	_, err := c.conn.Write(data)
	return err
}

func (c *client) readReply() (string, error) {
	line, err := c.r.ReadString('\n')
	if err != nil {
		return "", err
	}
	line = strings.TrimRight(line, "\r\n")
	if len(line) == 0 {
		return "", errors.New("empty reply")
	}
	switch line[0] {
	case '+':
		return line[1:], nil
	case '-':
		return "", fmt.Errorf("redis error: %s", line[1:])
	case ':':
		return line[1:], nil
	case '$':
		n, _ := strconv.Atoi(line[1:])
		if n < 0 {
			return "", nil // nil bulk
		}
		buf := make([]byte, n+2)
		_, err := c.r.Read(buf)
		if err != nil {
			return "", err
		}
		return string(buf[:n]), nil
	case '*':
		n, _ := strconv.Atoi(line[1:])
		if n < 0 {
			return "", nil
		}
		// Read all sub-elements (consume them)
		for i := 0; i < n; i++ {
			_, err := c.readReply()
			if err != nil {
				return "", err
			}
		}
		return fmt.Sprintf("(array %d)", n), nil
	}
	return line, nil
}

func (c *client) cmd(parts ...string) (string, error) {
	return c.cmdBytes(parts, nil)
}

func (c *client) cmdBytes(strParts []string, binParts [][]byte) (string, error) {
	totalArgs := len(strParts) + len(binParts)
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "*%d\r\n", totalArgs)
	for _, p := range strParts {
		fmt.Fprintf(&buf, "$%d\r\n%s\r\n", len(p), p)
	}
	for _, b := range binParts {
		fmt.Fprintf(&buf, "$%d\r\n", len(b))
		buf.Write(b)
		buf.WriteString("\r\n")
	}
	if err := c.sendRaw(buf.Bytes()); err != nil {
		return "", err
	}
	return c.readReply()
}

// ── Benchmark runner ────────────────────────────────────────────────

func benchParallel(n int, workers int, fn func(i int, worker int) error) ([]float64, error) {
	samples := make([]float64, n)
	var idx atomic.Int64
	var firstErr atomic.Value

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(wid int) {
			defer wg.Done()
			for {
				i := int(idx.Add(1)) - 1
				if i >= n {
					return
				}
				start := time.Now()
				if err := fn(i, wid); err != nil {
					firstErr.CompareAndSwap(nil, err)
					return
				}
				samples[i] = float64(time.Since(start).Microseconds())
			}
		}(w)
	}
	wg.Wait()

	if v := firstErr.Load(); v != nil {
		return nil, v.(error)
	}
	return samples[:idx.Load()], nil
}

func main() {
	flag.Parse()
	dim := *flagDim
	numVectors := *flagVectors
	k := *flagK
	queries := *flagQueries
	c := *flagC
	runs := *flagRuns
	warmup := *flagWarmup

	fmt.Printf("Vector Benchmark: %d vectors, %d dims, K=%d, c=%d, %d runs\n\n", numVectors, dim, k, c, runs)

	// ── Generate dataset ────────────────────────────────────────────
	fmt.Printf("Generating %d random vectors (%d dims)...\n", numVectors, dim)
	rng := rand.New(rand.NewSource(42))
	vectors := make([][]float32, numVectors)
	for i := range vectors {
		vectors[i] = randomUnitVector(dim, rng)
	}
	queryVecs := make([][]float32, queries+warmup)
	for i := range queryVecs {
		queryVecs[i] = randomUnitVector(dim, rng)
	}
	fmt.Printf("Dataset ready.\n\n")

	if !*flagSearch {
		// ── Insert benchmark ────────────────────────────────────────
		benchInsert(*flagVexAddr, vectors, dim)
	}

	if !*flagInsert {
		// ── Search benchmark ────────────────────────────────────────
		benchSearch(*flagVexAddr, queryVecs, warmup, queries, k, c, runs)

		// ── RAG benchmark ───────────────────────────────────────────
		benchRAG(*flagVexAddr, queryVecs, warmup, queries, k, *flagRagDepth, c, runs)
	}

	if *flagRecall {
		// ── Recall benchmark ────────────────────────────────────────
		benchRecall(*flagVexAddr, vectors, queryVecs[:100], k)
	}
}

// ── Insert Benchmark ────────────────────────────────────────────────

func benchInsert(addr string, vectors [][]float32, dim int) {
	fmt.Println("=== INSERT BENCHMARK ===")

	cl, err := newClient(addr)
	if err != nil {
		fmt.Printf("  connect error: %v\n", err)
		return
	}
	defer cl.close()

	// Flush existing data
	cl.cmd("FLUSHALL")

	pipeline := *flagPipeline
	numVectors := len(vectors)

	// Phase 1: Create graph nodes (pipelined)
	fmt.Printf("  Creating %d graph nodes (pipeline=%d)...\n", numVectors, pipeline)
	start := time.Now()
	for batch := 0; batch < numVectors; batch += pipeline {
		end := batch + pipeline
		if end > numVectors {
			end = numVectors
		}
		var buf bytes.Buffer
		for i := batch; i < end; i++ {
			key := fmt.Sprintf("doc:%d", i)
			args := []string{"GRAPH.ADDNODE", key, "document"}
			fmt.Fprintf(&buf, "*%d\r\n", len(args))
			for _, a := range args {
				fmt.Fprintf(&buf, "$%d\r\n%s\r\n", len(a), a)
			}
		}
		if err := cl.sendRaw(buf.Bytes()); err != nil {
			fmt.Printf("  send error: %v\n", err)
			return
		}
		for i := batch; i < end; i++ {
			if _, err := cl.readReply(); err != nil {
				fmt.Printf("  reply error at %d: %v\n", i, err)
				return
			}
		}
	}
	nodeTime := time.Since(start)
	fmt.Printf("  Nodes: %d in %v (%.0f nodes/s)\n", numVectors, nodeTime, float64(numVectors)/nodeTime.Seconds())

	// Phase 2: Set vectors (pipelined)
	fmt.Printf("  Setting %d vectors (pipeline=%d)...\n", numVectors, pipeline)
	start = time.Now()
	for batch := 0; batch < numVectors; batch += pipeline {
		end := batch + pipeline
		if end > numVectors {
			end = numVectors
		}
		var buf bytes.Buffer
		for i := batch; i < end; i++ {
			key := fmt.Sprintf("doc:%d", i)
			vecBytes := vecToBytes(vectors[i])
			// *4\r\n$12\r\nGRAPH.SETVEC\r\n$<keylen>\r\n<key>\r\n$9\r\nembedding\r\n$<veclen>\r\n<bytes>\r\n
			fmt.Fprintf(&buf, "*4\r\n$12\r\nGRAPH.SETVEC\r\n$%d\r\n%s\r\n$9\r\nembedding\r\n$%d\r\n", len(key), key, len(vecBytes))
			buf.Write(vecBytes)
			buf.WriteString("\r\n")
		}
		if err := cl.sendRaw(buf.Bytes()); err != nil {
			fmt.Printf("  send error: %v\n", err)
			return
		}
		for i := batch; i < end; i++ {
			if _, err := cl.readReply(); err != nil {
				fmt.Printf("  reply error at %d: %v\n", i, err)
				return
			}
		}
	}
	vecTime := time.Since(start)
	fmt.Printf("  Vectors: %d in %v (%.0f vecs/s)\n", numVectors, vecTime, float64(numVectors)/vecTime.Seconds())

	// Phase 3: Add some edges for RAG testing (chain: doc:0 → doc:1 → doc:2 ...)
	fmt.Printf("  Adding %d edges for RAG...\n", numVectors-1)
	start = time.Now()
	for batch := 0; batch < numVectors-1; batch += pipeline {
		end := batch + pipeline
		if end > numVectors-1 {
			end = numVectors - 1
		}
		var buf bytes.Buffer
		for i := batch; i < end; i++ {
			from := fmt.Sprintf("doc:%d", i)
			to := fmt.Sprintf("doc:%d", i+1)
			args := []string{"GRAPH.ADDEDGE", from, to, "related"}
			fmt.Fprintf(&buf, "*%d\r\n", len(args))
			for _, a := range args {
				fmt.Fprintf(&buf, "$%d\r\n%s\r\n", len(a), a)
			}
		}
		if err := cl.sendRaw(buf.Bytes()); err != nil {
			fmt.Printf("  send error: %v\n", err)
			return
		}
		for i := batch; i < end; i++ {
			if _, err := cl.readReply(); err != nil {
				// Edges may fail if nodes don't exist, that's ok
				continue
			}
		}
	}
	edgeTime := time.Since(start)
	fmt.Printf("  Edges: %d in %v\n", numVectors-1, edgeTime)

	totalTime := nodeTime + vecTime + edgeTime
	fmt.Printf("\n  TOTAL INSERT: %d vectors in %v (%.0f vecs/s including nodes+edges)\n\n", numVectors, totalTime, float64(numVectors)/totalTime.Seconds())
}

// ── Search Benchmark ────────────────────────────────────────────────

func benchSearch(addr string, queryVecs [][]float32, warmup, queries, k, c, runs int) {
	fmt.Println("=== VECSEARCH BENCHMARK ===")

	// Create client pool
	clients := make([]*client, c)
	for i := range clients {
		cl, err := newClient(addr)
		if err != nil {
			fmt.Printf("  connect error: %v\n", err)
			return
		}
		defer cl.close()
		clients[i] = cl
	}

	// Warmup
	fmt.Printf("  Warming up (%d queries)...\n", warmup)
	for i := 0; i < warmup; i++ {
		vecBytes := vecToBytes(queryVecs[i])
		clients[0].cmdBytes([]string{"GRAPH.VECSEARCH", "embedding"}, [][]byte{vecBytes, []byte("K"), []byte(strconv.Itoa(k))})
	}

	// Benchmark runs
	allStats := make([]stats, runs)
	for r := 0; r < runs; r++ {
		samples, err := benchParallel(queries, c, func(i int, worker int) error {
			vecBytes := vecToBytes(queryVecs[warmup+i%len(queryVecs[warmup:])])
			_, err := clients[worker%c].cmdBytes(
				[]string{"GRAPH.VECSEARCH", "embedding"},
				[][]byte{vecBytes, []byte("K"), []byte(strconv.Itoa(k))},
			)
			return err
		})
		if err != nil {
			fmt.Printf("  run %d error: %v\n", r+1, err)
			return
		}
		allStats[r] = summarize(samples)
		fmt.Printf("  run %d: p50=%6.0f us  p99=%6.0f us  qps=%8.0f\n", r+1, allStats[r].p50Us, allStats[r].p99Us, allStats[r].qps)
	}

	med := medianStats(allStats)
	fmt.Printf("\n  VECSEARCH MEDIAN: p50=%6.0f us  p99=%6.0f us  mean=%6.0f us  qps=%8.0f\n\n", med.p50Us, med.p99Us, med.meanUs, med.qps)
}

// ── RAG Benchmark ───────────────────────────────────────────────────

func benchRAG(addr string, queryVecs [][]float32, warmup, queries, k, depth, c, runs int) {
	fmt.Println("=== GRAPH.RAG BENCHMARK ===")

	clients := make([]*client, c)
	for i := range clients {
		cl, err := newClient(addr)
		if err != nil {
			fmt.Printf("  connect error: %v\n", err)
			return
		}
		defer cl.close()
		clients[i] = cl
	}

	// Warmup
	for i := 0; i < warmup; i++ {
		vecBytes := vecToBytes(queryVecs[i])
		clients[0].cmdBytes(
			[]string{"GRAPH.RAG", "embedding"},
			[][]byte{vecBytes, []byte("K"), []byte(strconv.Itoa(k)), []byte("DEPTH"), []byte(strconv.Itoa(depth))},
		)
	}

	allStats := make([]stats, runs)
	for r := 0; r < runs; r++ {
		samples, err := benchParallel(queries, c, func(i int, worker int) error {
			vecBytes := vecToBytes(queryVecs[warmup+i%len(queryVecs[warmup:])])
			_, err := clients[worker%c].cmdBytes(
				[]string{"GRAPH.RAG", "embedding"},
				[][]byte{vecBytes, []byte("K"), []byte(strconv.Itoa(k)), []byte("DEPTH"), []byte(strconv.Itoa(depth))},
			)
			return err
		})
		if err != nil {
			fmt.Printf("  run %d error: %v\n", r+1, err)
			return
		}
		allStats[r] = summarize(samples)
		fmt.Printf("  run %d: p50=%6.0f us  p99=%6.0f us  qps=%8.0f\n", r+1, allStats[r].p50Us, allStats[r].p99Us, allStats[r].qps)
	}

	med := medianStats(allStats)
	fmt.Printf("\n  GRAPH.RAG MEDIAN: p50=%6.0f us  p99=%6.0f us  mean=%6.0f us  qps=%8.0f\n\n", med.p50Us, med.p99Us, med.meanUs, med.qps)
}

// ── Recall Benchmark ────────────────────────────────────────────────

func benchRecall(addr string, vectors [][]float32, queryVecs [][]float32, k int) {
	fmt.Println("=== RECALL BENCHMARK ===")
	fmt.Printf("  %d queries, K=%d, brute-force comparison...\n", len(queryVecs), k)

	cl, err := newClient(addr)
	if err != nil {
		fmt.Printf("  connect error: %v\n", err)
		return
	}
	defer cl.close()

	var totalRecall float64
	for qi, qv := range queryVecs {
		// Brute-force: compute distance to all vectors, find true top-K
		type distPair struct {
			id   int
			dist float64
		}
		dists := make([]distPair, len(vectors))
		for i, v := range vectors {
			dists[i] = distPair{id: i, dist: cosineDistance(qv, v)}
		}
		sort.Slice(dists, func(a, b int) bool { return dists[a].dist < dists[b].dist })

		trueTopK := make(map[int]bool)
		for i := 0; i < k && i < len(dists); i++ {
			trueTopK[dists[i].id] = true
		}

		// HNSW search
		vecBytes := vecToBytes(qv)
		// We need to parse the reply to get node IDs
		// VECSEARCH returns: key1, score1, key2, score2, ...
		// Parse the raw reply
		var buf bytes.Buffer
		args := []string{"GRAPH.VECSEARCH", "embedding"}
		binArgs := [][]byte{vecBytes, []byte("K"), []byte(strconv.Itoa(k))}
		totalArgs := len(args) + len(binArgs)
		fmt.Fprintf(&buf, "*%d\r\n", totalArgs)
		for _, a := range args {
			fmt.Fprintf(&buf, "$%d\r\n%s\r\n", len(a), a)
		}
		for _, b := range binArgs {
			fmt.Fprintf(&buf, "$%d\r\n", len(b))
			buf.Write(b)
			buf.WriteString("\r\n")
		}
		cl.sendRaw(buf.Bytes())

		// Read array header
		line, _ := cl.r.ReadString('\n')
		line = strings.TrimRight(line, "\r\n")
		arrayLen, _ := strconv.Atoi(line[1:])

		hits := 0
		for i := 0; i < arrayLen; i++ {
			reply, _ := cl.readReply()
			if i%2 == 0 { // key (e.g., "doc:42")
				parts := strings.Split(reply, ":")
				if len(parts) == 2 {
					id, _ := strconv.Atoi(parts[1])
					if trueTopK[id] {
						hits++
					}
				}
			}
			// odd indices are scores, skip
		}

		recall := float64(hits) / float64(k)
		totalRecall += recall

		if (qi+1)%10 == 0 {
			fmt.Printf("  query %d/%d: recall=%.2f (running avg=%.4f)\n", qi+1, len(queryVecs), recall, totalRecall/float64(qi+1))
		}
	}

	avgRecall := totalRecall / float64(len(queryVecs))
	fmt.Printf("\n  RECALL@%d: %.4f (%.1f%%)\n\n", k, avgRecall, avgRecall*100)
}
