// vex-bleed-test — verifies that GRAPH.TRAVERSE with EDGETYPE does not
// bleed through a shared class node to sibling handler methods.
//
// Usage:
//
//	go run ./cmd/vex-bleed-test                          # localhost:6380
//	VEX_ADDR=staging-vex:6380 go run ./cmd/vex-bleed-test
//	go run ./cmd/vex-bleed-test --keep-fixtures          # leave nodes for inspection
//
// Graph fixture:
//
//	class:UsersController  --HAS_METHOD-->  m1:login_post
//	class:UsersController  --HAS_METHOD-->  m2:logout_post
//	class:UsersController  --HAS_METHOD-->  m3:list_users
//	api1:/auth/login       --HANDLES-->     m1:login_post
//	api2:/auth/logout      --HANDLES-->     m2:logout_post
//
// Assertions:
//  1. NEIGHBORS api1 OUT  — includes m1            (direct edge exists)
//  2. NEIGHBORS api1 OUT  — excludes m2, m3        (no direct edge)
//  3. TRAVERSE  api1 DEPTH 2 EDGETYPE HANDLES — returns only m1, not m2/m3
//     (must NOT fan out through class node to sibling methods)
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

func main() {
	os.Exit(run())
}

func run() int {
	keep := flag.Bool("keep-fixtures", false, "leave test nodes in Vex for inspection")
	flag.Parse()

	addr := os.Getenv("VEX_ADDR")
	if addr == "" {
		addr = "localhost:6380"
	}

	prefix := fmt.Sprintf("test_bleed_%d_", time.Now().UnixMilli())

	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: cannot connect to %s: %v\n", addr, err)
		return 1
	}
	defer conn.Close()

	c := &client{conn: conn, prefix: prefix}

	// Cleanup deferred unconditionally (unless --keep-fixtures)
	if !*keep {
		defer c.cleanup()
	}

	// ── Build fixture graph ──
	nodes := []struct{ key, typ string }{
		{"class:UsersController", "class"},
		{"m1:login_post", "method"},
		{"m2:logout_post", "method"},
		{"m3:list_users", "method"},
		{"api1:/auth/login", "api_endpoint"},
		{"api2:/auth/logout", "api_endpoint"},
	}
	for _, n := range nodes {
		if err := c.addNode(n.key, n.typ); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL: ADDNODE %s: %v\n", n.key, err)
			return 1
		}
	}

	edges := []struct{ from, to, typ string }{
		{"class:UsersController", "m1:login_post", "HAS_METHOD"},
		{"class:UsersController", "m2:logout_post", "HAS_METHOD"},
		{"class:UsersController", "m3:list_users", "HAS_METHOD"},
		{"api1:/auth/login", "m1:login_post", "HANDLES"},
		{"api2:/auth/logout", "m2:logout_post", "HANDLES"},
	}
	for _, e := range edges {
		if err := c.addEdge(e.from, e.to, e.typ); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL: ADDEDGE %s->%s: %v\n", e.from, e.to, err)
			return 1
		}
	}

	fmt.Printf("Fixtures created (%s) on %s\n\n", prefix, addr)

	passed, failed := 0, 0

	// ── Test 1: NEIGHBORS includes bound handler ──
	{
		neighbors, err := c.neighbors("api1:/auth/login", "OUT")
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL: NEIGHBORS api1: %v\n", err)
			return 1
		}
		if contains(neighbors, c.pfx("m1:login_post")) {
			fmt.Println("PASS  1/3  NEIGHBORS includes bound handler (m1)")
			passed++
		} else {
			fmt.Printf("FAIL  1/3  NEIGHBORS missing m1, got: %v\n", neighbors)
			failed++
		}
	}

	// ── Test 2: NEIGHBORS excludes sibling handlers ──
	{
		neighbors, err := c.neighbors("api1:/auth/login", "OUT")
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL: NEIGHBORS api1: %v\n", err)
			return 1
		}
		m2 := contains(neighbors, c.pfx("m2:logout_post"))
		m3 := contains(neighbors, c.pfx("m3:list_users"))
		if !m2 && !m3 {
			fmt.Println("PASS  2/3  NEIGHBORS excludes sibling handlers (m2, m3)")
			passed++
		} else {
			fmt.Printf("FAIL  2/3  NEIGHBORS leaked siblings: m2=%v m3=%v, got: %v\n", m2, m3, neighbors)
			failed++
		}
	}

	// ── Test 3: TRAVERSE depth=2 with EDGETYPE HANDLES ──
	{
		traversed, err := c.traverse("api1:/auth/login", 2, "HANDLES")
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL: TRAVERSE api1: %v\n", err)
			return 1
		}
		hasM1 := contains(traversed, c.pfx("m1:login_post"))
		hasM2 := contains(traversed, c.pfx("m2:logout_post"))
		hasM3 := contains(traversed, c.pfx("m3:list_users"))
		hasClass := contains(traversed, c.pfx("class:UsersController"))

		if hasM1 && !hasM2 && !hasM3 && !hasClass {
			fmt.Println("PASS  3/3  TRAVERSE EDGETYPE HANDLES returns only bound handler")
			passed++
		} else {
			fmt.Printf("FAIL  3/3  TRAVERSE leaked: m1=%v m2=%v m3=%v class=%v, got: %v\n",
				hasM1, hasM2, hasM3, hasClass, traversed)
			failed++
		}
	}

	fmt.Printf("\n%d passed, %d failed\n", passed, failed)
	if failed > 0 {
		return 1
	}
	return 0
}

// ── RESP client ──

type client struct {
	conn   net.Conn
	prefix string
	nodes  []string // track for cleanup
}

func (c *client) pfx(key string) string {
	return c.prefix + key
}

func (c *client) send(args ...string) (string, error) {
	c.conn.SetDeadline(time.Now().Add(5 * time.Second))
	cmd := fmt.Sprintf("*%d\r\n", len(args))
	for _, a := range args {
		cmd += fmt.Sprintf("$%d\r\n%s\r\n", len(a), a)
	}
	_, err := c.conn.Write([]byte(cmd))
	if err != nil {
		return "", err
	}
	buf := make([]byte, 65536)
	n, err := c.conn.Read(buf)
	if err != nil {
		return "", err
	}
	return string(buf[:n]), nil
}

func (c *client) addNode(key, typ string) error {
	pk := c.pfx(key)
	resp, err := c.send("GRAPH.ADDNODE", pk, typ)
	if err != nil {
		return err
	}
	if strings.HasPrefix(resp, "-") {
		return fmt.Errorf("%s", strings.TrimSpace(resp))
	}
	c.nodes = append(c.nodes, pk)
	return nil
}

func (c *client) addEdge(from, to, typ string) error {
	resp, err := c.send("GRAPH.ADDEDGE", c.pfx(from), c.pfx(to), typ)
	if err != nil {
		return err
	}
	if strings.HasPrefix(resp, "-") {
		return fmt.Errorf("%s", strings.TrimSpace(resp))
	}
	return nil
}

func (c *client) neighbors(key, dir string) ([]string, error) {
	resp, err := c.send("GRAPH.NEIGHBORS", c.pfx(key), dir)
	if err != nil {
		return nil, err
	}
	return parseArray(resp), nil
}

func (c *client) traverse(key string, depth int, edgeType string) ([]string, error) {
	resp, err := c.send("GRAPH.TRAVERSE", c.pfx(key), "DEPTH", fmt.Sprint(depth), "EDGETYPE", edgeType)
	if err != nil {
		return nil, err
	}
	return parseArray(resp), nil
}

func (c *client) cleanup() {
	for _, key := range c.nodes {
		c.send("GRAPH.DELNODE", key)
	}
}

func parseArray(resp string) []string {
	lines := strings.Split(resp, "\r\n")
	var result []string
	for _, line := range lines {
		if len(line) == 0 || line[0] == '*' || line[0] == '$' || line[0] == ':' {
			continue
		}
		result = append(result, line)
	}
	return result
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
