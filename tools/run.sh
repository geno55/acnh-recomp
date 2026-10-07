#!/bin/bash
# Build, run, and summarize: last log lines + symbolized guest backtrace.
cd "$(dirname "$0")/.."
nice -n 15 taskpolicy -b make -j8 2>&1 | grep -E 'error' -A3 && exit 1
SECS=${SECS:-30}
${RUNPREFIX:-taskpolicy -b} ./build/larecomp extracted > build/run.log 2>&1 &
PID=$!
for i in $(seq 1 $SECS); do sleep 1; kill -0 $PID 2>/dev/null || break; done
kill -9 $PID 2>/dev/null && echo "(still running after ${SECS}s, killed)"
wait $PID 2>/dev/null
grep -v "^\[svc\]" build/run.log | grep -v "host backtrace" | grep -vE "^\s+[0-9]+ +(larecomp|libsystem)" | tail -${TAIL:-40}
ADDRS=$(grep -oE "f_[0-9a-f]{10}" build/run.log | head -${DEPTH:-14} | sed 's/f_//' | tr '\n' ' ')
[ -n "$ADDRS" ] && (cd tools && ./venv/bin/python sym.py $ADDRS)
