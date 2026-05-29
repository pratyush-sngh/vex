#!/usr/bin/env bash
# self-publish-burst.sh — regression for finding #5: handlePublish's
# same-worker directFlush(sub_conn) can closeConn on the publisher's
# own connection if backpressure exceeds max_client_buffer. The
# enclosing handleRead then keeps touching the freed Connection.
#
# Trigger: one client subscribes AND publishes on the same channel at
# high rate so the worker is always self-delivering, while large
# payloads push write_buf toward the per-client limit.

set -uo pipefail

WORKERS=${WORKERS:-2}    # publisher and subscriber on the SAME worker is
                         # likely; with 2 workers round-robin keeps both
                         # busy without spreading too thin.
PORT=${PORT:-6399}
SELF_PUB_CLIENTS=${SELF_PUB_CLIENTS:-2}
PAYLOAD_BYTES=${PAYLOAD_BYTES:-32768}     # big enough to push toward
                                          # max_client_buffer (typically 1MB)
RATE_PER_CLIENT=${RATE_PER_CLIENT:-200}   # publishes per loop pass
DURATION=${DURATION:-60}
MAX_CLIENT_BUFFER=${MAX_CLIENT_BUFFER:-1048576}  # match a tight limit
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-self-pub.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()
log() { printf '[self-pub] %s\n' "$*"; }
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

log "starting vex (--max-client-buffer $MAX_CLIENT_BUFFER)"
"$VEX_BIN" --port "$PORT" --workers "$WORKERS" --no-persistence \
    --max-client-buffer "$MAX_CLIENT_BUFFER" > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!
for _ in {1..50}; do ping_ok && break; sleep 0.1; done
ping_ok || { log "FAIL: vex not responding"; tail -20 "$RUN_DIR/vex.log" | sed 's/^/    /'; exit 1; }

PAYLOAD=$(head -c "$PAYLOAD_BYTES" /dev/urandom | base64 | tr -d '\n' | head -c "$PAYLOAD_BYTES")

# Self-publishers: one connection both SUBSCRIBEs and PUBLISHes on the
# same channel. We can't do that with a single redis-cli invocation
# (SUBSCRIBE blocks), so we use a tight pair: a SUBSCRIBE process that
# stays connected (one conn) and a separate PUBLISH process. Both
# count as same-worker self-delivery as long as conn round-robin
# places them on the same worker — over many connections, a fraction
# will be co-located. To force co-location more aggressively, we run
# MANY pairs.
log "spawning $SELF_PUB_CLIENTS subscriber/publisher pairs"
for c in $(seq 1 "$SELF_PUB_CLIENTS"); do
    redis-cli -p "$PORT" SUBSCRIBE "selfchan$c" > "$RUN_DIR/sub-$c.log" 2>&1 &
    BG_PIDS+=("$!")
done
sleep 1

for c in $(seq 1 "$SELF_PUB_CLIENTS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            for _ in $(seq 1 "$RATE_PER_CLIENT"); do
                redis-cli -p "$PORT" PUBLISH "selfchan$c" "$PAYLOAD" >/dev/null 2>&1 || break 2
            done
        done
    ) > "$RUN_DIR/pub-$c.log" 2>&1 &
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

if grep -qE 'realloc\(\): invalid|corrupted size|panic:|segfault' "$RUN_DIR/vex.log"; then
    log "FAIL: abort in vex.log"
    grep -E 'realloc|corrupted|panic|segfault' "$RUN_DIR/vex.log" | head -10 | sed 's/^/    /'
    exit 1
fi

log "PASS: self-publish burst survived ${DURATION}s ($SELF_PUB_CLIENTS pairs, ${PAYLOAD_BYTES}B payloads)"
exit 0
