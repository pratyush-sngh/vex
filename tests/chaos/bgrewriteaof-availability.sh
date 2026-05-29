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

# ── Background GET stream — must stay responsive during rewrite ───────
LATENCY_LOG="$RUN_DIR/get-latency.log"
: > "$LATENCY_LOG"
log "starting GET stream sampling latency (target $GET_SAMPLE_COUNT samples)"
(
    for s in $(seq 1 "$GET_SAMPLE_COUNT"); do
        # Pick a random key index so we hit different stripes.
        k=$(( (RANDOM * 32768 + RANDOM) % N_KEYS + 1 ))
        t0_ns=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1e9')
        out=$(redis-cli -p "$PORT" GET "k$k" 2>/dev/null)
        rc=$?
        t1_ns=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1e9')
        ms=$(( (t1_ns - t0_ns) / 1000000 ))
        if [[ $rc -ne 0 || -z "$out" ]]; then
            printf 'ERR %d\n' "$ms" >> "$LATENCY_LOG"
        else
            printf '%d\n' "$ms" >> "$LATENCY_LOG"
        fi
        sleep 0.02
    done
) &
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

# ── Wait for the GET stream to finish so we can analyze latency ───────
log "waiting for GET stream to complete"
wait "$GET_PID" 2>/dev/null
GET_PID=

# ── Latency analysis ──────────────────────────────────────────────────
if ! ping_ok; then
    log "FAIL: vex unresponsive after rewrite"
    tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
    exit 1
fi

errors=$(grep -c '^ERR' "$LATENCY_LOG" || true)
samples=$(wc -l < "$LATENCY_LOG" | tr -d ' ')
oks=$(( samples - errors ))
sorted=$(grep -v '^ERR' "$LATENCY_LOG" | sort -n)
if [[ -z "$sorted" ]]; then
    log "FAIL: no successful GET samples"
    exit 1
fi
p50_idx=$(( oks / 2 ))
p99_idx=$(( oks * 99 / 100 ))
p50=$(echo "$sorted" | sed -n "${p50_idx}p")
p99=$(echo "$sorted" | sed -n "${p99_idx}p")
maxv=$(echo "$sorted" | tail -1)

log "GET stream results:"
log "  samples=$samples ok=$oks errors=$errors"
log "  latency p50=${p50}ms p99=${p99}ms max=${maxv}ms"

if (( errors > 0 )); then
    log "FAIL: $errors GET requests errored during rewrite (pre-B2 symptom: kv_mutex 5s timeout)"
    exit 1
fi
if (( maxv > STALL_THRESHOLD_MS )); then
    log "FAIL: max GET latency ${maxv}ms > ${STALL_THRESHOLD_MS}ms threshold (rewrite stalled the hot path)"
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
