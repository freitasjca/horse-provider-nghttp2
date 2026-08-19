#!/usr/bin/env bash
# ============================================================================
#  run-conn-sweep.sh — scenario S3: does the epoll engine beat the thread
#  driver, and above which connection count?
#
#  This is the measurement that decides whether the engine is worth extending.
#  Everything else known about it — one loop thread, no SO_REUSEPORT, the O(n)
#  sweep — is a GUESS about what will matter. Optimising against guesses is
#  what produced the 22.3x figure and the "free on fast routes" claim, both of
#  which later needed correcting.
#
#  Stage 12 of build-fpc.sh shows the two drivers at PARITY on one connection
#  issuing requests sequentially. That is the thread driver's best case and the
#  engine's worst — an event loop has no structural advantage there. Parity
#  means "no longer worse". This script looks for "better".
#
#  Both drivers live in the same binary behind one flag, so nothing but the
#  driver changes between cells.
#
#  ── Outcomes and what each directs ──
#
#    engine wins above a crossover ...... publish that number; make it the
#                                         default-on threshold
#    engine plateaus, one core pinned ... SO_REUSEPORT + N loop threads
#    engine degrades as conns climb ..... SweepAndPublish is O(all connections)
#                                         per cycle; make it event-driven
#    thread driver dies first .......... THAT is the win, and it is about
#                                         survival, not throughput
#    no crossover anywhere ............. the engine is not earning its
#                                         complexity. Say so and stop.
#
#  The last one is why this runs before any more engine work.
#
#  Usage:  bash run-conn-sweep.sh [--conns "10 100 1000"] [--route /ping]
#  Needs:  ./HorseNghttp2TestServer built (build-fpc.sh) and h2load.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

CONN_LIST="10 100 1000 5000 10000"
ROUTE=/ping
PORT=9010
SERVER=./HorseNghttp2TestServer
OUT="conn-sweep-$(date +%Y%m%d-%H%M%S).md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conns) CONN_LIST="$2"; shift 2 ;;
    --route) ROUTE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$SERVER" ]] || { echo "ERROR: $SERVER not built — run build-fpc.sh first." >&2; exit 1; }
command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found." >&2; exit 1; }

# ── File-descriptor headroom ────────────────────────────────────────────────
# Both client and server need roughly one fd per connection. If the limit bites
# first, the cell measures ulimit rather than the server — and it fails in a way
# that looks exactly like the thread exhaustion this script is hunting for.
MAXCONN=$(tr ' ' '\n' <<< "$CONN_LIST" | sort -n | tail -1)
NOFILE=$(ulimit -n)
NEED=$(( MAXCONN * 2 + 256 ))
if [[ "$NOFILE" -lt "$NEED" ]]; then
  echo "WARNING: ulimit -n is $NOFILE, and c=$MAXCONN needs about $NEED."
  echo "         Cells at high connection counts will fail on descriptors, not"
  echo "         on the server — which is indistinguishable from the thread"
  echo "         exhaustion this script exists to find. Raise it first:"
  echo "             ulimit -n $NEED"
  echo
  read -r -p "Continue anyway? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
fi

WORK=$(mktemp -d)
SRV=""
SPID=""

# Kill everything this script started: the server, the RSS sampler, and any
# h2load/timeout still running as our children.
cleanup() {
  [[ -n "$SPID" ]] && kill -TERM "$SPID" 2>/dev/null
  [[ -n "$SRV"  ]] && kill -TERM "$SRV"  2>/dev/null
  pkill -P $$ 2>/dev/null
  rm -rf "$WORK"
}

# Ctrl-C MUST exit, not just clean up.
#
# This was `trap cleanup EXIT INT TERM`, and cleanup only killed the server —
# so SIGINT ran the handler and bash then RESUMED the loop, starting the next
# cell. The script was uninterruptible: every Ctrl-C killed one server and
# moved on to spawn another. Separate traps, and the signal handler exits.
on_int() {
  echo
  echo "Interrupted — stopping the sweep."
  cleanup
  exit 130
}
trap cleanup EXIT
trap on_int INT TERM

alive() {   # kill -0 succeeds on an unreaped zombie; /proc state does not
  local pid=$1 st
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  [[ "$st" != "Z" ]]
}

# Peak RSS and thread count while the load runs. Sampled, because both climb
# during the ramp and the peak is the interesting number.
sample_peak() {   # <pid> <outfile>
  local pid=$1 f=$2 rss thr maxr=0 maxt=0
  while alive "$pid"; do
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    thr=$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    [[ -n "${rss:-}" && "$rss" -gt "$maxr" ]] && maxr=$rss
    [[ -n "${thr:-}" && "$thr" -gt "$maxt" ]] && maxt=$thr
    sleep 0.2
  done
  echo "$maxr $maxt" > "$f"
}

declare -A RPS RSS THR NOTE

run_cell() {   # <mode> <conns>
  local MODE=$1 CONNS=$2 KEY="$1/$2"
  local ARGS=() N OUTP RC SAMP PEAK

  RPS[$KEY]=""; RSS[$KEY]=""; THR[$KEY]=""; NOTE[$KEY]=""

  [[ "$MODE" == "eventloop" ]] && ARGS=(eventloop)

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    NOTE[$KEY]="port busy"; echo "    SKIP — port $PORT bound"; return
  fi

  "$SERVER" "${ARGS[@]+"${ARGS[@]}"}" < /dev/null > "$WORK/$MODE-$CONNS.log" 2>&1 &
  SRV=$!
  sleep 1.3      # TDriverProbe reports the resolved driver ~400 ms in

  if ! alive "$SRV"; then
    NOTE[$KEY]="server exited at startup"
    echo "    FAIL — server exited"; sed 's/^/      | /' "$WORK/$MODE-$CONNS.log"
    wait "$SRV" 2>/dev/null; SRV=""; return
  fi

  # The driver actually in force. `eventloop` degrades silently when
  # unavailable, and a cell that fell back would be a duplicate of the thread
  # row wearing the engine's label — the single worst thing this table could
  # contain.
  local RESOLVED
  RESOLVED=$(grep -oE 'RESOLVED: .*' "$WORK/$MODE-$CONNS.log" | head -1)
  if [[ "$MODE" == "eventloop" && "$RESOLVED" != *"epoll event loop"* ]]; then
    NOTE[$KEY]="engine NOT resolved — cell discarded"
    echo "    FAIL — asked for the engine, got: ${RESOLVED:-nothing}"
    kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; return
  fi

  N=$(( CONNS * 20 )); [[ "$N" -lt 20000 ]] && N=20000

  timeout 60 h2load -n "$CONNS" -c "$CONNS" -m 1 \
    "http://127.0.0.1:$PORT$ROUTE" > /dev/null 2>&1   # warm-up / ramp

  SAMP="$WORK/$MODE-$CONNS.peak"
  sample_peak "$SRV" "$SAMP" &
  SPID=$!

  OUTP=$(timeout 90 h2load -n "$N" -c "$CONNS" -m 1 \
           "http://127.0.0.1:$PORT$ROUTE" 2>&1); RC=$?

  kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
  wait "$SPID" 2>/dev/null; SPID=""
  PEAK=$(cat "$SAMP" 2>/dev/null || echo "0 0")
  RSS[$KEY]=$(( $(cut -d' ' -f1 <<< "$PEAK") / 1024 ))
  THR[$KEY]=$(cut -d' ' -f2 <<< "$PEAK")

  if [[ $RC -eq 124 ]]; then
    NOTE[$KEY]="TIMED OUT (90s)"; echo "    TIMEOUT"; return
  fi

  local OK FAILED
  OK=$(grep -oE '[0-9]+ succeeded' <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  FAILED=$(grep -oE '[0-9]+ failed' <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  RPS[$KEY]=$(grep -oE '[0-9.]+ req/s' <<< "$OUTP" | grep -oE '^[0-9.]+' | head -1)

  # Partial failure is a RESULT, not a harness error — a driver that starts
  # dropping connections at some count is exactly what this sweep looks for.
  if [[ -n "${FAILED:-}" && "$FAILED" -gt 0 ]]; then
    NOTE[$KEY]="${FAILED} of $N failed"
  fi
  echo "    ${RPS[$KEY]:-?} req/s   RSS ${RSS[$KEY]}MB   threads ${THR[$KEY]}   ${NOTE[$KEY]:-ok}"
}

{
  echo "# Connection-scale sweep (S3) — epoll engine vs thread driver"
  echo
  echo "- host: \`$(uname -srm)\`, $(nproc) cores, ulimit -n $NOFILE"
  echo "- route: \`$ROUTE\`, h2load \`-c N -m 1\`, n = max(20000, 20N)"
  echo
  echo "Same binary, same routes; only the connection driver differs."
  echo "Every engine cell verifies \`[driver] RESOLVED: epoll event loop\` —"
  echo "a silent fallback would duplicate the thread row under the engine's name."
} | tee "$OUT"

for MODE in thread eventloop; do
  echo | tee -a "$OUT"
  echo "## $MODE" | tee -a "$OUT"
  echo | tee -a "$OUT"
  echo "| conns | req/s | peak RSS MB | peak threads | note |" | tee -a "$OUT"
  echo "|---|---|---|---|---|" | tee -a "$OUT"
  # Stop escalating once a driver has clearly given up. The first run spent
  # seven minutes on thread/c=10000 after thread/c=5000 had already timed out —
  # a foregone conclusion at full price. The wall is the finding; grinding
  # past it adds nothing.
  COLLAPSED=0
  for C in $CONN_LIST; do
    if [[ $COLLAPSED -eq 1 ]]; then
      echo "  [$MODE c=$C] SKIPPED — this driver already failed at a lower count"
      echo "| $C | — | — | — | skipped after earlier failure |" >> "$OUT"
      continue
    fi
    echo "  [$MODE c=$C]"
    run_cell "$MODE" "$C"
    K="$MODE/$C"
    echo "| $C | ${RPS[$K]:-—} | ${RSS[$K]:-—} | ${THR[$K]:-—} | ${NOTE[$K]:-} |" >> "$OUT"
    # A timeout, a dead server, or zero throughput means this driver is done.
    # Partial connection failures do NOT count — those are still a measurement.
    if [[ -z "${RPS[$K]:-}" || "${NOTE[$K]:-}" == *"TIMED OUT"* \
          || "${NOTE[$K]:-}" == *"exited"* ]]; then
      COLLAPSED=1
      echo "    ^ treating this as the ceiling for $MODE; skipping higher counts"
    fi
    sleep 1
  done
done

{
  echo
  echo "## Comparison"
  echo
  echo "| conns | thread req/s | engine req/s | engine / thread |"
  echo "|---|---|---|---|"
  for C in $CONN_LIST; do
    t=${RPS[thread/$C]:-}; e=${RPS[eventloop/$C]:-}
    if [[ -n "$t" && -n "$e" ]]; then
      printf "| %s | %s | %s | %s |\n" "$C" "$t" "$e" \
        "$(awk -v a="$t" -v b="$e" 'BEGIN{ if(a>0) printf "%.2fx", b/a; else print "—" }')"
    else
      printf "| %s | %s | %s | — |\n" "$C" "${t:-—}" "${e:-—}"
    fi
  done
  echo
  echo "Read the CROSSOVER, not any single row. Below it the thread driver"
  echo "should win — a dedicated thread blocking in recv beats a poll loop when"
  echo "there is nothing to multiplex. Above it, if the engine never pulls"
  echo "ahead and the thread driver never falls over, the engine is not earning"
  echo "its complexity and that is the finding."
  echo
  echo "Peak threads is the other half: the thread driver should track the"
  echo "connection count and the engine should stay flat. A thread row that"
  echo "stops climbing is hitting a limit, not being efficient."
} | tee -a "$OUT"

echo
echo "Results: $OUT"
