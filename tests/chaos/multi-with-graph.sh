#!/usr/bin/env bash
# multi-with-graph.sh — regression for finding #3: handleExec runs
# queued commands under kv_mutex only, but does NOT take graph_rwlock.
# A worker executing a MULTI block containing GRAPH.ADDNODE/SETPROP
# races concurrent graph readers on another worker.
#
# Trigger: parallel clients running MULTI/EXEC blocks of graph writes
# while other clients fire graph reads.

set -uo pipefail

WORKERS=${WORKERS:-4}
PORT=${PORT:-6398}
N_INIT_NODES=${N_INIT_NODES:-3000}
EXEC_CLIENTS=${EXEC_CLIENTS:-3}
READ_CLIENTS=${READ_CLIENTS:-6}
CMDS_PER_EXEC=${CMDS_PER_EXEC:-10}
DURATION=${DURATION:-60}
VEX_BIN=${VEX_BIN:-./zig-out/bin/vex}

RUN_DIR=$(mktemp -d -t vex-chaos-multi.XXXX)
trap 'cleanup' EXIT INT TERM

VEX_PID=
BG_PIDS=()
log() { printf '[multi-graph] %s\n' "$*"; }
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

log "seeding $N_INIT_NODES nodes"
(for i in $(seq 1 "$N_INIT_NODES"); do printf 'GRAPH.ADDNODE n%d service\n' "$i"; done) | redis-cli -p "$PORT" --pipe >/dev/null

# EXEC clients: MULTI / GRAPH.ADDNODE × N / GRAPH.SETPROP × N / EXEC.
log "spawning $EXEC_CLIENTS MULTI/EXEC writers ($CMDS_PER_EXEC cmds each)"
for e in $(seq 1 "$EXEC_CLIENTS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        round=0
        while (( $(date +%s) < end_ts )); do
            round=$(( round + 1 ))
            {
                printf 'MULTI\n'
                for i in $(seq 1 "$CMDS_PER_EXEC"); do
                    new_id=$(( N_INIT_NODES + (e * 1000000) + (round * 1000) + i ))
                    printf 'GRAPH.ADDNODE m%d service\n' "$new_id"
                    # Touch a random existing node for SETPROP too.
                    rk=$(( (RANDOM % N_INIT_NODES) + 1 ))
                    printf 'GRAPH.SETPROP n%d r%d v%d\n' "$rk" "$round" "$i"
                done
                printf 'EXEC\n'
            } | redis-cli -p "$PORT" >/dev/null 2>&1 || break
        done
    ) > "$RUN_DIR/exec-$e.log" 2>&1 &
    BG_PIDS+=("$!")
done

log "spawning $READ_CLIENTS graph readers"
for r in $(seq 1 "$READ_CLIENTS"); do
    (
        end_ts=$(( $(date +%s) + DURATION ))
        i=0
        while (( $(date +%s) < end_ts )); do
            i=$(( i + 1 ))
            k=$(( (RANDOM % N_INIT_NODES) + 1 ))
            case $(( i % 3 )) in
                0) redis-cli -p "$PORT" GRAPH.GETNODE "n$k" >/dev/null 2>&1 || break ;;
                1) redis-cli -p "$PORT" GRAPH.NEIGHBORS "n$k" >/dev/null 2>&1 || break ;;
                2) redis-cli -p "$PORT" GRAPH.LIST_BY_TYPE service >/dev/null 2>&1 || break ;;
            esac
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

if grep -qE 'realloc\(\): invalid|corrupted size|panic:|segfault' "$RUN_DIR/vex.log"; then
    log "FAIL: abort in vex.log"
    grep -E 'realloc|corrupted|panic|segfault' "$RUN_DIR/vex.log" | head -10 | sed 's/^/    /'
    exit 1
fi

log "PASS: MULTI/EXEC graph writes survived ${DURATION}s alongside readers"
exit 0
