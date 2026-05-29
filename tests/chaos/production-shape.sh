#!/usr/bin/env bash
# production-shape.sh — long-running stress that mirrors the
# ReviewGraph platform's workload shape: multi-worker vex, no TLS,
# parallel graph reads (GETNODE / NEIGHBORS / LIST_BY_TYPE) + a steady
# trickle of graph writes (ADDNODE / ADDEDGE / SETPROP) + pub/sub
# broadcast. This is the test that would have caught io_uring race
# (#4) and any other path-specific bug exercised by that mix.
#
# It is intentionally NOT a tight regression for a single bug — it's
# the canary that runs before tagging a release. Failures here mean
# "production will crash"; you triage from logs.
#
# PASS = vex alive + responsive + no abort signature in vex.log
# FAIL = any of those break inside DURATION seconds

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────
WORKERS=${WORKERS:-4}
PORT=${PORT:-6395}
DURATION=${DURATION:-300}                # 5 min default; pre-release runs 600+

# Initial graph size (loaded once before the load window).
INIT_NODES=${INIT_NODES:-20000}
INIT_EDGES=${INIT_EDGES:-60000}

# Per-second pressure during load window.
READ_CLIENTS=${READ_CLIENTS:-8}          # parallel readers
WRITE_CLIENTS=${WRITE_CLIENTS:-2}        # parallel writers (graph mutations)
PUBSUB_CHANNELS=${PUBSUB_CHANNELS:-4}
SUBSCRIBERS_PER_CHANNEL=${SUBSCRIBERS_PER_CHANNEL:-4}
PUBLISHERS=${PUBLISHERS:-2}
PUBLISH_PAYLOAD_BYTES=${PUBLISH_PAYLOAD_BYTES:-2048}

VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-prod-shape.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()

log() { printf '[prod-shape] %s\n' "$*"; }
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

# ── Boot ──────────────────────────────────────────────────────────────
log "starting vex on :$PORT, $WORKERS workers, no TLS"
"$VEX_BIN" \
    --port "$PORT" \
    --workers "$WORKERS" \
    --no-persistence \
    > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!
for _ in {1..50}; do ping_ok && break; sleep 0.1; done
ping_ok || { log "FAIL: vex not responding"; tail -20 "$RUN_DIR/vex.log" | sed 's/^/    /'; exit 1; }
log "vex up — PID $VEX_PID"

# ── Seed the graph ────────────────────────────────────────────────────
log "seeding $INIT_NODES nodes across 5 types"
(
    types=(service database cache queue gateway)
    for i in $(seq 1 "$INIT_NODES"); do
        t=${types[$(( i % 5 ))]}
        printf 'GRAPH.ADDNODE n%d %s\n' "$i" "$t"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

log "seeding $INIT_EDGES edges"
(
    for i in $(seq 1 "$INIT_EDGES"); do
        from=$(( (i % INIT_NODES) + 1 ))
        to=$(( ((i * 7 + 3) % INIT_NODES) + 1 ))
        weight=$(( (i % 10) + 1 ))
        printf 'GRAPH.ADDEDGE n%d n%d calls %d.0\n' "$from" "$to" "$weight"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

# ── Reader loops — three different shapes ─────────────────────────────
log "spawning $READ_CLIENTS readers (mix of GETNODE / NEIGHBORS / LIST_BY_TYPE)"
for c in $(seq 1 "$READ_CLIENTS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        i=0
        while (( $(date +%s) < end_ts )); do
            i=$(( i + 1 ))
            shape=$(( i % 3 ))
            case "$shape" in
                0)  # GETNODE
                    k=$(( (RANDOM % INIT_NODES) + 1 ))
                    redis-cli -p "$PORT" GRAPH.GETNODE "n$k" >/dev/null 2>&1 || break
                    ;;
                1)  # NEIGHBORS (returns potentially many edges → large response)
                    k=$(( (RANDOM % INIT_NODES) + 1 ))
                    redis-cli -p "$PORT" GRAPH.NEIGHBORS "n$k" >/dev/null 2>&1 || break
                    ;;
                2)  # LIST_BY_TYPE (largest responses)
                    types=(service database cache queue gateway)
                    t=${types[$(( i % 5 ))]}
                    redis-cli -p "$PORT" GRAPH.LIST_BY_TYPE "$t" >/dev/null 2>&1 || break
                    ;;
            esac
        done
    ) > "$RUN_DIR/read-$c.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Writer loops — graph mutations during reads ───────────────────────
log "spawning $WRITE_CLIENTS writers (ADDNODE / ADDEDGE / SETPROP)"
for c in $(seq 1 "$WRITE_CLIENTS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        i=0
        while (( $(date +%s) < end_ts )); do
            i=$(( i + 1 ))
            shape=$(( i % 3 ))
            # New ids beyond INIT_NODES so we keep adding without
            # colliding with the static graph.
            new_id=$(( INIT_NODES + (c * 1000000) + i ))
            case "$shape" in
                0)
                    redis-cli -p "$PORT" GRAPH.ADDNODE "n$new_id" service >/dev/null 2>&1 || break
                    ;;
                1)
                    other=$(( (RANDOM % INIT_NODES) + 1 ))
                    redis-cli -p "$PORT" GRAPH.ADDEDGE "n$other" "n$new_id" knows 1.0 >/dev/null 2>&1 || true
                    ;;
                2)
                    k=$(( (RANDOM % INIT_NODES) + 1 ))
                    redis-cli -p "$PORT" GRAPH.SETPROP "n$k" tag "v$i" >/dev/null 2>&1 || break
                    ;;
            esac
        done
    ) > "$RUN_DIR/write-$c.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Pub/sub: subscribers per channel, then publishers ────────────────
log "spawning $PUBSUB_CHANNELS channels × $SUBSCRIBERS_PER_CHANNEL subscribers"
for ch in $(seq 1 "$PUBSUB_CHANNELS"); do
    for s in $(seq 1 "$SUBSCRIBERS_PER_CHANNEL"); do
        redis-cli -p "$PORT" SUBSCRIBE "chan$ch" > "$RUN_DIR/sub-c${ch}-s${s}.log" 2>&1 &
        BG_PIDS+=("$!")
    done
done
sleep 1  # let subscribers register

log "spawning $PUBLISHERS publishers (payload ${PUBLISH_PAYLOAD_BYTES}B)"
PAYLOAD=$(head -c "$PUBLISH_PAYLOAD_BYTES" /dev/urandom | base64 | tr -d '\n' | head -c "$PUBLISH_PAYLOAD_BYTES")
for p in $(seq 1 "$PUBLISHERS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            for ch in $(seq 1 "$PUBSUB_CHANNELS"); do
                redis-cli -p "$PORT" PUBLISH "chan$ch" "$PAYLOAD" >/dev/null 2>&1 || break 2
            done
        done
    ) > "$RUN_DIR/pub-$p.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Monitor ───────────────────────────────────────────────────────────
log "load window: ${DURATION}s — checking vex every 5s"
elapsed=0
while (( elapsed < DURATION )); do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    if ! kill -0 "$VEX_PID" 2>/dev/null; then
        log "FAIL: vex died at t=${elapsed}s"
        tail -60 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
    if ! ping_ok; then
        log "FAIL: vex unresponsive at t=${elapsed}s"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
    # Light progress beat every 30s so long runs don't look hung.
    if (( elapsed % 30 == 0 )); then
        dbs=$(redis-cli -p "$PORT" GRAPH.STATS 2>/dev/null | head -3 | tr '\n' ' ')
        log "  t=${elapsed}s: $dbs"
    fi
done

log "draining background workers"
for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null; done

# ── Final verdict ─────────────────────────────────────────────────────
if ! ping_ok; then
    log "FAIL: vex unhealthy after load window"
    exit 1
fi

if grep -qE 'realloc\(\): invalid|corrupted size|munmap_chunk|panic:|thread.*panic|segfault' "$RUN_DIR/vex.log"; then
    log "FAIL: abort/panic in vex.log"
    grep -E 'realloc|corrupted|munmap|panic|segfault' "$RUN_DIR/vex.log" | head -10 | sed 's/^/    /'
    exit 1
fi

final_stats=$(redis-cli -p "$PORT" GRAPH.STATS 2>/dev/null | tr '\n' ' ')
log "PASS: production-shape load survived ${DURATION}s"
log "  final stats: $final_stats"
exit 0
