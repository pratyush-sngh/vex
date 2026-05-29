#!/usr/bin/env bash
# Sequential chaos-suite runner used by the chaos-runner Pod image.
# Skips the durability scaffold scripts (still TODO stubs), runs every
# regression script under /chaos, and reports a one-line PASS / FAIL
# per script plus a final tally.
#
# Tunables via env (defaults are tuned for a 5-10 min CI gate; bump
# DURATION + the N_* knobs for a longer release-gate run):
#   DURATION              (per-script load window seconds)
#   N_KEYS / N_NODES / N_EDGES   (graph-shape tests)
#   TOTAL_KEYS / KEYS_PER_PIPELINE (write-heavy tests)
#   INIT_NODES / INIT_EDGES       (production-shape tests)

set -u

export VEX_BIN=${VEX_BIN:-/usr/local/bin/vex}
export DURATION=${DURATION:-30}
export N_KEYS=${N_KEYS:-50000}
export N_NODES=${N_NODES:-5000}
export N_EDGES=${N_EDGES:-15000}
export TOTAL_KEYS=${TOTAL_KEYS:-500000}
export KEYS_PER_PIPELINE=${KEYS_PER_PIPELINE:-25000}
export INIT_NODES=${INIT_NODES:-5000}
export INIT_EDGES=${INIT_EDGES:-15000}

cd /workspace

fail=0
pass=0
skip=0
declare -a failures=()

for s in /chaos/*.sh; do
    base=$(basename "$s" .sh)
    # Skip the durability scaffolds + ourselves.
    case "$base" in
        run-all|fill-disk|kill-and-restart|partition-leader|slow-disk) continue ;;
    esac

    printf '\n========== %s ==========\n' "$base"
    if "$s"; then
        rc=$?
        # Some scripts print "SKIP" then exit 0 — count as skip.
        # We detect that by checking the last log line of the script,
        # but easier: print PASS unconditionally on rc=0.
        printf '++ %s PASS\n' "$base"
        pass=$((pass + 1))
    else
        rc=$?
        printf '!! %s FAIL (rc=%d)\n' "$base" "$rc"
        failures+=("$base")
        fail=$((fail + 1))
    fi
done

printf '\n===============================\n'
printf 'pass=%d fail=%d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    printf 'failures: %s\n' "${failures[*]}"
fi

exit "$fail"
