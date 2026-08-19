#!/usr/bin/env bash
# ============================================================================
#  run-slow-ab.sh — re-take the "22.3x" async-dispatch measurement
#
#  This is NOT run-p1.sh. That one measures per-request cost on /ping at one
#  request in flight. This measures what the worker pool buys on a BLOCKING
#  route with many requests multiplexed on one connection — the only shape
#  where a dispatch pool can help at all.
#
#      h2load -n 200 -c 1 -m 50  http://127.0.0.1:9010/slow/50
#
#  One connection, 50 requests in flight, each handler sleeping 50 ms.
#
#  ── Why it needs re-taking ──
#
#  The original 22.3x (15.90 -> 354.00 req/s) was measured BEFORE FIX-NODELAY.
#  Nagle plus delayed ACK added ~40 ms to every response on Linux, so the
#  inline baseline carried a 50 ms sleep AND a 40 ms stall — ~90 ms per
#  request, not the ~63 ms attributed to serialization at the time. The pool
#  partly hid that stall behind concurrent work, inflating the ratio.
#
#  The direction is not in doubt: inline serializes a blocking route behind one
#  connection thread and the pool does not. The magnitude was wrong.
#
#  ── Why the server banner is captured into the output ──
#
#  An earlier apparent 21x swing "between identical runs" turned out to be two
#  different configurations behind a banner that did not say which was which.
#  Both resolved dispatch lines are printed here, so a number can never again
#  be attributed to the wrong configuration.
#
#  Usage:  bash run-slow-ab.sh [--reqs N] [--streams M] [--workers W] [--slow MS]
#  Needs:  ./HorseNghttp2TestServer built (run build-fpc.sh first) and h2load.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

REQS=200
STREAMS=50
WORKERS=0          # 0 = auto (one per core), matching the original run
SLOW_MS=50
PORT=9010
SERVER=./HorseNghttp2TestServer

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reqs)    REQS="$2"; shift 2 ;;
    --streams) STREAMS="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --slow)    SLOW_MS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$SERVER" ]] || { echo "ERROR: $SERVER not built — run build-fpc.sh first." >&2; exit 1; }
command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found (apt install nghttp2-client)." >&2; exit 1; }

WORK=$(mktemp -d)
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill -TERM "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Zombie-aware: kill -0 succeeds on an exited-but-unreaped child, which once
# sent this harness into an h2load that could never connect.
alive() {
  local pid=$1 st
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  [[ "$st" != "Z" ]]
}

RPS_INLINE=""; RPS_POOL=""
MEAN_INLINE=""; MEAN_POOL=""

measure() {   # <label> [server args...]
  local LABEL=$1; shift
  local OUT RC RPS MEAN

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "  [$LABEL] SKIP — port $PORT already bound (pkill -f HorseNghttp2TestServer)"
    return 1
  fi

  "$SERVER" "$@" < /dev/null > "$WORK/$LABEL.log" 2>&1 &
  SRV=$!
  sleep 1.2      # long enough for TDriverProbe's resolved-driver line

  if ! alive "$SRV"; then
    echo "  [$LABEL] FAIL — server exited at startup"
    sed 's/^/    | /' "$WORK/$LABEL.log"
    wait "$SRV" 2>/dev/null; SRV=""; return 1
  fi

  echo "  [$LABEL] server reports:"
  grep -E "^Dispatch:|^Driver:|^\[driver\]" "$WORK/$LABEL.log" | sed 's/^/      /'

  OUT=$(timeout 300 h2load -n "$REQS" -c 1 -m "$STREAMS" \
          "http://127.0.0.1:$PORT/slow/$SLOW_MS" 2>&1); RC=$?
  if [[ $RC -ne 0 ]]; then
    echo "  [$LABEL] FAIL — h2load rc=$RC"
    echo "$OUT" | tail -5 | sed 's/^/    h2load | /'
    kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; return 1
  fi

  RPS=$(grep -oE '[0-9.]+ req/s' <<< "$OUT" | grep -oE '^[0-9.]+' | head -1)
  # "time for request:  min  max  mean  sd  +/- sd" — field 6 is the mean.
  MEAN=$(awk '/time for request:/ {print $6}' <<< "$OUT")
  echo "  [$LABEL] => ${RPS:-?} req/s   mean latency ${MEAN:-?}"

  if [[ "$LABEL" == "inline" ]]; then
    RPS_INLINE=$RPS; MEAN_INLINE=$MEAN
  else
    RPS_POOL=$RPS; MEAN_POOL=$MEAN
  fi

  kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
  sleep 0.5
}

echo "Async-dispatch A/B — GET /slow/$SLOW_MS, h2load -n $REQS -c 1 -m $STREAMS"
echo "  post-FIX-NODELAY re-take of the original 22.3x measurement"
echo

measure inline inline
if [[ "$WORKERS" -gt 0 ]]; then
  measure pool "workers=$WORKERS"
else
  measure pool
fi

echo
if [[ -n "$RPS_INLINE" && -n "$RPS_POOL" ]]; then
  awk -v i="$RPS_INLINE" -v p="$RPS_POOL" -v mi="$MEAN_INLINE" -v mp="$MEAN_POOL" \
      -v slow="$SLOW_MS" -v m="$STREAMS" 'BEGIN{
    printf "| dispatch | req/s | mean latency |\n";
    printf "|---|---|---|\n";
    printf "| inline | %10.2f | %s |\n", i, mi;
    printf "| pool   | %10.2f | %s |\n", p, mp;
    printf "\npool / inline = %.2fx   (original, pre-NODELAY: 22.3x)\n", p/i;
    printf "\nSanity floor: inline serializes a %d ms handler behind one\n", slow;
    printf "connection thread, so it CANNOT exceed %.2f req/s. A result at or\n", 1000/slow;
    printf "just under that is consistent. Well under means something else is\n";
    printf "also costing time — which is exactly how the pre-NODELAY baseline\n";
    printf "of 15.90 req/s should have been read at the time, and was not.\n";
    printf "\nPool ceiling is about W x %.2f req/s for W workers; with %d\n", 1000/slow, m;
    printf "requests in flight a pool smaller than that queues, so a result\n";
    printf "below the ceiling is saturation rather than a defect.\n";
  }'
else
  echo "Incomplete — see the messages above."
fi
