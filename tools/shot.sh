#!/bin/bash
# Test screenshot run: tools/shot.sh <frame> [max seconds] -- runs ./build/larecomp with the caller's LARECOMP_* env,
# writes build/window.png at <frame> and exits; killed after max seconds (default 150). Log: build/run_shot.log
F=$1; T=${2:-150}
# one test run at a time: runs share build/window.png and build/run_shot.log
until mkdir build/.shot.lock 2>/dev/null; do sleep 1; done
trap 'rmdir build/.shot.lock 2>/dev/null' EXIT
LARECOMP_WINDOW_SHOT=$F LARECOMP_EXIT_AFTER_SHOT=1 ./build/larecomp extracted > build/run_shot.log 2>&1 &
P=$!
for i in $(seq 1 $T); do kill -0 $P 2>/dev/null || exit 0; sleep 1; done
kill $P 2>/dev/null; echo "timed out" >&2; exit 1
