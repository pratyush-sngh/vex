package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"math/rand"
	"net"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

func main() {
	var (
		vexAddr    = flag.String("vex", "127.0.0.1:17380", "Vex host:port")
		mgAddr     = flag.String("memgraph", "bolt://127.0.0.1:17687", "Memgraph bolt URL")
		nodes      = flag.Int("nodes", 5000, "number of nodes to create")
		edgesPerN  = flag.Int("edges", 5, "edges per node")
		depth      = flag.Int("depth", 3, "BFS traverse depth")
		runs       = flag.Int("runs", 3, "benchmark runs (median)")
		timeout    = flag.Duration("timeout", 30*time.Second, "connection timeout")
	)
	flag.Parse()

	totalEdges := *nodes * *edgesPerN

	fmt.Printf("\n=== Graph DB Benchmark ===\n")
	fmt.Printf("Nodes: %d, Edges/node: %d, Total edges: %d, Depth: %d, Runs: %d\n\n", *nodes, *edgesPerN, totalEdges, *depth, *runs)

	// ── Memgraph ──
	fmt.Println("--- Memgraph ---")
	benchMemgraph(*mgAddr, *nodes, *edgesPerN, *depth, *runs)

	fmt.Println()

	// ── Vex ──
	fmt.Println("--- Vex ---")
	benchVex(*vexAddr, *nodes, *edgesPerN, *depth, *runs, *timeout)

	fmt.Println("\n=== Done ===")
}

// ─── Memgraph benchmark ───

func benchMemgraph(uri string, nodeCount, edgesPerNode, depth, runs int) {
	ctx := context.Background()
	driver, err := neo4j.NewDriverWithContext(uri, neo4j.NoAuth())
	if err != nil {
		fmt.Printf("  connect failed: %v\n", err)
		return
	}
	defer driver.Close(ctx)

	if err := driver.VerifyConnectivity(ctx); err != nil {
		fmt.Printf("  connectivity check failed: %v\n", err)
		return
	}

	// Clear
	session := driver.NewSession(ctx, neo4j.SessionConfig{})
	_, _ = session.Run(ctx, "MATCH (n) DETACH DELETE n", nil)
	session.Close(ctx)

	// Bench: Add nodes
	addNodeTimes := make([]float64, 0, runs)
	for r := 0; r < runs; r++ {
		session := driver.NewSession(ctx, neo4j.SessionConfig{})
		// Clear between runs
		_, _ = session.Run(ctx, "MATCH (n) DETACH DELETE n", nil)

		start := time.Now()
		for i := 0; i < nodeCount; i++ {
			_, err := session.Run(ctx, "CREATE (:Node {name: $name, type: 'service'})",
				map[string]any{"name": fmt.Sprintf("n%d", i)})
			if err != nil {
				fmt.Printf("  addNode error: %v\n", err)
				break
			}
		}
		elapsed := time.Since(start)
		addNodeTimes = append(addNodeTimes, float64(elapsed.Microseconds())/float64(nodeCount))
		session.Close(ctx)
	}
	fmt.Printf("  AddNode:   %6.1f us/op (median)\n", median(addNodeTimes))

	// Populate for edge + query benchmarks
	session = driver.NewSession(ctx, neo4j.SessionConfig{})
	_, _ = session.Run(ctx, "MATCH (n) DETACH DELETE n", nil)
	for i := 0; i < nodeCount; i++ {
		session.Run(ctx, "CREATE (:Node {name: $name, type: 'service'})",
			map[string]any{"name": fmt.Sprintf("n%d", i)})
	}
	// Create index for faster MATCH
	session.Run(ctx, "CREATE INDEX ON :Node(name)", nil)

	// Bench: Add edges
	rng := rand.New(rand.NewSource(42))
	addEdgeTimes := make([]float64, 0, runs)
	edgeCount := 0
	for r := 0; r < runs; r++ {
		// Remove edges only
		_, _ = session.Run(ctx, "MATCH ()-[r]->() DELETE r", nil)
		rng = rand.New(rand.NewSource(42))

		start := time.Now()
		count := 0
		for i := 0; i < nodeCount; i++ {
			for j := 0; j < edgesPerNode; j++ {
				target := rng.Intn(nodeCount)
				if target == i {
					continue
				}
				_, err := session.Run(ctx,
					"MATCH (a:Node {name: $from}), (b:Node {name: $to}) CREATE (a)-[:CALLS]->(b)",
					map[string]any{"from": fmt.Sprintf("n%d", i), "to": fmt.Sprintf("n%d", target)})
				if err != nil {
					continue
				}
				count++
			}
		}
		elapsed := time.Since(start)
		edgeCount = count
		addEdgeTimes = append(addEdgeTimes, float64(elapsed.Microseconds())/float64(max(count, 1)))
	}
	fmt.Printf("  AddEdge:   %6.1f us/op (median, %d edges)\n", median(addEdgeTimes), edgeCount)

	// Bench: BFS Traverse
	traverseTimes := make([]float64, 0, runs)
	for r := 0; r < runs; r++ {
		start := time.Now()
		result, err := session.Run(ctx,
			fmt.Sprintf("MATCH (start:Node {name: 'n0'})-[*1..%d]->(m) RETURN DISTINCT m.name", depth), nil)
		if err != nil {
			fmt.Printf("  traverse error: %v\n", err)
			continue
		}
		count := 0
		for result.Next(ctx) {
			count++
		}
		elapsed := time.Since(start)
		traverseTimes = append(traverseTimes, float64(elapsed.Microseconds()))
	}
	fmt.Printf("  Traverse:  %6.0f us (depth=%d, median)\n", median(traverseTimes), depth)

	// Bench: Shortest Path
	pathTimes := make([]float64, 0, runs)
	target := fmt.Sprintf("n%d", nodeCount/2)
	for r := 0; r < runs; r++ {
		start := time.Now()
		result, err := session.Run(ctx,
			"MATCH p = (a:Node {name: 'n0'})-[*BFS]-(b:Node {name: $target}) RETURN length(p) LIMIT 1",
			map[string]any{"target": target})
		if err == nil {
			for result.Next(ctx) {
			}
		}
		if err != nil {
			fmt.Printf("  path error: %v\n", err)
			continue
		}
		elapsed := time.Since(start)
		pathTimes = append(pathTimes, float64(elapsed.Microseconds()))
	}
	fmt.Printf("  ShortPath: %6.0f us (median)\n", median(pathTimes))

	// Bench: Neighbors
	neighborTimes := make([]float64, 0, runs)
	for r := 0; r < runs; r++ {
		start := time.Now()
		result, err := session.Run(ctx,
			"MATCH (n:Node {name: 'n0'})-->(m) RETURN m.name", nil)
		if err != nil {
			fmt.Printf("  neighbors error: %v\n", err)
			continue
		}
		for result.Next(ctx) {
		}
		elapsed := time.Since(start)
		neighborTimes = append(neighborTimes, float64(elapsed.Microseconds()))
	}
	fmt.Printf("  Neighbors: %6.0f us (median)\n", median(neighborTimes))

	session.Close(ctx)
}

// ─── Vex benchmark ───

func benchVex(addr string, nodeCount, edgesPerNode, depth, runs int, timeout time.Duration) {
	c, err := newVexClient(addr, timeout)
	if err != nil {
		fmt.Printf("  connect failed: %v\n", err)
		return
	}
	defer c.close()

	if err := c.cmd("PING"); err != nil {
		fmt.Printf("  ping failed: %v\n", err)
		return
	}

	// Bench: Add nodes
	addNodeTimes := make([]float64, 0, runs)
	for r := 0; r < runs; r++ {
		_ = c.cmd("FLUSHALL")
		start := time.Now()
		for i := 0; i < nodeCount; i++ {
			if err := c.cmd("GRAPH.ADDNODE", fmt.Sprintf("n%d", i), "service"); err != nil {
				fmt.Printf("  addNode error: %v\n", err)
				break
			}
		}
		elapsed := time.Since(start)
		addNodeTimes = append(addNodeTimes, float64(elapsed.Microseconds())/float64(nodeCount))
	}
	fmt.Printf("  AddNode:   %6.1f us/op (median)\n", median(addNodeTimes))

	// Populate for edge + query benchmarks
	_ = c.cmd("FLUSHALL")
	for i := 0; i < nodeCount; i++ {
		c.cmd("GRAPH.ADDNODE", fmt.Sprintf("n%d", i), "service")
	}

	// Bench: Add edges
	rng := rand.New(rand.NewSource(42))
	addEdgeTimes := make([]float64, 0, runs)
	edgeCount := 0
	for r := 0; r < runs; r++ {
		// Can't easily delete edges only in Vex, so repopulate
		_ = c.cmd("FLUSHALL")
		for i := 0; i < nodeCount; i++ {
			c.cmd("GRAPH.ADDNODE", fmt.Sprintf("n%d", i), "service")
		}
		rng = rand.New(rand.NewSource(42))

		start := time.Now()
		count := 0
		for i := 0; i < nodeCount; i++ {
			for j := 0; j < edgesPerNode; j++ {
				target := rng.Intn(nodeCount)
				if target == i {
					continue
				}
				if err := c.cmd("GRAPH.ADDEDGE", fmt.Sprintf("n%d", i), fmt.Sprintf("n%d", target), "calls"); err != nil {
					continue
				}
				count++
			}
		}
		elapsed := time.Since(start)
		edgeCount = count
		addEdgeTimes = append(addEdgeTimes, float64(elapsed.Microseconds())/float64(max(count, 1)))
	}
	fmt.Printf("  AddEdge:   %6.1f us/op (median, %d edges)\n", median(addEdgeTimes), edgeCount)

	// Bench: BFS Traverse
	traverseTimes := make([]float64, 0, runs)
	for r := 0; r < runs; r++ {
		start := time.Now()
		if err := c.cmd("GRAPH.TRAVERSE", "n0", "DEPTH", strconv.Itoa(depth), "DIR", "OUT"); err != nil {
			fmt.Printf("  traverse error: %v\n", err)
			continue
		}
		elapsed := time.Since(start)
		traverseTimes = append(traverseTimes, float64(elapsed.Microseconds()))
	}
	fmt.Printf("  Traverse:  %6.0f us (depth=%d, median)\n", median(traverseTimes), depth)

	// Bench: Shortest Path
	pathTimes := make([]float64, 0, runs)
	target := fmt.Sprintf("n%d", nodeCount/2)
	for r := 0; r < runs; r++ {
		start := time.Now()
		if err := c.cmd("GRAPH.PATH", "n0", target); err != nil {
			// Path might not exist
			continue
		}
		elapsed := time.Since(start)
		pathTimes = append(pathTimes, float64(elapsed.Microseconds()))
	}
	if len(pathTimes) > 0 {
		fmt.Printf("  ShortPath: %6.0f us (median)\n", median(pathTimes))
	} else {
		fmt.Printf("  ShortPath: no path found\n")
	}

	// Bench: Neighbors
	neighborTimes := make([]float64, 0, runs)
	for r := 0; r < runs; r++ {
		start := time.Now()
		if err := c.cmd("GRAPH.NEIGHBORS", "n0", "OUT"); err != nil {
			fmt.Printf("  neighbors error: %v\n", err)
			continue
		}
		elapsed := time.Since(start)
		neighborTimes = append(neighborTimes, float64(elapsed.Microseconds()))
	}
	fmt.Printf("  Neighbors: %6.0f us (median)\n", median(neighborTimes))
}

// ─── Helpers ───

func median(vals []float64) float64 {
	if len(vals) == 0 {
		return 0
	}
	cp := make([]float64, len(vals))
	copy(cp, vals)
	sort.Float64s(cp)
	return cp[len(cp)/2]
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// ─── Vex RESP client (reused from compare-client) ───

type vexClient struct {
	conn    net.Conn
	rd      *bufio.Reader
	timeout time.Duration
}

func newVexClient(addr string, timeout time.Duration) (*vexClient, error) {
	c, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, err
	}
	return &vexClient{conn: c, rd: bufio.NewReader(c), timeout: timeout}, nil
}

func (c *vexClient) close() { _ = c.conn.Close() }

func (c *vexClient) cmd(parts ...string) error {
	_ = c.conn.SetDeadline(time.Now().Add(c.timeout))
	var b strings.Builder
	b.WriteString("*")
	b.WriteString(strconv.Itoa(len(parts)))
	b.WriteString("\r\n")
	for _, p := range parts {
		b.WriteString("$")
		b.WriteString(strconv.Itoa(len(p)))
		b.WriteString("\r\n")
		b.WriteString(p)
		b.WriteString("\r\n")
	}
	if _, err := c.conn.Write([]byte(b.String())); err != nil {
		return err
	}
	_, err := readRESP(c.rd)
	return err
}

func readRESP(r *bufio.Reader) (any, error) {
	t, err := r.ReadByte()
	if err != nil {
		return nil, err
	}
	switch t {
	case '+', ':':
		line, err := r.ReadString('\n')
		return strings.TrimSpace(line), err
	case '-':
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		return nil, errors.New(strings.TrimSpace(line))
	case '$':
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(strings.TrimSpace(line))
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil
		}
		buf := make([]byte, n+2)
		_, err = r.Read(buf)
		return string(buf[:n]), err
	case '*':
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(strings.TrimSpace(line))
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil
		}
		arr := make([]any, 0, n)
		for i := 0; i < n; i++ {
			v, err := readRESP(r)
			if err != nil {
				return nil, err
			}
			arr = append(arr, v)
		}
		return arr, nil
	default:
		return nil, fmt.Errorf("unknown RESP type: %q", t)
	}
}
