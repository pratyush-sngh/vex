#!/usr/bin/env bash
# set-large-then-small.sh — regression for the SET fast-path race
# (re-audit finding #1). Pre-fix, executeHotFast's SET held only the
# stripe RDLOCK, then mutated entry.value, entry.flags.is_inline,
# entry.inline_buf etc. independently. A concurrent reader could see
# flags.is_inline=false with value.ptr=inline_buf and value.len=
# OLD_LARGE_LEN, then memcpy thousands of bytes past inline_buf.
#
# Trigger: many SETs on the same key alternating between large
# (heap-allocated) and small (inline-fast-path) while parallel GETs
# read the same key.

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────
WORKERS=${WORKERS:-4}
PORT=${PORT:-6396}
HOT_KEYS=${HOT_KEYS:-50}             # how many keys to thrash
WRITER_LOOPS=${WRITER_LOOPS:-4}      # parallel writers alternating sizes
READER_LOOPS=${READER_LOOPS:-8}      # parallel GETs on the same keys
DURATION=${DURATION:-60}
LARGE_BYTES=${LARGE_BYTES:-1024}     # >> INLINE_BUF_SIZE (32)
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-set-race.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()
log() { printf '[set-race] %s\n' "$*"; }
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

[[ -x "$VEX_BIN" ]] || { log "FAIL: $VEX_BIN missing"; exit 1; }

log "starting vex on :$PORT, $WORKERS workers"
"$VEX_BIN" --port "$PORT" --workers "$WORKERS" --no-persistence > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!
for _ in {1..50}; do ping_ok && break; sleep 0.1; done
ping_ok || { log "FAIL: vex not responding"; exit 1; }

LARGE_VAL=$(head -c "$LARGE_BYTES" /dev/urandom | base64 | tr -d '\n' | head -c "$LARGE_BYTES")

# Seed the hot keys with LARGE values so the first SET-to-small hits
# the heap-to-inline transition.
log "seeding $HOT_KEYS keys with $LARGE_BYTES-byte values"
for i in $(seq 1 "$HOT_KEYS"); do
    redis-cli -p "$PORT" SET "hot:$i" "$LARGE_VAL" >/dev/null
done

# Writers: alternate small (fast path) and large (slow path) on hot keys.
# Batched through --pipe: one connection per ~2000 commands. A redis-cli
# process (and TCP connection) per command exhausts macOS ephemeral ports
# in seconds (EADDRNOTAVAIL), which fails the script's own health ping
# while vex is perfectly healthy.
log "spawning $WRITER_LOOPS writers (alternating small ↔ large, batched)"
for w in $(seq 1 "$WRITER_LOOPS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        i=0
        while (( $(date +%s) < end_ts )); do
            for j in $(seq 1 2000); do
                i=$(( i + 1 ))
                k=$(( (i % HOT_KEYS) + 1 ))
                if (( i % 2 == 0 )); then
                    printf 'SET hot:%d s%d\n' "$k" "$i"      # inline fast path
                else
                    printf 'SET hot:%d %s\n' "$k" "$LARGE_VAL"  # heap path
                fi
            done | redis-cli -p "$PORT" --pipe >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/write-$w.log" 2>&1 &
    BG_PIDS+=("$!")
done

# Readers: GET the same keys; with the race, eventually a torn read
# crashes via OOB memcpy from inline_buf. Same batching rationale.
log "spawning $READER_LOOPS GET loops on the same keys (batched)"
for r in $(seq 1 "$READER_LOOPS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            for j in $(seq 1 2000); do
                printf 'GET hot:%d\n' "$(( (RANDOM % HOT_KEYS) + 1 ))"
            done | redis-cli -p "$PORT" --pipe >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/read-$r.log" 2>&1 &
    BG_PIDS+=("$!")
done

log "monitoring for ${DURATION}s"
elapsed=0
while (( elapsed < DURATION )); do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    if ! kill -0 "$VEX_PID" 2>/dev/null; then
        log "FAIL: vex died at t=${elapsed}s"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
    if ! ping_ok; then log "FAIL: unresponsive at t=${elapsed}s"; exit 1; fi
done

for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null; done

if grep -qE 'realloc\(\): invalid|corrupted size|munmap_chunk|panic:|segfault' "$RUN_DIR/vex.log"; then
    log "FAIL: abort in vex.log"
    grep -E 'realloc|corrupted|munmap|panic|segfault' "$RUN_DIR/vex.log" | head -10 | sed 's/^/    /'
    exit 1
fi

log "PASS: SET large↔small thrash survived ${DURATION}s on $HOT_KEYS hot keys"
exit 0
