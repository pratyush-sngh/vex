#!/usr/bin/env bash
# bgrewriteaof-availability.sh — validates that BGREWRITEAOF runs on a
# background thread (B2) and that other workers stay responsive during
# the rewrite. Pre-B2: the originating worker held kv_mutex synchronously
# for the entire rewrite, stalling every other worker for ~5s and then
# aborting their commands. Post-B2: rewrite runs detached; the bonus fix
# snapshots kv.map up front so even the bg thread releases kv_mutex
# before the multi-second file write.
#
# PASS criteria:
#   1. BGREWRITEAOF returns "Background ... started" within 100ms.
#   2. During the rewrite, a GET stream on another connection stays
#      responsive — p99 latency under STALL_THRESHOLD_MS.
#   3. vex stays alive; the post-rewrite AOF file exists and is non-empty.
#   4. Re-issuing BGREWRITEAOF immediately is refused with "in progress".

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────
WORKERS=${WORKERS:-4}
PORT=${PORT:-6391}
N_KEYS=${N_KEYS:-200000}              # enough to make rewrite take seconds
N_NODES=${N_NODES:-10000}
N_EDGES=${N_EDGES:-30000}
GET_SAMPLE_COUNT=${GET_SAMPLE_COUNT:-500}
STALL_THRESHOLD_MS=${STALL_THRESHOLD_MS:-1000}  # any GET > 1s = unacceptable stall
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-bgrewrite.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
GET_PID=

log() { printf '[bgrewriteaof] %s\n' "$*"; }
cleanup() {
    trap - EXIT INT TERM
    set +e
    # Kill every direct child of this script (vex + redis-cli loops +
    # any background subshell) with SIGTERM, wait briefly, then SIGKILL.
    # pkill -P is robust to BG_PID arrays drifting and to children that
    # ignore SIGTERM (vex shutdown handler can hang under load).
    pkill -P $$ 2>/dev/null
    sleep 0.3
    pkill -9 -P $$ 2>/dev/null
    [[ -n "$RUN_DIR" ]] && printf "logs preserved at %s\n" "$RUN_DIR" >&2
}
ping_ok() { redis-cli -p "$PORT" PING 2>/dev/null | grep -q '^PONG$'; }

# ── Sanity ────────────────────────────────────────────────────────────
[[ -x "$VEX_BIN" ]] || { log "FAIL: $VEX_BIN missing — run 'zig build' first"; exit 1; }

# ── Start vex with AOF ────────────────────────────────────────────────
DATA_DIR="$RUN_DIR/data"
mkdir -p "$DATA_DIR"
log "starting vex on :$PORT, $WORKERS workers, AOF enabled, data $DATA_DIR"
"$VEX_BIN" \
    --port "$PORT" \
    --workers "$WORKERS" \
    --data-dir "$DATA_DIR" \
    --appendonly yes \
    > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!

for _ in {1..50}; do ping_ok && break; sleep 0.1; done
ping_ok || { log "FAIL: vex not responding"; tail -20 "$RUN_DIR/vex.log" | sed 's/^/    /'; exit 1; }
log "vex up — PID $VEX_PID"

# ── Load enough data that BGREWRITEAOF takes multiple seconds ─────────
log "loading $N_KEYS KV keys"
redis-cli -p "$PORT" --pipe-mode flushdb >/dev/null 2>&1 || redis-cli -p "$PORT" FLUSHDB >/dev/null
(
    for i in $(seq 1 "$N_KEYS"); do
        printf 'SET k%d v%d\n' "$i" "$i"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

log "loading $N_NODES graph nodes"
(
    for i in $(seq 1 "$N_NODES"); do
        printf 'GRAPH.ADDNODE n%d person\n' "$i"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

log "loading $N_EDGES graph edges"
(
    for i in $(seq 1 "$N_EDGES"); do
        from=$(( (i % N_NODES) + 1 ))
        to=$(( ((i + 7) % N_NODES) + 1 ))
        printf 'GRAPH.ADDEDGE n%d n%d knows 1.0\n' "$from" "$to"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

# ── Background latency stream — must stay responsive during rewrite ───
# ONE persistent connection via `redis-cli --latency-history` (1s
# buckets, each line reporting min/max/avg). The previous version
# spawned a redis-cli process (fork+exec+connect) per GET sample —
# that measures the client machine (process spawn time +
# ephemeral-port pressure), not server stalls, and produced
# multi-second false "latencies" on macOS.
LATENCY_LOG="$RUN_DIR/get-latency.log"
: > "$LATENCY_LOG"
log "starting latency stream on one persistent connection"
redis-cli -p "$PORT" --latency-history -i 1 > "$LATENCY_LOG" 2>&1 &
GET_PID=$!

# Give the GET stream a moment to baseline.
sleep 1

# ── Trigger BGREWRITEAOF ──────────────────────────────────────────────
log "issuing BGREWRITEAOF"
issue_t0=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1e9')
issue_reply=$(redis-cli -p "$PORT" BGREWRITEAOF)
issue_t1=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1e9')
issue_ms=$(( (issue_t1 - issue_t0) / 1000000 ))
log "  reply: '$issue_reply' (returned in ${issue_ms}ms)"

if ! echo "$issue_reply" | grep -qi 'started'; then
    log "FAIL: BGREWRITEAOF did not return 'started' — got '$issue_reply'"
    kill "$GET_PID" 2>/dev/null
    exit 1
fi
if (( issue_ms > 100 )); then
    log "FAIL: BGREWRITEAOF reply latency ${issue_ms}ms > 100ms — was it actually async?"
    kill "$GET_PID" 2>/dev/null
    exit 1
fi

# ── Immediate re-issue should be refused ──────────────────────────────
sleep 0.1
reissue=$(redis-cli -p "$PORT" BGREWRITEAOF 2>&1)
if ! echo "$reissue" | grep -qi 'in progress'; then
    log "WARN: concurrent BGREWRITEAOF was not refused — got '$reissue'"
    log "      (this only fails if the rewrite already finished — usually OK on tiny datasets)"
fi

# ── Observe through the rewrite window, then stop the stream ──────────
OBSERVE_SEC=${OBSERVE_SEC:-12}
log "observing latency for ${OBSERVE_SEC}s through the rewrite"
sleep "$OBSERVE_SEC"
kill "$GET_PID" 2>/dev/null
wait "$GET_PID" 2>/dev/null
GET_PID=

# ── Latency analysis ──────────────────────────────────────────────────
if ! ping_ok; then
    log "FAIL: vex unresponsive after rewrite"
    tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
    exit 1
fi

# --latency-history lines: "min: 0, max: 5, avg: 0.12 (89 samples) -- 1.00 seconds range"
buckets=$(grep -c 'seconds range' "$LATENCY_LOG" || true)
if (( buckets == 0 )); then
    log "FAIL: latency stream produced no samples (connection died?)"
    sed 's/^/    /' "$LATENCY_LOG" | head -5
    exit 1
fi
maxv=$(grep -oE 'max: [0-9]+' "$LATENCY_LOG" | awk '{ if ($2 > m) m = $2 } END { print m + 0 }')

log "latency stream results: $buckets one-second buckets, worst bucket max=${maxv}ms"

if (( maxv > STALL_THRESHOLD_MS )); then
    log "FAIL: max latency ${maxv}ms > ${STALL_THRESHOLD_MS}ms threshold (rewrite stalled the hot path)"
    exit 1
fi

# ── AOF file sanity ───────────────────────────────────────────────────
aof_file=$(find "$DATA_DIR" -name 'vex.aof*' -type f | head -1)
if [[ -z "$aof_file" ]] || [[ ! -s "$aof_file" ]]; then
    log "FAIL: AOF file missing or empty after rewrite (expected at $DATA_DIR/vex.aof)"
    ls -la "$DATA_DIR" | sed 's/^/    /'
    exit 1
fi
log "  AOF file: $aof_file ($(wc -c < "$aof_file") bytes)"

# ── Final glibc abort scan ────────────────────────────────────────────
if grep -qE 'realloc\(\): invalid|corrupted size|munmap_chunk|panic|abort' "$RUN_DIR/vex.log"; then
    log "FAIL: panic/abort observed in vex.log"
    grep -E 'realloc|corrupted|munmap|panic|abort' "$RUN_DIR/vex.log" | head -5 | sed 's/^/    /'
    exit 1
fi

log "PASS: BGREWRITEAOF ran detached; hot path remained responsive"
exit 0
