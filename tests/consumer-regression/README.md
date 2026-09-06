# jarvis

External Go-based regression tests for vex. Lives outside the main Zig
tree because the failures it watches for are easier to assert from a
real RESP client than from inside a Zig unit test, and they're
specific to consumer-shaped graph queries (where the original bugs
were found in production).

## Tools

### `cmd/vex-bleed-test`

Regression for the **GRAPH.TRAVERSE EDGETYPE handler-bleed** bug fixed
in commit `8fa6678`. Builds a tiny class/method graph, asserts that a
depth-2 traversal from a method does NOT fan through the shared class
node into sibling methods — i.e. that `EDGETYPE` filtering isn't
silently dropped after the first hop.

```bash
# Run against a vex instance:
go run ./cmd/vex-bleed-test -addr=127.0.0.1:6380
```

Exit code 0 on success, non-zero with diff output on failure.

## Adding more

Drop new probes under `cmd/<name>/main.go`. Keep them small,
self-contained, and documented in this README — these are
operator-side smoke tests, not a full test framework.
