#!/usr/bin/env bash
# Redis vs Zigraph: bring up docker-compose.compare.yml and run a fixed benchmark matrix.
# Exits non-zero on first failure. Requires: docker, go, nc (netcat).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPOSE=(docker compose -f docker-compose.compare.yml --project-directory "$ROOT")

echo "[compare] compose up (clean volumes)..."
"${COMPOSE[@]}" down -v
"${COMPOSE[@]}" up --build -d

echo "[compare] wait for Redis..."
for _ in $(seq 1 120); do
  if docker exec redis-compare redis-cli ping 2>/dev/null | grep -q PONG; then
    break
  fi
  sleep 0.5
done

echo "[compare] wait for Zigraph TCP..."
for _ in $(seq 1 90); do
  if echo -en '*1\r\n$4\r\nPING\r\n' | nc -w 1 127.0.0.1 16380 2>/dev/null | head -c 1 | grep -q .; then
    break
  fi
  sleep 0.3
done
sleep 0.5

run() {
  echo ""
  echo "[compare] go run . $*"
  (cd "$ROOT/tools/compare-client" && GO111MODULE=on go run . "$@")
}

# Baseline, moderate parallel, heavier load
run -n 5000 -c 1 -warmup 500 -runs 3 -timeout 15s
run -n 5000 -c 8 -warmup 500 -runs 3 -timeout 25s
run -n 15000 -c 16 -warmup 1000 -runs 3 -timeout 35s
run -n 20000 -c 32 -warmup 1000 -runs 3 -timeout 50s

echo ""
echo "[compare] container status:"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'redis-compare|zigraph-compare' || true

echo ""
echo "[compare] all benchmark steps completed OK."
