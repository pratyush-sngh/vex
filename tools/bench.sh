#!/bin/bash
# Vex vs Redis benchmark suite
# Runs redis-benchmark N times per test and reports median rps.
# Usage: ./tools/bench.sh [runs] (default: 15)

set -e

RUNS=${1:-15}
TCP_N=500000
UDS_N=500000
PIPELINE=50
CONCURRENCY=16
REDIS_PORT=16379
VEX_PORT=16380

# Tests to run. Names must match redis-benchmark -t output exactly.
TESTS=(
    "SET"
    "GET"
    "INCR"
    "LPUSH"
    "RPUSH"
    "LPOP"
    "RPOP"
    "SADD"
    "HSET"
    "ZADD"
    "MSET"
    "LRANGE_100"
)

echo "=== Vex vs Redis Benchmark (median of $RUNS runs) ==="
echo "P=$PIPELINE, c=$CONCURRENCY, n=$TCP_N per run, ${#TESTS[@]} commands"
echo ""

median() {
    sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

# For TCP: run from host via port mapping
run_tcp() {
    local port=$1
    local test_name=$2
    local runs=$3
    local test_flag=$(echo "$test_name" | tr '[:upper:]' '[:lower:]')

    local vals=""
    for i in $(seq 1 $runs); do
        redis-cli -h 127.0.0.1 -p $port FLUSHALL > /dev/null 2>&1
        local rps=$(redis-benchmark -h 127.0.0.1 -p $port -c $CONCURRENCY -n $TCP_N -P $PIPELINE -q -t "$test_flag" --csv 2>/dev/null \
            | grep "\"$test_name" | head -1 | cut -d',' -f2 | tr -d '"')
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

# For UDS: run inside Docker container
run_uds() {
    local sock=$1
    local test_name=$2
    local runs=$3
    local test_flag=$(echo "$test_name" | tr '[:upper:]' '[:lower:]')

    docker exec redis-compare bash -c "
        for i in \$(seq 1 $runs); do
            redis-cli -s $sock FLUSHALL > /dev/null 2>&1
            redis-benchmark -s $sock -c $CONCURRENCY -n $UDS_N -P $PIPELINE -q -t '$test_flag' --csv 2>/dev/null \
                | grep '\"$test_name' | head -1 | cut -d',' -f2 | tr -d '\"'
        done" 2>/dev/null | grep -v '^$' | median
}

printf "%-16s %12s %12s %12s %12s\n" "Command" "Redis TCP" "Vex TCP" "Redis UDS" "Vex UDS"
printf "%-16s %12s %12s %12s %12s\n" "---------------" "---------" "-------" "---------" "-------"

for test_name in "${TESTS[@]}"; do
    redis_tcp=$(run_tcp 16379 "$test_name" "$RUNS")
    vex_tcp=$(run_tcp 16380 "$test_name" "$RUNS")
    redis_uds=$(run_uds /socks/redis.sock "$test_name" "$RUNS")
    vex_uds=$(run_uds /socks/vex.sock "$test_name" "$RUNS")

    printf "%-16s %12s %12s %12s %12s\n" "$test_name" "$redis_tcp" "$vex_tcp" "$redis_uds" "$vex_uds"
done

echo ""
echo "=== Done ==="
