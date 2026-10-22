#!/bin/bash
# End-to-end open latency, measured the way Finder opens files (via LaunchServices `open`):
# from just before `open` runs until the first frame with the document has been painted.
#
#   scripts/bench.sh [file.md] [runs]
#   MODE=source scripts/bench.sh ...   measures opening in source (editor) mode instead of preview
#
# cold = app not running (process launch + WebKit boot + render)
# warm = app already running in the background (the normal case after first use)
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="$(cd "$(dirname "${1:-samples/showcase.md}")" && pwd)/$(basename "${1:-samples/showcase.md}")"
RUNS="${2:-5}"
APP="$PWD/build/Flickdown.app"
LOG="$(mktemp -t flick-bench)"
# Pin the view mode for this run without touching the saved preference.
if [ "${MODE:-preview}" = source ]; then SOURCE=YES; else SOURCE=NO; fi

now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
# The short pause lets LaunchServices notice the exit (otherwise `open` can fail with -600).
quit_app() { pkill -x Flickdown 2>/dev/null || true; while pgrep -x Flickdown >/dev/null; do sleep 0.05; done; sleep 0.3; }

# Waits for the Nth "painted" line in the log and prints its epoch timestamp.
wait_painted() {
  local n=$1
  for _ in $(seq 1 200); do
    local t
    t=$(grep " painted " "$LOG" | sed -n "${n}p" | awk '{print $2}' || true)
    if [ -n "$t" ]; then echo "$t"; return; fi
    sleep 0.025
  done
  echo "timeout waiting for paint #$n; log so far:" >&2; cut -c1-120 "$LOG" >&2; exit 1
}

ms() { perl -e "printf '%.0f', ($2 - $1) * 1000"; }

echo "file: $FILE ($(wc -c < "$FILE" | tr -d ' ') bytes), mode: ${MODE:-preview}"

cold=()
for i in $(seq 1 "$RUNS"); do
  quit_app
  : > "$LOG"
  t0=$(now)
  open --env FLICK_BENCH=1 --env FLICK_BENCH_LOG="$LOG" --env FLICK_QUIT=1 -a "$APP" "$FILE" --args -sourceMode "$SOURCE"
  t1=$(wait_painted 1)
  cold+=("$(ms "$t0" "$t1")")
done

quit_app
: > "$LOG"
open --env FLICK_BENCH=1 --env FLICK_BENCH_LOG="$LOG" --env FLICK_CLOSE=1 -a "$APP" "$FILE" --args -sourceMode "$SOURCE"
wait_painted 1 >/dev/null
sleep 1.5 # let the spare page prewarm
warm=()
for i in $(seq 1 "$RUNS"); do
  t0=$(now)
  open -a "$APP" "$FILE"
  t1=$(wait_painted $((i + 1)))
  warm+=("$(ms "$t0" "$t1")")
  sleep 1.2
done
quit_app

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
echo "cold open → first paint: ${cold[*]} ms   (median $(median "${cold[@]}") ms)"
echo "warm open → first paint: ${warm[*]} ms   (median $(median "${warm[@]}") ms)"
rm -f "$LOG"
