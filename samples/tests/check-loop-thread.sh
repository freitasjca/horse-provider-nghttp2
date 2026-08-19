#!/usr/bin/env bash
# ============================================================================
#  check-loop-thread.sh — is the epoll engine's throughput ceiling one
#  saturated loop thread?
#
#  The S3 sweep showed 27 939 req/s at c=1000 and 27 742 at c=5000 — 0.7%
#  apart across a five-fold increase in connections. That is a hard ceiling,
#  and with a single loop thread the obvious suspect is that thread pegging.
#
#  "Obvious suspect" is exactly the kind of reasoning that produced the 22.3x
#  and "free on fast routes" claims, both of which measurement later corrected.
#  So this measures it rather than assuming it.
#
#  Reads /proc/<pid>/task/<tid>/stat directly instead of driving `top -H`:
#  the load window is a few seconds, per-thread deltas over a known interval
#  are exact, and the output is a table rather than something to eyeball.
#
#  ── Reading the result ──
#
#    ONE thread near 100%, the rest idle ...... ceiling confirmed. SO_REUSEPORT
#                                               + N loop threads is the fix.
#    SEVERAL threads busy, none saturated ..... NOT the loop thread. Do not
#                                               build SO_REUSEPORT; find the
#                                               real limit first.
#    Everything idle .......................... the bottleneck is off-CPU —
#                                               syscall latency, the client, or
#                                               the loopback path.
#
#  The middle row is the one worth taking seriously: it would mean the planned
#  next change is aimed at the wrong thing.
#
#  Usage:  bash check-loop-thread.sh [--conns 5000] [--secs 6]
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

CONNS=5000
SECS=6
PORT=9010
SERVER=./HorseNghttp2TestServer

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conns) CONNS="$2"; shift 2 ;;
    --secs)  SECS="$2";  shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$SERVER" ]] || { echo "ERROR: $SERVER not built — run build-fpc.sh." >&2; exit 1; }
command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found." >&2; exit 1; }

NEED=$(( CONNS * 2 + 256 ))
[[ "$(ulimit -n)" -lt "$NEED" ]] && {
  echo "ERROR: ulimit -n is $(ulimit -n), need ~$NEED for c=$CONNS." >&2
  echo "       Run:  ulimit -n $NEED" >&2; exit 1; }

SRV=""; LOAD=""
cleanup() {
  [[ -n "$LOAD" ]] && kill -TERM "$LOAD" 2>/dev/null
  [[ -n "$SRV"  ]] && kill -TERM "$SRV"  2>/dev/null
  pkill -P $$ 2>/dev/null
}
on_int() { echo; echo "Interrupted."; cleanup; exit 130; }
trap cleanup EXIT
trap on_int INT TERM

ss -ltn 2>/dev/null | grep -q ":$PORT " && { echo "ERROR: port $PORT busy." >&2; exit 1; }

LOG=$(mktemp)
"$SERVER" eventloop < /dev/null > "$LOG" 2>&1 &
SRV=$!
sleep 1.3

kill -0 "$SRV" 2>/dev/null || { echo "ERROR: server exited:"; sed 's/^/  | /' "$LOG"; exit 1; }

# Same gate as the sweep: `eventloop` degrades silently, and measuring the
# thread driver while believing it is the engine would invert the conclusion.
if ! grep -q "RESOLVED: epoll event loop" "$LOG"; then
  echo "ERROR: engine did not resolve — this would have measured the thread driver."
  grep -E "^\[driver\]|^Driver:" "$LOG" | sed 's/^/  | /'
  exit 1
fi
echo "engine confirmed: $(grep -oE 'RESOLVED: .*' "$LOG" | head -1)"
echo "load: h2load -c $CONNS -m 1, sampling per-thread CPU for ${SECS}s"
echo

# The request count must outlive the sampling window at ANY throughput, so it
# is derived from TIME, not from the connection count.
#
# It was CONNS*60, which at c=100 is 6000 requests — about 0.15s at 40k req/s,
# finished before the 2s pre-sample settle even elapsed. Every thread then
# measured idle and the verdict announced "nothing is saturated" for a server
# that had simply stopped being loaded. The failure scaled the wrong way: it
# only appeared at LOW connection counts, where the run is quickest.
NREQ=$(( 80000 * (SECS + 6) ))
timeout $(( SECS + 60 )) h2load -n "$NREQ" -c "$CONNS" -m 1 \
  "http://127.0.0.1:$PORT/ping" > /dev/null 2>&1 &
LOAD=$!
sleep 2      # let the ramp finish before sampling

HZ=$(getconf CLK_TCK)

snapshot() {   # -> "tid name ticks" per line
  local t
  for t in /proc/$SRV/task/*/; do
    local tid=${t%/}; tid=${tid##*/}
    local st; st=$(cat "$t/stat" 2>/dev/null) || continue
    # utime and stime are fields 14 and 15 AFTER the comm field, which can
    # itself contain spaces — so split on the last ')' rather than by column.
    local rest=${st#*) }
    local u s
    u=$(awk '{print $12}' <<< "$rest")   # utime  (field 14 overall)
    s=$(awk '{print $13}' <<< "$rest")   # stime  (field 15 overall)
    local nm; nm=$(cat "$t/comm" 2>/dev/null || echo "?")
    echo "$tid $nm $(( ${u:-0} + ${s:-0} ))"
  done
}

A=$(snapshot)
sleep "$SECS"
B=$(snapshot)

# Was the server still under load for the whole window? If h2load finished
# early, every number below describes an idle server and means nothing.
LOAD_ALIVE=1
kill -0 "$LOAD" 2>/dev/null || LOAD_ALIVE=0

kill -TERM "$LOAD" 2>/dev/null; LOAD=""
kill -TERM "$SRV"  2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# Compute first, THEN display. The previous version piped the while-loop into
# `sort`, which runs the loop in a SUBSHELL — every BUSY/SATURATED/TOTAL
# increment was discarded when it exited. The table showed one thread at 105.7%
# while the verdict underneath read "threads >80%: 0, total CPU: 0%" and
# concluded the opposite of the truth. A harness that contradicts its own data
# is worse than one that prints nothing.
ROWS=$(while read -r tid nm ticks; do
  before=$(awk -v t="$tid" '$1==t{print $3}' <<< "$A")
  [[ -z "${before:-}" ]] && continue
  pct=$(awk -v d="$(( ticks - before ))" -v hz="$HZ" -v s="$SECS" \
        'BEGIN{printf "%.1f", (d/hz)/s*100}')
  echo "$pct $tid $nm"
done <<< "$B")

echo "| tid | name | CPU% |"
echo "|---|---|---|"
sort -rn <<< "$ROWS" | awk '$1>1 {printf "| %s | %s | %s |\n", $2, $3, $1}'

read -r BUSY SATURATED TOTAL < <(awk '{t+=$1; if($1>20)b++; if($1>80)s++}
  END{printf "%d %d %.1f", b+0, s+0, t+0}' <<< "$ROWS")

rm -f "$LOG"
echo
if [[ "$LOAD_ALIVE" -eq 0 ]]; then
  echo "INVALID — h2load finished before the sampling window closed, so the"
  echo "server was idle for part or all of it. Raise --secs or lower the load."
  exit 2
fi
echo "threads >20% CPU: $BUSY    >80%: $SATURATED    total CPU: ${TOTAL}%"
echo
# The verdict has to distinguish "load is spread because N loops are working"
# from "load is spread because nothing is the bottleneck". Before SO_REUSEPORT
# those were the same reading; now total CPU separates them — many busy threads
# with a HIGH total is the fix working, with a LOW total it is something else.
HIGH_TOTAL=$(awk -v t="$TOTAL" 'BEGIN{print (t>500) ? 1 : 0}')

if [[ "$SATURATED" -ge 1 && "$BUSY" -le 2 ]]; then
  echo "SINGLE-THREAD CEILING — one saturated thread with nothing else busy."
  echo "If the engine is running N loops, they are not sharing the load: check"
  echo "that every loop bound its SO_REUSEPORT listener."
elif [[ "$BUSY" -ge 3 && "$HIGH_TOTAL" -eq 1 ]]; then
  echo "HEALTHY — $BUSY threads busy, none saturated, ${TOTAL}% total."
  echo "Load is spread across loops, which is what N loop threads are for."
  echo "No thread is the ceiling; if throughput has plateaued, the limit is"
  echo "elsewhere — most likely the client or the loopback path. Check whether"
  echo "h2load itself is pegged before changing anything server-side."
elif [[ "$BUSY" -ge 3 ]]; then
  echo "Spread but IDLE — $BUSY threads busy yet only ${TOTAL}% total."
  echo "No server thread is the constraint. Look off-CPU: syscall latency, the"
  echo "client, or the loopback path."
else
  echo "Nothing is CPU-saturated (${TOTAL}% total). The bottleneck is off-CPU —"
  echo "syscall latency, the client, or the loopback path. Check h2load first."
fi
