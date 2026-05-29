#!/usr/bin/env bash
# pipelined-large-response.sh — regression for the io_uring SEND vs
# write_buf appendSlice race (re-audit finding #4). Pre-fix, the kernel
# was handed a pointer into the ArrayList backing conn.write_buf; the
# next pipelined command's appendSlice could realloc that buffer while
# the kernel was still DMA-reading, producing glibc `realloc(): invalid
# next size` once the freed chunk got reused.
#
# Trigger ingredients:
#   - Linux io_uring path active   ⇒ no TLS, run on Linux
#   - Large responses              ⇒ exceed initial write_buf capacity
#                                    (4096 B) on the first command, then
#                                    keep growing on follow-up commands
#   - Pipelined commands on one    ⇒ multiple appendSlice calls land
#     fd                             before SEND CQE returns
#   - Many concurrent connections  ⇒ multiplies realloc probability
#
# PASS = vex stays alive and responsive after the load window.
# FAIL = vex dies (exit 133/134), or glibc abort string in vex.log,
#        or PING stops responding mid-run.

set -uo pipefail

# ── Linux gate ────────────────────────────────────────────────────────
# The bug is io_uring-specific. On macOS the kqueue path doesn't have
# the same race; skipping there keeps developer-laptop runs from
# producing misleading PASSes.
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[pipe-large] SKIP: requires Linux (io_uring path); host is $(uname -s)"
    exit 0
fi

# ── Config ────────────────────────────────────────────────────────────
WORKERS=${WORKERS:-4}
PORT=${PORT:-6394}
CLIENTS=${CLIENTS:-32}          # parallel connections, each pipelining
PIPELINE_DEPTH=${PIPELINE_DEPTH:-32}
N_KEYS=${N_KEYS:-200}           # hot-key set per client; each value ≥8KB
VALUE_BYTES=${VALUE_BYTES:-8192}  # > initial write_buf capacity (4096B)
DURATION=${DURATION:-60}
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-pipe-large.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()

log() { printf '[pipe-large] %s\n' "$*"; }
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

log "starting vex on :$PORT, $WORKERS workers, no TLS (forces io_uring)"
"$VEX_BIN" \
    --port "$PORT" \
    --workers "$WORKERS" \
    --no-persistence \
    > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!
for _ in {1..50}; do ping_ok && break; sleep 0.1; done
ping_ok || { log "FAIL: vex not responding"; tail -20 "$RUN_DIR/vex.log" | sed 's/^/    /'; exit 1; }
log "vex up — PID $VEX_PID"

# ── Seed hot keys with large values ───────────────────────────────────
# A single GET response for a VALUE_BYTES-byte value plus RESP framing
# is well over 4096 B, so each appendSlice into the initial write_buf
# capacity forces a realloc on the next pipelined append.
log "seeding $N_KEYS hot keys, value=${VALUE_BYTES}B"
PAYLOAD=$(head -c "$VALUE_BYTES" /dev/urandom | base64 | tr -d '\n' | head -c "$VALUE_BYTES")
(
    for i in $(seq 1 "$N_KEYS"); do
        printf 'SET k%d "%s"\n' "$i" "$PAYLOAD"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

# ── Launch concurrent pipelined readers ───────────────────────────────
log "launching $CLIENTS clients × pipeline-depth $PIPELINE_DEPTH GETs"
for c in $(seq 1 "$CLIENTS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            # Each pass: build a script of $PIPELINE_DEPTH GETs and send
            # them in one shot. redis-cli --pipe blasts them; on the
            # vex side each GET appends a >8KB response to the same
            # connection's write_buf, repeatedly forcing realloc while
            # earlier SENDs are still in flight under io_uring.
            for i in $(seq 1 "$PIPELINE_DEPTH"); do
                k=$(( (RANDOM % N_KEYS) + 1 ))
                printf 'GET k%d\n' "$k"
            done | redis-cli -p "$PORT" --pipe >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/client-$c.log" 2>&1 &
    BG_PIDS+=("$!")
done

# ── Monitor ───────────────────────────────────────────────────────────
log "running for ${DURATION}s"
elapsed=0
while (( elapsed < DURATION )); do
    sleep 2
    elapsed=$(( elapsed + 2 ))
    if ! kill -0 "$VEX_PID" 2>/dev/null; then
        log "FAIL: vex died at t=${elapsed}s — repro confirmed"
        log "vex.log tail:"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
    if ! ping_ok; then
        log "FAIL: vex unresponsive at t=${elapsed}s"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
done

log "draining client loops"
for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null; done

# ── Final checks ──────────────────────────────────────────────────────
if ! ping_ok; then
    log "FAIL: vex unhealthy after load window"
    exit 1
fi

if grep -qE 'realloc\(\): invalid|corrupted size|munmap_chunk|panic:|thread.*panic|segfault' "$RUN_DIR/vex.log"; then
    log "FAIL: glibc/zig abort observed in vex.log"
    grep -E 'realloc|corrupted|munmap|panic|segfault' "$RUN_DIR/vex.log" | head -10 | sed 's/^/    /'
    exit 1
fi

# Sanity: a sample GET still returns the expected payload length.
got_len=$(redis-cli -p "$PORT" STRLEN k1 2>/dev/null)
if [[ "$got_len" != "$VALUE_BYTES" ]]; then
    log "FAIL: k1 STRLEN=$got_len, expected $VALUE_BYTES (data corruption)"
    exit 1
fi

log "PASS: vex survived ${DURATION}s of pipelined large-response load"
log "  workers=$WORKERS clients=$CLIENTS pipeline_depth=$PIPELINE_DEPTH value_bytes=$VALUE_BYTES"
exit 0
