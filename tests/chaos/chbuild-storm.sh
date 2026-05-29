#!/usr/bin/env bash
# chbuild-storm.sh — regression for finding #2: GRAPH.CHBUILD was
# misclassified as a READ command (took rdlock) while rebuildCH
# destroys + reallocates self.ch and self.ch_query_engine. Concurrent
# WPATH readers walking the just-freed CH arrays trip glibc malloc.
#
# Trigger: periodic CHBUILD + parallel WPATH queries.
#
# SKIP if CHBUILD/WPATH aren't compiled in (older vex builds).

set -uo pipefail

WORKERS=${WORKERS:-4}
PORT=${PORT:-6397}
N_NODES=${N_NODES:-5000}
N_EDGES=${N_EDGES:-15000}
WPATH_LOOPS=${WPATH_LOOPS:-6}
CHBUILD_INTERVAL_SEC=${CHBUILD_INTERVAL_SEC:-3}
DURATION=${DURATION:-60}
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-chbuild.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()
log() { printf '[chbuild] %s\n' "$*"; }
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

log "starting vex"
"$VEX_BIN" --port "$PORT" --workers "$WORKERS" --no-persistence > "$RUN_DIR/vex.log" 2>&1 &
VEX_PID=$!
for _ in {1..50}; do ping_ok && break; sleep 0.1; done
ping_ok || { log "FAIL: vex not responding"; exit 1; }

# Probe for CHBUILD / WPATH support — older vex builds may lack them.
probe=$(redis-cli -p "$PORT" GRAPH.CHBUILD 2>&1)
if echo "$probe" | grep -qiE 'unknown.*command|ERR.*GRAPH\.CHBUILD'; then
    log "SKIP: this vex build doesn't have GRAPH.CHBUILD"
    exit 0
fi

# Seed graph.
log "seeding $N_NODES nodes / $N_EDGES edges"
(
    for i in $(seq 1 "$N_NODES"); do printf 'GRAPH.ADDNODE n%d node\n' "$i"; done
) | redis-cli -p "$PORT" --pipe >/dev/null
(
    for i in $(seq 1 "$N_EDGES"); do
        from=$(( (i % N_NODES) + 1 ))
        to=$(( ((i * 3 + 1) % N_NODES) + 1 ))
        printf 'GRAPH.ADDEDGE n%d n%d e %d.0\n' "$from" "$to" "$((i % 9 + 1))"
    done
) | redis-cli -p "$PORT" --pipe >/dev/null

# Initial CHBUILD to populate the structures.
redis-cli -p "$PORT" GRAPH.CHBUILD >/dev/null 2>&1 || true

log "spawning $WPATH_LOOPS WPATH readers"
for w in $(seq 1 "$WPATH_LOOPS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        while (( $(date +%s) < end_ts )); do
            from=$(( (RANDOM % N_NODES) + 1 ))
            to=$(( (RANDOM % N_NODES) + 1 ))
            redis-cli -p "$PORT" GRAPH.WPATH "n$from" "n$to" >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/wpath-$w.log" 2>&1 &
    BG_PIDS+=("$!")
done

# CHBUILD storm: every CHBUILD_INTERVAL_SEC trigger a rebuild.
log "issuing CHBUILD every ${CHBUILD_INTERVAL_SEC}s"
elapsed=0
chbuilds=0
while (( elapsed < DURATION )); do
    sleep "$CHBUILD_INTERVAL_SEC"
    elapsed=$(( elapsed + CHBUILD_INTERVAL_SEC ))
    if ! kill -0 "$VEX_PID" 2>/dev/null; then
        log "FAIL: vex died at t=${elapsed}s (after $chbuilds CHBUILDs)"
        tail -40 "$RUN_DIR/vex.log" | sed 's/^/    /'
        exit 1
    fi
    redis-cli -p "$PORT" GRAPH.CHBUILD >/dev/null 2>&1 || true
    chbuilds=$(( chbuilds + 1 ))
done

for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null; done

if ! ping_ok; then log "FAIL: unhealthy after window"; exit 1; fi
if grep -qE 'realloc\(\): invalid|corrupted size|panic:|segfault' "$RUN_DIR/vex.log"; then
    log "FAIL: abort in vex.log"
    grep -E 'realloc|corrupted|panic|segfault' "$RUN_DIR/vex.log" | head -10 | sed 's/^/    /'
    exit 1
fi

log "PASS: $chbuilds CHBUILDs + $WPATH_LOOPS parallel WPATHs survived ${DURATION}s"
exit 0
