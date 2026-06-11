// drain-client: a near-zero-CPU load generator for fixed-size replies.
//
// Standard benchmark clients (redis-benchmark, compare-client) fully parse
// every RESP reply; on big-multibulk commands like HGETALL over a large hash
// that parse cost pins the client thread long before the server saturates,
// so the measurement reflects the client, not the server.
//
// This client RESP-parses ONE reply per connection to learn its byte size,
// then relies on the reply being byte-identical for a static key (no
// concurrent mutation) and just io.ReadFull's exact byte counts. Client cost
// per op drops to a syscall pair, so the server is the thing being measured.
//
// Usage:
//
//	drain-client -addr 127.0.0.1:6380 -conns 32 -pipeline 1 -duration 10s -cmd HGETALL -key bigh
package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"sync/atomic"
	"time"
)

func buildReq(cmd, key string) []byte {
	return []byte(fmt.Sprintf("*2\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", len(cmd), cmd, len(key), key))
}

// skipReply consumes exactly one RESP value from r and returns its byte size.
func skipReply(r *bufio.Reader) (int, error) {
	line, err := r.ReadBytes('\n')
	if err != nil {
		return 0, err
	}
	n := len(line)
	switch line[0] {
	case '+', '-', ':':
		return n, nil
	case '$':
		var blen int
		if _, err := fmt.Sscanf(string(line[1:len(line)-2]), "%d", &blen); err != nil {
			return 0, err
		}
		if blen < 0 {
			return n, nil
		}
		if _, err := io.CopyN(io.Discard, r, int64(blen+2)); err != nil {
			return 0, err
		}
		return n + blen + 2, nil
	case '*', '%':
		var elems int
		if _, err := fmt.Sscanf(string(line[1:len(line)-2]), "%d", &elems); err != nil {
			return 0, err
		}
		if line[0] == '%' {
			elems *= 2
		}
		for i := 0; i < elems; i++ {
			en, err := skipReply(r)
			if err != nil {
				return 0, err
			}
			n += en
		}
		return n, nil
	}
	return 0, fmt.Errorf("unexpected RESP type byte %q", line[0])
}

func main() {
	addr := flag.String("addr", "127.0.0.1:6380", "server host:port")
	conns := flag.Int("conns", 32, "parallel connections")
	pipeline := flag.Int("pipeline", 1, "commands per write batch")
	duration := flag.Duration("duration", 10*time.Second, "measurement duration")
	cmd := flag.String("cmd", "HGETALL", "command to run")
	key := flag.String("key", "bigh", "key argument")
	flag.Parse()

	req := buildReq(*cmd, *key)
	batch := bytes.Repeat(req, *pipeline)

	var totalOps int64
	deadline := time.Now().Add(*duration)
	errs := make(chan error, *conns)

	for i := 0; i < *conns; i++ {
		go func() {
			conn, err := net.Dial("tcp", *addr)
			if err != nil {
				errs <- err
				return
			}
			defer conn.Close()
			br := bufio.NewReaderSize(conn, 1<<16)

			// Learn the reply size with one parsed round-trip.
			if _, err := conn.Write(req); err != nil {
				errs <- err
				return
			}
			replySize, err := skipReply(br)
			if err != nil {
				errs <- fmt.Errorf("learning reply size: %w", err)
				return
			}

			buf := make([]byte, replySize**pipeline)
			for time.Now().Before(deadline) {
				if _, err := conn.Write(batch); err != nil {
					errs <- err
					return
				}
				if _, err := io.ReadFull(br, buf); err != nil {
					errs <- fmt.Errorf("draining %d bytes: %w", len(buf), err)
					return
				}
				atomic.AddInt64(&totalOps, int64(*pipeline))
			}
			errs <- nil
		}()
	}

	var failed int
	for i := 0; i < *conns; i++ {
		if err := <-errs; err != nil {
			failed++
			fmt.Fprintf(os.Stderr, "conn error: %v\n", err)
		}
	}

	ops := atomic.LoadInt64(&totalOps)
	fmt.Printf("ops=%d duration=%s ops/s=%.0f conns=%d pipeline=%d failed_conns=%d\n",
		ops, *duration, float64(ops)/duration.Seconds(), *conns, *pipeline, failed)
}
