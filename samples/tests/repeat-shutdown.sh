#!/usr/bin/env bash
# ============================================================================
#  repeat-shutdown.sh — run build-fpc.sh's stage 6 on its own, N times
#
#  Why this exists: the graceful-drain time jumped from a very tight 1817 /
#  1816 / 1817 ms to 3271 ms after the B3 pump extraction. Every run passed —
#  all 200 started requests answered — so the question is only whether that
#  number is load or a regression, and one sample cannot tell.
#
#  Running the full 15-stage suite to re-measure one stage costs minutes and
#  rebuilds everything, which is its own source of variance. This reproduces
#  stage 6 EXACTLY (same server arguments, same h2load invocation) against the
#  binary already built in this directory, and reports the spread.
#
#  Reading the result — the drain is quantised, so expect steps, not a curve:
#    /slow/500 sleeps 500 ms, the pool has one worker per core, and shutdown
#    fires at a fixed t=3000 ms. Whatever is still queued at that instant
#    drains in ~500 ms waves. The observed 1816 → 3271 gap is 1455 ms, i.e.
#    almost exactly three waves — so a few requests' difference in how far
#    h2load got by t=3000 ms moves the total by whole half-seconds.
#
#    LOAD:       values cluster on a few distinct plateaus ~500 ms apart, and
#                the low plateau is still reachable.
#    REGRESSION: values sit at the high plateau every time, and the ~1.8 s
#                figure never comes back.
#
#  Usage:  bash repeat-shutdown.sh [runs]      (default 5)
# ============================================================================
set -uo pipefail

RUNS="${1:-5}"
PORT=9010
SERVER=./HorseNghttp2TestServer

cd "$(dirname "$0")" || exit 1

# ── Preconditions ───────────────────────────────────────────────────────────
if [[ ! -x "$SERVER" ]]; then
  echo "ERROR: $SERVER not found or not executable." >&2
  echo "       Run build-fpc.sh once first — it leaves the binary here." >&2
  exit 1
fi

if ! command -v h2load > /dev/null 2>&1; then
  echo "ERROR: h2load not installed (apt install nghttp2-client)." >&2
  exit 1
fi

WORK="$(mktemp -d)"
SRV=""

cleanup() {
  [[ -n "$SRV" ]] && kill -TERM "$SRV" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# An orphan from an interrupted run silently steals the port, and then every
# measurement below belongs to a server that is not the one under test.
require_port_free() {
  if command -v ss > /dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "ERROR: port $PORT is already bound." >&2
    echo "       Usually an orphaned server: pkill -f HorseNghttp2TestServer" >&2
    exit 1
  fi
}

echo "Repeating build-fpc.sh stage 6 — $RUNS run(s)"
echo "  server:  $SERVER shutdown-after=3000 shutdown-timeout=10000"
echo "  load:    h2load -n 200 -c 4 -m 25 http://127.0.0.1:$PORT/slow/500"
echo

RESULTS=()
ANOMALY=0

for ((i = 1; i <= RUNS; i++)); do
  require_port_free

  stdbuf -o0 -e0 "$SERVER" shutdown-after=3000 shutdown-timeout=10000 \
    < /dev/null > "$WORK/shutdown-$i.log" 2>&1 &
  SRV=$!
  sleep 0.6

  if ! kill -0 "$SRV" 2>/dev/null; then
    echo "run $i: server exited at startup —"
    tail -4 "$WORK/shutdown-$i.log" | sed 's/^/    | /'
    ANOMALY=1
    SRV=""
    continue
  fi

  timeout 60 h2load -n 200 -c 4 -m 25 "http://127.0.0.1:$PORT/slow/500" \
    < /dev/null > "$WORK/h2load-$i.log" 2>&1 || true

  # The server self-terminates through its own StopListenGraceful. If a defect
  # parks it there, do not inherit the hang.
  if ! timeout 60 tail --pid="$SRV" -f /dev/null 2>/dev/null; then
    kill -TERM "$SRV" 2>/dev/null
  fi
  wait "$SRV" 2>/dev/null
  SRV=""

  MS=$(grep -oE 'returned after: [0-9]+ ms' "$WORK/shutdown-$i.log" \
       | grep -oE '[0-9]+' | head -1)
  INFLIGHT=$(grep -oE 'in flight at trigger: [0-9]+' "$WORK/shutdown-$i.log" \
       | grep -oE '[0-9]+' | head -1)
  STARTED=$(grep -oE '[0-9]+ started' "$WORK/h2load-$i.log" | grep -oE '^[0-9]+' | head -1)
  SUCCEEDED=$(grep -oE '[0-9]+ succeeded' "$WORK/h2load-$i.log" | grep -oE '^[0-9]+' | head -1)

  MS="${MS:-?}"; INFLIGHT="${INFLIGHT:-?}"
  STARTED="${STARTED:-0}"; SUCCEEDED="${SUCCEEDED:-0}"

  # Timing is the question, but correctness still has to hold every run — a
  # fast drain that severed replies is a failure, not a good result.
  if [[ "$STARTED" != "$SUCCEEDED" ]] || [[ "$STARTED" == "0" ]]; then
    VERDICT="*** DELIVERY FAILURE ***"
    ANOMALY=1
  else
    VERDICT="ok"
  fi

  printf 'run %2d:  drain %6s ms   in-flight-at-trigger %3s   %s/%s answered   %s\n' \
    "$i" "$MS" "$INFLIGHT" "$SUCCEEDED" "$STARTED" "$VERDICT"

  [[ "$MS" != "?" ]] && RESULTS+=("$MS")
done

# ── Summary ─────────────────────────────────────────────────────────────────
echo
if [[ ${#RESULTS[@]} -eq 0 ]]; then
  echo "No timings collected."
  exit 1
fi

SORTED=$(printf '%s\n' "${RESULTS[@]}" | sort -n)
MIN=$(echo "$SORTED" | head -1)
MAX=$(echo "$SORTED" | tail -1)
SUM=0
for v in "${RESULTS[@]}"; do SUM=$((SUM + v)); done
MEAN=$((SUM / ${#RESULTS[@]}))

echo "drain times (ms), sorted: $(echo "$SORTED" | tr '\n' ' ')"
echo "  min $MIN   mean $MEAN   max $MAX   spread $((MAX - MIN))"
echo
echo "Reference: 1817 / 1816 / 1817 ms before the B3 extraction; 3271 ms after."
echo "  min back near ~1.8 s  → the 3271 was load, nothing to chase."
echo "  every run near ~3.3 s → look again at when SetIdle publishes,"
echo "                          i.e. TNghttp2ConnectionPump.Idle and its caller."
[[ $ANOMALY -ne 0 ]] && echo && echo "NOTE: at least one run had a delivery or startup anomaly — see above."
exit 0
