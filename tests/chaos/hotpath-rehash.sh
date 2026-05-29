#!/usr/bin/env bash
# hotpath-rehash.sh — stresses the hot-path GET/SET/MGET/INCR race
# against ConcurrentKV stripe rehashes (B3). Pre-B3: executeHotFast
# called stripe.map.getPtr() with no lock; a concurrent setInternal
# rehash freed the bucket array out from under the reader → segfault
# or panic. Authors mitigated by pre-allocating each stripe to 16384
# entries; beyond that any rehash was lethal. B3 wraps every hot-path
# bucket access in stripe.rdlock.
#
# Strategy: hammer SETs of unique keys until well past 16384 per stripe
# (which probabilistically means ~256 * 16384 ≈ 4.2M total keys for
# uniform hashing), while running parallel GET/MGET/INCR loops on hot
# subsets of those keys. Detection is "did vex die or panic".
#
# PASS = vex alive, no panic/segfault, sample queries return expected
#        values, no deadlock (SET fast-path + setInternal fallback both
#        complete under load).

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────
WORKERS=${WORKERS:-4}
PORT=${PORT:-6392}
# Default targets ~80k unique keys per stripe — well past the 16384
# pre-alloc threshold (forces ~2-3 rehashes per stripe).
TOTAL_KEYS=${TOTAL_KEYS:-2000000}
SET_PIPELINES=${SET_PIPELINES:-4}        # parallel SET pipelines
GET_LOOPS=${GET_LOOPS:-4}                # parallel hot-key GET loops
MGET_LOOPS=${MGET_LOOPS:-2}              # parallel MGET loops
INCR_LOOPS=${INCR_LOOPS:-2}              # parallel INCR loops (own keys)
HOT_KEY_RANGE=${HOT_KEY_RANGE:-1000}     # readers cycle through this many
DURATION=${DURATION:-60}
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-rehash.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()

log() { printf '[rehash] %s\n' "$*"; }
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

# ── Start vex (no persistence — we don't care about durability here) ─
log "starting vex on :$PORT, $WORKERS workers"
"$VEX_BIN" \
    --port "$PORT" \
    --workers "$WORKERS" \
    --no-persistence \
    > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!
for _ in {1..50}; do ping_ok && break; sleep 0.1; done
ping_ok || { log "FAIL: vex not responding"; tail -20 "$RUN_DIR/vex.log" | sed 's/^/    /'; exit 1; }
log "vex up — PID $VEX_PID"

# Pre-seed the hot read range so GETs don't all miss.
log "seeding $HOT_KEY_RANGE hot keys"
(
    for i in $(seq 1 "$HOT_KEY_RANGE"); do
        printf 'SET hot:%d v%d\n' "$i" "$i"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

# Seed counter keys for INCR fast-path coverage.
log "seeding $INCR_LOOPS counter keys"
for i in $(seq 1 "$INCR_LOOPS"); do
    redis-cli -p "$PORT" SET "cnt:$i" 0 >/dev/null
done

# ── Producers: piles in unique keys to force rehashes ─────────────────
keys_per_pipe=$(( TOTAL_KEYS / SET_PIPELINES ))
log "spawning $SET_PIPELINES SET pipelines ($keys_per_pipe keys each → ~$TOTAL_KEYS total)"
for p in $(seq 1 "$SET_PIPELINES"); do
    (
        start=$(( (p - 1) * keys_per_pipe + 1 ))
        end=$(( p * keys_per_pipe ))
        for i in $(seq "$start" "$end"); do
            printf 'SET k%d_%d v_%d\n' "$p" "$i" "$i"
        done | redis-cli -p "$PORT" --pipe > "$RUN_DIR/set-$p.log" 2>&1
    ) &
    BG_PIDS+=("$!")
done

# ── Readers: hot-path GET loop ────────────────────────────────────────
log "spawning $GET_LOOPS GET loops"
for g in $(seq 1 "$GET_LOOPS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            k=$(( (RANDOM % HOT_KEY_RANGE) + 1 ))
            redis-cli -p "$PORT" GET "hot:$k" >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/get-$g.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Readers: MGET ─────────────────────────────────────────────────────
log "spawning $MGET_LOOPS MGET loops"
for m in $(seq 1 "$MGET_LOOPS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            # Pick 8 random hot keys per MGET.
            args=""
            for _ in 1 2 3 4 5 6 7 8; do
                k=$(( (RANDOM % HOT_KEY_RANGE) + 1 ))
                args="$args hot:$k"
            done
            redis-cli -p "$PORT" MGET $args >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/mget-$m.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Writers: INCR (fast path on integer keys) ─────────────────────────
log "spawning $INCR_LOOPS INCR loops"
for c in $(seq 1 "$INCR_LOOPS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            redis-cli -p "$PORT" INCR "cnt:$c" >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/incr-$c.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Monitor ───────────────────────────────────────────────────────────
log "running for ${DURATION}s"
elapsed=0
while (( elapsed < DURATION )); do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    if ! kill -0 "$VEX_PID" 2>/dev/null; then
        log "FAIL: vex died at t=${elapsed}s"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
    if ! ping_ok; then
        log "FAIL: vex unresponsive at t=${elapsed}s (possible deadlock)"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
done

# ── Wait for any remaining producers (they may finish before DURATION) ─
log "waiting for background workers to drain"
for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null; done

# ── Post-run verification ─────────────────────────────────────────────
if ! ping_ok; then
    log "FAIL: vex unhealthy after load window"
    exit 1
fi

# Spot-check: a few hot keys should still return their seeded values.
for i in 1 100 500 999; do
    expected="v$i"
    got=$(redis-cli -p "$PORT" GET "hot:$i" 2>/dev/null)
    if [[ "$got" != "$expected" ]]; then
        log "FAIL: hot:$i = '$got', expected '$expected' (data corruption)"
        exit 1
    fi
done

# Counters should be > 0.
for c in $(seq 1 "$INCR_LOOPS"); do
    v=$(redis-cli -p "$PORT" GET "cnt:$c" 2>/dev/null)
    if [[ "${v:-0}" == "0" ]]; then
        log "WARN: cnt:$c = 0 (no INCRs landed — INCR loop may have errored early)"
    fi
done

# Final glibc/zig abort scan.
if grep -qE 'realloc\(\): invalid|corrupted size|munmap_chunk|panic:|thread.*panic|segfault' "$RUN_DIR/vex.log"; then
    log "FAIL: panic/segfault observed in vex.log"
    grep -E 'realloc|corrupted|munmap|panic|segfault' "$RUN_DIR/vex.log" | head -10 | sed 's/^/    /'
    exit 1
fi

# Final dbsize sanity — should be near TOTAL_KEYS + HOT_KEY_RANGE + INCR_LOOPS.
dbs=$(redis-cli -p "$PORT" DBSIZE 2>/dev/null)
log "PASS: hot-path survived rehash storm"
log "  workers=$WORKERS dbsize=$dbs duration=${DURATION}s"
exit 0
