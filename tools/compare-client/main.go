package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"math"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type target struct {
	name string
	addr string
}

type stats struct {
	minMs  float64
	p50Ms  float64
	p95Ms  float64
	p99Ms  float64
	meanMs float64
	maxMs  float64
	opsPS  float64
}

type benchCfg struct {
	n           int
	warmup      int
	runs        int
	concurrency int
}

func main() {
	var (
		redisAddr    = flag.String("redis", "127.0.0.1:16379", "Redis host:port")
		zigraphAddr  = flag.String("zigraph", "127.0.0.1:16380", "Zigraph host:port")
		n            = flag.Int("n", 5000, "timed operations per benchmark")
		warmup       = flag.Int("warmup", 0, "warmup operations per benchmark run (discarded)")
		runs         = flag.Int("runs", 1, "repeat benchmark runs and report median metrics")
		concurrency  = flag.Int("c", 1, "parallel workers (connections) per scenario")
		timeout      = flag.Duration("timeout", 3*time.Second, "dial/read/write timeout")
		zigraphFirst = flag.Bool("zigraph-first", false, "run zigraph before redis for KV scenarios")
	)
	flag.Parse()
	if *concurrency < 1 {
		*concurrency = 1
	}
	if *runs < 1 {
		*runs = 1
	}
	if *warmup < 0 {
		*warmup = 0
	}

	targets := []target{
		{name: "redis", addr: *redisAddr},
		{name: "zigraph", addr: *zigraphAddr},
	}
	if *zigraphFirst {
		targets[0], targets[1] = targets[1], targets[0]
	}

	cfg := benchCfg{
		n:           *n,
		warmup:      *warmup,
		runs:        *runs,
		concurrency: *concurrency,
	}

	fmt.Printf("Running common KV benchmarks, timed_n=%d, warmup=%d, runs=%d\n\n", cfg.n, cfg.warmup, cfg.runs)
	for _, t := range targets {
		clients := make([]*client, 0, cfg.concurrency)
		for i := 0; i < cfg.concurrency; i++ {
			c, err := newClient(t.addr, *timeout)
			if err != nil {
				fmt.Printf("[%s] connect failed: %v\n", t.name, err)
				for _, cc := range clients {
					cc.close()
				}
				clients = nil
				break
			}
			clients = append(clients, c)
		}
		if len(clients) == 0 {
			continue
		}
		for _, c := range clients {
			defer c.close()
		}

		if err := clients[0].ping(); err != nil {
			fmt.Printf("[%s] ping failed: %v\n", t.name, err)
			continue
		}

		fmt.Printf("== %s (%s) ==\n", t.name, t.addr)
		if err := clients[0].cmd("FLUSHDB"); err != nil {
			fmt.Printf("flushdb failed: %v\n\n", err)
			continue
		}

		printBench("SET", cfg, func(i int, worker int) error {
			key := fmt.Sprintf("k:%d", i)
			val := fmt.Sprintf("v:%d", i)
			return clients[worker%len(clients)].cmd("SET", key, val)
		})

		printBench("GET (hit)", cfg, func(i int, worker int) error {
			key := fmt.Sprintf("k:%d", i)
			return clients[worker%len(clients)].cmd("GET", key)
		})

		printBench("DEL", cfg, func(i int, worker int) error {
			key := fmt.Sprintf("k:%d", i)
			return clients[worker%len(clients)].cmd("DEL", key)
		})
		fmt.Println()
	}

	// Zigraph-only graph commands.
	fmt.Printf("Running Zigraph graph benchmark, timed_n=%d, warmup=%d, runs=%d\n\n", cfg.n, cfg.warmup, cfg.runs)
	zclients := make([]*client, 0, cfg.concurrency)
	for i := 0; i < cfg.concurrency; i++ {
		zc, err := newClient(*zigraphAddr, *timeout)
		if err != nil {
			fmt.Printf("[zigraph] connect failed: %v\n", err)
			for _, cc := range zclients {
				cc.close()
			}
			os.Exit(1)
		}
		zclients = append(zclients, zc)
	}
	for _, c := range zclients {
		defer c.close()
	}
	if err := zclients[0].cmd("FLUSHDB"); err != nil {
		fmt.Printf("[zigraph] flush failed: %v\n", err)
		os.Exit(1)
	}

	printGraphBench("GRAPH.ADDNODE", cfg, func(i int, worker int, runID int64) error {
		return zclients[worker%len(zclients)].cmd("GRAPH.ADDNODE", fmt.Sprintf("svc:%d:%d", runID, i), "service")
	})
	printGraphEdgeBench("GRAPH.ADDEDGE", benchCfg{
		n:           cfg.n - 1,
		warmup:      max(cfg.warmup-1, 0),
		runs:        cfg.runs,
		concurrency: cfg.concurrency,
	}, zclients)
}

func bench(n int, fn func(i int) error) (stats, error) {
	if n <= 0 {
		return stats{}, errors.New("n must be > 0")
	}
	samples := make([]float64, 0, n)
	startAll := time.Now()
	for i := 0; i < n; i++ {
		start := time.Now()
		if err := fn(i); err != nil {
			return stats{}, err
		}
		samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
	}
	total := time.Since(startAll).Seconds() * 1000
	return summarize(samples, total, n), nil
}

func summarize(samples []float64, totalMs float64, n int) stats {
	cp := append([]float64(nil), samples...)
	sort.Float64s(cp)
	minV := cp[0]
	maxV := cp[len(cp)-1]
	p50 := cp[(len(cp)-1)/2]
	p95 := cp[int(math.Ceil(float64(len(cp))*0.95))-1]
	p99 := cp[int(math.Ceil(float64(len(cp))*0.99))-1]
	sum := 0.0
	for _, s := range cp {
		sum += s
	}
	mean := sum / float64(len(cp))
	opsPerSec := 0.0
	if totalMs > 0 {
		opsPerSec = float64(n) * 1000.0 / totalMs
	}
	return stats{
		minMs:  minV,
		p50Ms:  p50,
		p95Ms:  p95,
		p99Ms:  p99,
		meanMs: mean,
		maxMs:  maxV,
		opsPS:  opsPerSec,
	}
}

func printScenario(name string, s stats, err error) {
	if err != nil {
		fmt.Printf("%-16s error: %v\n", name, err)
		return
	}
	fmt.Printf("%-16s min=%6.3fms p50=%6.3fms p95=%6.3fms p99=%6.3fms mean=%6.3fms max=%6.3fms ops/s=%8.1f\n",
		name, s.minMs, s.p50Ms, s.p95Ms, s.p99Ms, s.meanMs, s.maxMs, s.opsPS)
}

func printBench(name string, cfg benchCfg, fn func(i int, worker int) error) {
	runStats := make([]stats, 0, cfg.runs)
	for run := 0; run < cfg.runs; run++ {
		if cfg.warmup > 0 {
			_, err := benchParallel(cfg.warmup, cfg.concurrency, fn)
			if err != nil {
				fmt.Printf("%-16s warmup run=%d error: %v\n", name, run+1, err)
				return
			}
		}
		s, err := benchParallel(cfg.n, cfg.concurrency, fn)
		if err != nil {
			printScenario(name, s, err)
			return
		}
		runStats = append(runStats, s)
	}
	agg := medianStats(runStats)
	fmt.Printf("%-16s runs=%d min=%6.3fms p50=%6.3fms p95=%6.3fms p99=%6.3fms mean=%6.3fms max=%6.3fms ops/s=%8.1f\n",
		name, cfg.runs, agg.minMs, agg.p50Ms, agg.p95Ms, agg.p99Ms, agg.meanMs, agg.maxMs, agg.opsPS)
}

func printGraphBench(name string, cfg benchCfg, fn func(i int, worker int, runID int64) error) {
	runStats := make([]stats, 0, cfg.runs)
	for run := 0; run < cfg.runs; run++ {
		warmupRunID := time.Now().UnixNano() + int64(run*2)
		timedRunID := warmupRunID + 1
		warmupFn := func(i int, worker int) error {
			return fn(i, worker, warmupRunID)
		}
		timedFn := func(i int, worker int) error {
			return fn(i, worker, timedRunID)
		}

		if cfg.warmup > 0 {
			_, err := benchParallel(cfg.warmup, cfg.concurrency, warmupFn)
			if err != nil {
				fmt.Printf("%-16s warmup run=%d error: %v\n", name, run+1, err)
				return
			}
		}

		s, err := benchParallel(cfg.n, cfg.concurrency, timedFn)
		if err != nil {
			printScenario(name, s, err)
			return
		}
		runStats = append(runStats, s)
	}
	agg := medianStats(runStats)
	fmt.Printf("%-16s runs=%d min=%6.3fms p50=%6.3fms p95=%6.3fms p99=%6.3fms mean=%6.3fms max=%6.3fms ops/s=%8.1f\n",
		name, cfg.runs, agg.minMs, agg.p50Ms, agg.p95Ms, agg.p99Ms, agg.meanMs, agg.maxMs, agg.opsPS)
}

func printGraphEdgeBench(name string, cfg benchCfg, clients []*client) {
	runStats := make([]stats, 0, cfg.runs)
	for run := 0; run < cfg.runs; run++ {
		warmupRunID := time.Now().UnixNano() + int64(run*2)
		timedRunID := warmupRunID + 1

		if cfg.warmup > 0 {
			if err := createGraphChainNodes(clients[0], warmupRunID, cfg.warmup+1); err != nil {
				fmt.Printf("%-16s warmup run=%d setup error: %v\n", name, run+1, err)
				return
			}
			warmupFn := func(i int, worker int) error {
				return clients[worker%len(clients)].cmd(
					"GRAPH.ADDEDGE",
					fmt.Sprintf("svc:%d:%d", warmupRunID, i),
					fmt.Sprintf("svc:%d:%d", warmupRunID, i+1),
					"calls",
				)
			}
			_, err := benchParallel(cfg.warmup, cfg.concurrency, warmupFn)
			if err != nil {
				fmt.Printf("%-16s warmup run=%d error: %v\n", name, run+1, err)
				return
			}
		}

		if err := createGraphChainNodes(clients[0], timedRunID, cfg.n+1); err != nil {
			fmt.Printf("%-16s run=%d setup error: %v\n", name, run+1, err)
			return
		}
		timedFn := func(i int, worker int) error {
			return clients[worker%len(clients)].cmd(
				"GRAPH.ADDEDGE",
				fmt.Sprintf("svc:%d:%d", timedRunID, i),
				fmt.Sprintf("svc:%d:%d", timedRunID, i+1),
				"calls",
			)
		}
		s, err := benchParallel(cfg.n, cfg.concurrency, timedFn)
		if err != nil {
			printScenario(name, s, err)
			return
		}
		runStats = append(runStats, s)
	}
	agg := medianStats(runStats)
	fmt.Printf("%-16s runs=%d min=%6.3fms p50=%6.3fms p95=%6.3fms p99=%6.3fms mean=%6.3fms max=%6.3fms ops/s=%8.1f\n",
		name, cfg.runs, agg.minMs, agg.p50Ms, agg.p95Ms, agg.p99Ms, agg.meanMs, agg.maxMs, agg.opsPS)
}

func createGraphChainNodes(c *client, runID int64, count int) error {
	for i := 0; i < count; i++ {
		if err := c.cmd("GRAPH.ADDNODE", fmt.Sprintf("svc:%d:%d", runID, i), "service"); err != nil {
			return err
		}
	}
	return nil
}

func benchParallel(n int, workers int, fn func(i int, worker int) error) (stats, error) {
	if workers <= 1 {
		return bench(n, func(i int) error { return fn(i, 0) })
	}
	if n <= 0 {
		return stats{}, errors.New("n must be > 0")
	}

	samples := make([]float64, n)
	startAll := time.Now()
	var next atomic.Int64
	var firstErr atomic.Value
	var wg sync.WaitGroup

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				start := time.Now()
				if err := fn(i, worker); err != nil {
					if firstErr.Load() == nil {
						firstErr.Store(err)
					}
					return
				}
				samples[i] = float64(time.Since(start).Microseconds()) / 1000.0
			}
		}(w)
	}
	wg.Wait()

	if v := firstErr.Load(); v != nil {
		return stats{}, v.(error)
	}
	total := time.Since(startAll).Seconds() * 1000
	return summarize(samples, total, n), nil
}

func medianStats(all []stats) stats {
	cp := append([]stats(nil), all...)
	sort.Slice(cp, func(i, j int) bool { return cp[i].p95Ms < cp[j].p95Ms })
	m := cp[(len(cp)-1)/2]

	p99Vals := make([]float64, len(cp))
	opsVals := make([]float64, len(cp))
	for i, s := range cp {
		p99Vals[i] = s.p99Ms
		opsVals[i] = s.opsPS
	}
	sort.Float64s(p99Vals)
	sort.Float64s(opsVals)
	m.p99Ms = p99Vals[(len(p99Vals)-1)/2]
	m.opsPS = opsVals[(len(opsVals)-1)/2]
	return m
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

type client struct {
	conn    net.Conn
	rd      *bufio.Reader
	timeout time.Duration
}

func newClient(addr string, timeout time.Duration) (*client, error) {
	c, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, err
	}
	_ = c.SetDeadline(time.Now().Add(timeout))
	return &client{conn: c, rd: bufio.NewReader(c), timeout: timeout}, nil
}

func (c *client) close() { _ = c.conn.Close() }

func (c *client) ping() error { return c.cmd("PING") }

func (c *client) cmd(parts ...string) error {
	_ = c.conn.SetDeadline(time.Now().Add(c.timeout))
	payload := encodeArray(parts)
	if _, err := c.conn.Write(payload); err != nil {
		return err
	}
	_, err := readRESP(c.rd)
	return err
}

func encodeArray(parts []string) []byte {
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
	return []byte(b.String())
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
		if _, err = r.Read(buf); err != nil {
			return nil, err
		}
		return string(buf[:n]), nil
	case '*':
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(strings.TrimSpace(line))
		if err != nil {
			return nil, err
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
		return nil, fmt.Errorf("unknown RESP type byte: %q", t)
	}
}
