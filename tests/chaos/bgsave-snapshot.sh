#!/usr/bin/env bash
# bgsave-snapshot.sh — validates the kv_mutex snapshot path used by
# BGSAVE (bonus fix). Pre-fix: BGSAVE iterated kv.map on a background
# thread without holding kv_mutex, racing with KV writers (cmdSet on
# the legacy KVStore). Post-fix: BGSAVE briefly locks kv_mutex,
# deep-copies all live entries into a snapshot slice, releases, and
# does file I/O against the snapshot.
#
# Strategy: many concurrent SETs + repeated BGSAVE. The snapshot must
# always succeed; the resulting RDB file must be readable on restart.
#
# PASS criteria:
#   1. BGSAVE completes successfully under write load (no panic).
#   2. Restart loads the snapshot back; a sample of expected keys
#      survives.
#   3. vex doesn't deadlock; ping responsive throughout.

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────
WORKERS=${WORKERS:-4}
PORT=${PORT:-6393}
WRITE_PIPELINES=${WRITE_PIPELINES:-4}
KEYS_PER_PIPELINE=${KEYS_PER_PIPELINE:-50000}
BGSAVE_INTERVAL_SEC=${BGSAVE_INTERVAL_SEC:-5}
DURATION=${DURATION:-30}
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-bgsave.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()

log() { printf '[bgsave] %s\n' "$*"; }
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
start_vex() {
    # $2: boot window in seconds (default 5). The restart-from-snapshot
    # call passes a much larger window: restoring a few hundred thousand
    # keys is legitimately slow in Debug builds, where the DebugAllocator
    # captures a stack trace per allocation (minutes for a ~6MB zdb).
    local boot_window=${2:-5}
    "$VEX_BIN" \
        --port "$PORT" \
        --workers "$WORKERS" \
        --data-dir "$DATA_DIR" \
        --appendonly yes \
        > "$1" 2>&1 &
    VEX_PID=$!
    local i
    for (( i = 0; i < boot_window * 10; i++ )); do ping_ok && return 0; sleep 0.1; done
    log "FAIL: vex not responding (log $1)"
    tail -20 "$1" | sed 's/^/    /'
    return 1
}

# ── Sanity ────────────────────────────────────────────────────────────
[[ -x "$VEX_BIN" ]] || { log "FAIL: $VEX_BIN missing — run 'zig build' first"; exit 1; }

DATA_DIR="$RUN_DIR/data"
mkdir -p "$DATA_DIR"

# ── Boot vex ──────────────────────────────────────────────────────────
log "starting vex on :$PORT, $WORKERS workers, AOF + snapshot enabled"
start_vex "$RUN_DIR/vex.log" || exit 1
log "vex up — PID $VEX_PID"

# ── Concurrent SET pipelines ──────────────────────────────────────────
log "spawning $WRITE_PIPELINES SET pipelines ($KEYS_PER_PIPELINE keys each)"
for p in $(seq 1 "$WRITE_PIPELINES"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        cycle=0
        while (( $(date +%s) < end_ts )); do
            cycle=$(( cycle + 1 ))
            for i in $(seq 1 "$KEYS_PER_PIPELINE"); do
                printf 'SET p%d_c%d_k%d v%d\n' "$p" "$cycle" "$i" "$i"
            done | redis-cli -p "$PORT" --pipe >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/set-$p.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Periodic BGSAVE during the write storm ────────────────────────────
log "issuing BGSAVE every ${BGSAVE_INTERVAL_SEC}s during write load"
bgsave_count=0
bgsave_failures=0
elapsed=0
while (( elapsed < DURATION )); do
    sleep "$BGSAVE_INTERVAL_SEC"
    elapsed=$(( elapsed + BGSAVE_INTERVAL_SEC ))

    if ! kill -0 "$VEX_PID" 2>/dev/null; then
        log "FAIL: vex died at t=${elapsed}s during BGSAVE storm"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi

    reply=$(redis-cli -p "$PORT" BGSAVE 2>&1)
    bgsave_count=$(( bgsave_count + 1 ))
    if echo "$reply" | grep -qi 'started'; then
        log "  bgsave #$bgsave_count: ok"
    elif echo "$reply" | grep -qi 'in progress'; then
        log "  bgsave #$bgsave_count: previous still running (expected under load)"
    else
        log "  bgsave #$bgsave_count: UNEXPECTED reply: '$reply'"
        bgsave_failures=$(( bgsave_failures + 1 ))
    fi
done

# Drain SET pipelines.
log "draining writer pipelines"
for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null; done

# Final BGSAVE so we have a snapshot reflecting the final state.
log "final BGSAVE + waiting for it to finish"
redis-cli -p "$PORT" BGSAVE >/dev/null
# LASTSAVE: when it advances past the pre-call timestamp, the BGSAVE landed.
pre=$(redis-cli -p "$PORT" LASTSAVE 2>/dev/null)
for _ in {1..120}; do
    sleep 0.5
    post=$(redis-cli -p "$PORT" LASTSAVE 2>/dev/null)
    if [[ "$post" != "$pre" ]]; then break; fi
done

# ── Verify vex is still healthy ───────────────────────────────────────
if ! ping_ok; then
    log "FAIL: vex unresponsive after BGSAVE storm"
    exit 1
fi
if (( bgsave_failures > 0 )); then
    log "FAIL: $bgsave_failures BGSAVE calls returned unexpected replies"
    exit 1
fi

# Capture dbsize + a few sample keys before restart.
pre_dbsize=$(redis-cli -p "$PORT" DBSIZE | tr -d ' \r')
sample_key=$(redis-cli -p "$PORT" SCAN 0 COUNT 1 | tail -1)

# ── Restart from snapshot ─────────────────────────────────────────────
log "stopping vex"
kill -TERM "$VEX_PID" 2>/dev/null
# Wait up to 2s for graceful shutdown so AOF flushes, then SIGKILL.
# vex's SIGTERM handler only sets a shutdown flag the main loop must
# poll, and under load that poll can be delayed indefinitely.
for _ in $(seq 1 20); do kill -0 "$VEX_PID" 2>/dev/null || break; sleep 0.1; done
kill -9 "$VEX_PID" 2>/dev/null
wait "$VEX_PID" 2>/dev/null
VEX_PID=

log "restarting vex from snapshot"
start_vex "$RUN_DIR/vex-restart.log" 300 || { log "FAIL: vex did not come back up after restart"; exit 1; }

post_dbsize=$(redis-cli -p "$PORT" DBSIZE | tr -d ' \r')
log "  pre-restart dbsize: $pre_dbsize"
log "  post-restart dbsize: $post_dbsize"

# Acceptable: post should be >= 90% of pre (some keys may have been
# written between final BGSAVE and snapshot completion).
threshold=$(( pre_dbsize * 9 / 10 ))
if (( post_dbsize < threshold )); then
    log "FAIL: post-restart dbsize $post_dbsize < 90% of pre-restart $pre_dbsize"
    exit 1
fi

if [[ -n "$sample_key" ]]; then
    sample_val=$(redis-cli -p "$PORT" GET "$sample_key" 2>/dev/null)
    if [[ -z "$sample_val" ]]; then
        log "FAIL: sample key '$sample_key' missing after restart"
        exit 1
    fi
fi

# Final abort scan across both vex logs.
for lf in "$RUN_DIR/vex.log" "$RUN_DIR/vex-restart.log"; do
    if grep -qE 'realloc\(\): invalid|corrupted size|munmap_chunk|panic:|thread.*panic|segfault' "$lf"; then
        log "FAIL: panic/segfault observed in $lf"
        grep -E 'realloc|corrupted|munmap|panic|segfault' "$lf" | head -10 | sed 's/^/    /'
        exit 1
    fi
done

log "PASS: BGSAVE survived $bgsave_count attempts under write load; snapshot loaded back successfully"
exit 0
