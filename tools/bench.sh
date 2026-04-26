#!/bin/bash
# Vex vs Redis benchmark suite
# Runs redis-benchmark N times per test and reports median rps.
# Usage: ./tools/bench.sh [runs] (default: 15)

set -e

RUNS=${1:-15}
CMDS="set,get,incr,lpush,rpush,lpop,rpop,sadd,hset"
TCP_N=500000
UDS_N=500000
PIPELINE=50
CONCURRENCY=16

echo "=== Vex vs Redis Benchmark (median of $RUNS runs) ==="
echo "P=$PIPELINE, c=$CONCURRENCY, n=$TCP_N per run"
echo ""

median() {
    sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

run_bench() {
    local label=$1
    local args=$2
    local cmd=$3
    local runs=$4

    local vals=""
    for i in $(seq 1 $runs); do
        local rps=$(redis-benchmark $args -c $CONCURRENCY -n $TCP_N -P $PIPELINE -q -t $cmd --csv 2>/dev/null \
            | grep "\"$cmd\"" | head -1 | cut -d',' -f2 | tr -d '"')
        if [ -n "$rps" ] && [ "$rps" != "0.0" ]; then
            vals="$vals $rps"
        fi
    done

    if [ -z "$vals" ]; then
        echo "ERROR"
        return
    fi

    echo "$vals" | tr ' ' '\n' | grep -v '^$' | median
}

echo "Running TCP benchmarks..."
echo ""
printf "%-8s %12s %12s %12s %12s\n" "Command" "Redis TCP" "Vex TCP" "Redis UDS" "Vex UDS"
printf "%-8s %12s %12s %12s %12s\n" "-------" "---------" "-------" "---------" "-------"

for cmd in $(echo $CMDS | tr ',' ' '); do
    CMD_UPPER=$(echo $cmd | tr '[:lower:]' '[:upper:]')

    redis_tcp=$(run_bench "Redis TCP" "-h 127.0.0.1 -p 16379" "$CMD_UPPER" "$RUNS")
    vex_tcp=$(run_bench "Vex TCP" "-h 127.0.0.1 -p 16380" "$CMD_UPPER" "$RUNS")

    redis_uds=$(docker exec redis-compare bash -c "
        for i in \$(seq 1 $RUNS); do
            redis-benchmark -s /socks/redis.sock -c $CONCURRENCY -n $UDS_N -P $PIPELINE -q -t $cmd --csv 2>/dev/null \
                | grep '\"$CMD_UPPER\"' | head -1 | cut -d',' -f2 | tr -d '\"'
        done" 2>/dev/null | grep -v '^$' | median)

    vex_uds=$(docker exec redis-compare bash -c "
        for i in \$(seq 1 $RUNS); do
            redis-benchmark -s /socks/vex.sock -c $CONCURRENCY -n $UDS_N -P $PIPELINE -q -t $cmd --csv 2>/dev/null \
                | grep '\"$CMD_UPPER\"' | head -1 | cut -d',' -f2 | tr -d '\"'
        done" 2>/dev/null | grep -v '^$' | median)

    printf "%-8s %12s %12s %12s %12s\n" "$CMD_UPPER" "$redis_tcp" "$vex_tcp" "$redis_uds" "$vex_uds"
done

echo ""
echo "=== Done ==="
