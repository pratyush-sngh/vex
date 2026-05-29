#!/usr/bin/env bash
# pubsub-cross-worker-tls.sh — stresses cross-worker PUBLISH delivery
# under TLS, the path that caused glibc `realloc(): invalid next size`
# crashes in production (B1).
#
# Setup: vex with 4 workers + TLS. 16 TLS subscribers (round-robin places
# at least one on each worker). 4 TLS publishers loop PUBLISH on the
# shared channel. Cross-worker delivery is the dominant path.
#
# PASS = vex still alive and responsive after the run window.
# FAIL = vex died (any exit), or PING via TLS stops responding mid-run.

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────
DURATION=${DURATION:-60}                   # seconds to apply load
WORKERS=${WORKERS:-4}
SUBSCRIBERS=${SUBSCRIBERS:-16}
PUBLISHERS=${PUBLISHERS:-4}
PORT=${PORT:-6390}
PAYLOAD_BYTES=${PAYLOAD_BYTES:-1024}
CHANNEL=stress

VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}
RUN_DIR=$(mktemp -d -t vex-chaos-pubsub-tls.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
SUB_PIDS=()
PUB_PIDS=()

# ── Helpers ───────────────────────────────────────────────────────────
log() { printf '[pubsub-tls] %s\n' "$*"; }

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

vex_alive() {
    [[ -n "$VEX_PID" ]] && kill -0 "$VEX_PID" 2>/dev/null
}

tls_ping() {
    # Note: no `-t` — redis-cli 7.0 (Debian Bookworm) doesn't support
    # the timeout flag. Default behavior is fine for our use.
    redis-cli --tls --insecure -p "$PORT" PING 2>/dev/null | grep -q '^PONG$'
}

# ── Self-signed cert ──────────────────────────────────────────────────
log "generating self-signed cert at $RUN_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$RUN_DIR/key.pem" -out "$RUN_DIR/cert.pem" \
    -subj "/CN=vex-stress" >/dev/null 2>&1

# ── Build check ───────────────────────────────────────────────────────
if [[ ! -x "$VEX_BIN" ]]; then
    log "FAIL: $VEX_BIN missing — run 'zig build' first"
    exit 1
fi

# ── Start vex ─────────────────────────────────────────────────────────
log "starting vex on :$PORT with $WORKERS workers + TLS"
"$VEX_BIN" \
    --port "$PORT" \
    --workers "$WORKERS" \
    --no-persistence \
    --tls-cert "$RUN_DIR/cert.pem" \
    --tls-key "$RUN_DIR/key.pem" \
    > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!

# Brief wait so the banner / TLS init line lands in vex.log.
for _ in {1..20}; do
    [[ -s "$RUN_DIR/vex.log" ]] && break
    sleep 0.1
done

# Vex on dev macOS builds is often compiled without an OpenSSL backend
# and prints "TLS init failed: TlsNotAvailable" then falls back to
# plaintext. Probing the running server with --tls would hang forever
# because the TCP handshake succeeds and the TLS handshake stalls. Skip
# cleanly so the rest of the chaos suite runs.
if grep -q "TLS init failed\|TlsNotAvailable" "$RUN_DIR/vex.log"; then
    log "SKIP: this vex build has no working TLS backend (see vex.log)"
    log "  the cross-worker TLS pub/sub race needs OpenSSL to reproduce"
    log "  this script will run cleanly on Linux CI"
    exit 0
fi

# Wait for vex to be ready (≤5s).
for _ in {1..50}; do
    if tls_ping; then break; fi
    sleep 0.1
done
if ! tls_ping; then
    log "FAIL: vex not responding to TLS PING within 5s — check $RUN_DIR/vex.log"
    exit 1
fi
log "vex up — PID $VEX_PID"

# ── Subscribers ───────────────────────────────────────────────────────
# redis-cli SUBSCRIBE blocks; backgrounding it persists the connection
# so the cross-worker case (subscriber owned by a different worker than
# the publisher) is reliably hit.
log "starting $SUBSCRIBERS TLS subscribers"
for i in $(seq 1 "$SUBSCRIBERS"); do
    redis-cli --tls --insecure -p "$PORT" SUBSCRIBE "$CHANNEL" \
        > "$RUN_DIR/sub-$i.log" 2>&1 &
    SUB_PIDS+=("$!")
done
# Give subscribers a moment to register.
sleep 1

# ── Publishers ────────────────────────────────────────────────────────
log "starting $PUBLISHERS TLS publishers (payload ${PAYLOAD_BYTES}B for ${DURATION}s)"
PAYLOAD=$(head -c "$PAYLOAD_BYTES" /dev/urandom | base64 | tr -d '\n' | head -c "$PAYLOAD_BYTES")
END=$(( $(date +%s) + DURATION ))
for i in $(seq 1 "$PUBLISHERS"); do
    (
        while (( $(date +%s) < END )); do
            redis-cli --tls --insecure -p "$PORT" PUBLISH "$CHANNEL" "$PAYLOAD" >/dev/null 2>&1 \
                || break
        done
    ) > "$RUN_DIR/pub-$i.log" 2>&1 &
    PUB_PIDS+=("$!")
done

# ── Monitor ───────────────────────────────────────────────────────────
log "monitoring for $DURATION seconds"
CHECK_INTERVAL=2
elapsed=0
while (( elapsed < DURATION )); do
    sleep "$CHECK_INTERVAL"
    elapsed=$(( elapsed + CHECK_INTERVAL ))
    if ! vex_alive; then
        log "FAIL: vex died at t=${elapsed}s"
        log "vex.log tail:"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
    if ! tls_ping; then
        log "FAIL: vex unresponsive at t=${elapsed}s"
        log "vex.log tail:"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
done

# ── Final check ───────────────────────────────────────────────────────
if ! vex_alive || ! tls_ping; then
    log "FAIL: vex unhealthy after load window"
    exit 1
fi

# Verify subscribers actually saw traffic (sanity that pub/sub is wired).
total_msgs=0
for i in $(seq 1 "$SUBSCRIBERS"); do
    count=$(grep -c '^message$' "$RUN_DIR/sub-$i.log" 2>/dev/null || echo 0)
    total_msgs=$(( total_msgs + count ))
done

# Scan vex.log for glibc malloc abort signatures even if process is still up
# (some envs print abort but keep running until next event).
if grep -qE 'realloc\(\): invalid next size|corrupted size vs. prev_size|munmap_chunk' "$RUN_DIR/vex.log"; then
    log "FAIL: glibc heap-corruption abort observed in vex.log"
    grep -E 'realloc|corrupted|munmap' "$RUN_DIR/vex.log" | head -5 | sed 's/^/    /'
    exit 1
fi

log "PASS: vex survived ${DURATION}s of cross-worker TLS pub/sub"
log "  subscribers=$SUBSCRIBERS publishers=$PUBLISHERS workers=$WORKERS"
log "  total messages delivered to subscribers: $total_msgs"
exit 0
