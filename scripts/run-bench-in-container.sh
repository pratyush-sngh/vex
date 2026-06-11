#!/bin/bash
# Bring up redis-server + vex inside the container, then run the go bench
# client against both. Two modes:
#   - Default: single run with args forwarded to compare-client.
#   - BENCH_MATRIX=1: sweep workers ∈ {1, 4} × c ∈ {1, 4, 8, 16, 32, 64},
#     restarting vex between worker configs. Prints a clear delimiter per
#     run so the output is easy to parse.
set -e

DATA_DIR=/data
mkdir -p "$DATA_DIR"

VEX_PID=""

stop_vex() {
    if [ -n "$VEX_PID" ]; then
        kill "$VEX_PID" 2>/dev/null || true
        # Wait briefly; if vex ignores SIGTERM (it has in practice during
        # high-load matrix runs) escalate to SIGKILL so the script can
        # continue to the next configuration.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! kill -0 "$VEX_PID" 2>/dev/null; then break; fi
            sleep 0.3
        done
        kill -9 "$VEX_PID" 2>/dev/null || true
        wait "$VEX_PID" 2>/dev/null || true
        VEX_PID=""
    fi
}

cleanup() {
    redis-cli -p 6379 SHUTDOWN NOSAVE 2>/dev/null || true
    stop_vex
}
trap cleanup EXIT INT TERM

start_vex() {
    local workers="$1"
    stop_vex
    /usr/local/bin/vex \
        --port 6380 \
        --data-dir "$DATA_DIR" \
        --no-persistence \
        --reactor \
        --workers "$workers" \
        --maxclients 50000 >/tmp/vex.log 2>&1 &
    VEX_PID=$!
    for _ in $(seq 1 60); do
        if redis-cli -p 6380 ping >/dev/null 2>&1; then return 0; fi
        sleep 0.2
    done
    echo "[bench] vex (workers=$workers) never responded:" >&2
    cat /tmp/vex.log >&2
    return 1
}

# Redis is only started in modes that benchmark against it. In BENCH_PROBES
# mode we drive load with redis-benchmark (the tool) directly at vex — no
# need for a competing redis-server on the same pod (which would pollute
# cache, CPU, and scheduler).
if [ "${BENCH_PROBES:-0}" != "1" ]; then
    echo "[bench] starting redis 8.0.3 on 127.0.0.1:6379..."
    redis-server --port 6379 \
                 --bind 127.0.0.1 \
                 --appendonly no \
                 --save "" \
                 --daemonize yes \
                 --logfile /tmp/redis.log \
                 --pidfile /tmp/redis.pid \
                 --maxclients 50000
    for _ in $(seq 1 60); do
        if redis-cli -p 6379 ping >/dev/null 2>&1; then break; fi
        sleep 0.2
    done
    if ! redis-cli -p 6379 ping >/dev/null 2>&1; then
        echo "[bench] redis never responded:" >&2
        cat /tmp/redis.log >&2
        exit 1
    fi
fi

if [ "${BENCH_PROBES:-0}" = "1" ]; then
    # Probe mode: enable vex's per-worker timing probes, drive load, collect
    # the breakdown. Sweeps workers x c so the wait-path probes (wait_enter /
    # wait_blocked / cqes_per_wake / cqe_* / flush_enter / tail_submit) can be
    # compared between the configs where the multi-worker dip appears (w=4
    # c=8..16) and where it doesn't (w=1 any c; w=4 c=32).
    for nworkers in ${PROBE_WORKERS_LIST:-1 4}; do
        start_vex "$nworkers"
        echo "[probes] sqpoll kthreads visible: $(ps -eL -o comm= 2>/dev/null | grep -c iou-sqp || true)"

        # Use redis-benchmark (in the image already) — more robust than the go
        # compare-client at higher c, and doesn't have the RESP-resync bug we
        # hit at c=8 with the go client.
        for c_clients in ${PROBE_C_LIST:-8 32}; do
            for op_set in ${PROBE_OPS:-SET GET HSET}; do
                echo ""
                echo "================================================================"
                echo "=== probes for $op_set (workers=$nworkers, c=$c_clients, n=20000)"
                echo "================================================================"
                echo "[probes] enable+reset:  ON=$(redis-cli -p 6380 DEBUG PROBES ON)   RESET=$(redis-cli -p 6380 DEBUG PROBES RESET)"
                echo "[probes] state header:  $(redis-cli -p 6380 DEBUG PROBES | head -1)"
                echo "[probes] running redis-benchmark for $op_set..."
                redis-benchmark -h 127.0.0.1 -p 6380 -c "$c_clients" -n 20000 -t "$op_set" -q 2>&1 | tail -3
                echo ""
                echo "--- DEBUG PROBES ---"
                redis-cli -p 6380 DEBUG PROBES 2>&1
                echo "--- end ---"
            done
        done

        # Corroboration for the wait_blocked probe: voluntary ctx switches per
        # vex thread (cumulative over this worker config's whole sweep).
        echo "[probes] per-thread ctx switches (cumulative, workers=$nworkers):"
        for t in /proc/$VEX_PID/task/*; do
            echo "  tid=$(basename "$t") comm=$(cat "$t/comm" 2>/dev/null) $(grep -E 'voluntary_ctxt|nonvoluntary_ctxt' "$t/status" 2>/dev/null | tr '\n' ' ')"
        done

        redis-cli -p 6380 DEBUG PROBES OFF >/dev/null 2>&1 || true
        stop_vex
    done
    exit 0
fi

if [ "${BENCH_PROFILE:-0}" = "1" ]; then
    # Profile mode: vex --workers 4 under c=8 load. Uses software-event
    # cpu-clock sampling (works without HW perf counters and without
    # perf_event_paranoid=0 — falls back gracefully in cloud kernels).
    echo "[profile] kernel.perf_event_paranoid = $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)"
    echo "[profile] kernel.kptr_restrict = $(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unknown)"

    # Try to relax paranoid setting from inside the privileged container.
    echo 0 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || \
        echo "[profile] could not write perf_event_paranoid (need privileged pod)"
    echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true

    start_vex 4
    VEX_PID_NUM=$VEX_PID

    echo "[profile] launching sustained c=8 load against vex for 90s..."
    (
        /usr/local/bin/compare-client \
            -redis 127.0.0.1:6379 \
            -vex 127.0.0.1:6380 \
            -n 500000 -c 8 -warmup 0 -runs 1 -timeout 180s >/tmp/bench.out 2>&1
    ) &
    BENCH_PID=$!

    sleep 3   # let load steady

    # Software event counters work without HW PMU access.
    echo ""
    echo "================================================================"
    echo "=== perf stat -e cpu-clock,context-switches,cpu-migrations (30s)"
    echo "================================================================"
    perf stat -p "$VEX_PID_NUM" \
        -e cpu-clock,task-clock,context-switches,cpu-migrations,page-faults \
        -- sleep 30 2>&1 || echo "[profile] perf stat failed"

    # Sample on cpu-clock (software event, always available).
    echo ""
    echo "================================================================"
    echo "=== perf record -e cpu-clock (30s, all threads of vex)"
    echo "================================================================"
    perf record -F 99 -p "$VEX_PID_NUM" -g -e cpu-clock --call-graph dwarf \
        -o /tmp/perf.data -- sleep 30 2>&1 | tail -20
    if [ -f /tmp/perf.data ] && [ -s /tmp/perf.data ]; then
        echo ""
        echo "--- top 30 functions by self-time ---"
        perf report -i /tmp/perf.data --stdio --no-children -n --sort overhead,symbol 2>/dev/null | \
            grep -E "^[[:space:]]*[0-9]+\.[0-9]+%" | head -30
        echo ""
        echo "--- top 20 with brief callstacks ---"
        perf report -i /tmp/perf.data --stdio -g graph,0.5,caller --percent-limit 1 2>/dev/null | head -200
    else
        echo "[profile] perf.data empty — kernel still blocking sampling"
    fi

    # Per-thread /proc state — useful even when perf is blocked.
    echo ""
    echo "================================================================"
    echo "=== /proc/$VEX_PID_NUM/status + /proc/$VEX_PID_NUM/task summary"
    echo "================================================================"
    grep -E "voluntary_ctxt|nonvoluntary_ctxt|Threads" /proc/$VEX_PID_NUM/status 2>&1
    echo ""
    echo "Per-thread voluntary/nonvoluntary context switches:"
    for tid in $(ls /proc/$VEX_PID_NUM/task 2>/dev/null); do
        if [ -r "/proc/$VEX_PID_NUM/task/$tid/status" ]; then
            v=$(grep voluntary_ctxt /proc/$VEX_PID_NUM/task/$tid/status | awk '{print $2}')
            nv=$(grep nonvoluntary_ctxt /proc/$VEX_PID_NUM/task/$tid/status | awk '{print $2}')
            name=$(grep Name /proc/$VEX_PID_NUM/task/$tid/status | awk '{print $2}')
            echo "  tid=$tid name=$name voluntary=$v nonvoluntary=$nv"
        fi
    done

    wait $BENCH_PID 2>/dev/null || true
    stop_vex
    exit 0
fi

if [ "${BENCH_MATRIX:-0}" = "1" ]; then
    # Sweep matrix. warmup/timeout scale with c.
    # WORKERS_LIST, C_LIST, and BENCH_N env vars allow re-running subsets
    # (larger BENCH_N tightens the ±5% noise seen with the 10k default).
    WORKERS_LIST="${WORKERS_LIST:-1 4}"
    C_LIST="${C_LIST:-1 4 8 16 32 64}"
    BENCH_N="${BENCH_N:-10000}"
    for workers in $WORKERS_LIST; do
        start_vex "$workers"
        for c in $C_LIST; do
            echo ""
            echo "=================================================="
            echo "=== MATRIX RUN workers=$workers c=$c n=$BENCH_N"
            echo "=================================================="
            /usr/local/bin/compare-client \
                -redis 127.0.0.1:6379 \
                -vex 127.0.0.1:6380 \
                -n "$BENCH_N" \
                -c "$c" \
                -warmup 1000 \
                -runs 3 \
                -timeout 60s
        done
        stop_vex
    done
    echo ""
    echo "[bench] matrix complete"
    exit 0
fi

# Single-run mode.
VEX_WORKERS="${VEX_WORKERS:-4}"
echo "[bench] starting vex on 127.0.0.1:6380 (--workers $VEX_WORKERS)..."
start_vex "$VEX_WORKERS"

echo "[bench] both servers up. running compare-client $*"
echo ""

/usr/local/bin/compare-client \
    -redis 127.0.0.1:6379 \
    -vex 127.0.0.1:6380 \
    "$@"
