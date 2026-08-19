#!/usr/bin/env bash
# ============================================================================
#  run-slow-latency-ab.sh — did FALLBACK-1 disturb normal-operation latency?
#
#  FALLBACK-1 runs the pipeline inline when the dispatch queue is full instead
#  of answering 503. It cut refusals at c=10 000 on /ping by 84% (39 860 ->
#  6 344). The open question is whether it costs anything when the queue is
#  NOT full — i.e. on every ordinary request.
#
#  ── The decisive check is a counter, not a stopwatch ──
#
#  Inline execution is known to cost tail latency: on /slow/50 via the epoll
#  engine, pool and inline have identical throughput and identical MEAN, but
#  inline's max was 1.14s vs 410ms at c=200 and 4.64s vs 1.85s at c=1000.
#  That is head-of-line blocking — a stalled loop holds its ~c/28 connections.
#
#  So if the fallback engaged during normal operation, the pool rows would
#  drift toward the inline numbers. But rather than inferring that from
#  latency, this reads `inlineFallbacks` from /metrics/shed:
#
#    inlineFallbacks = 0  ->  the path never ran. Any latency difference from
#                             baseline is noise or something else entirely,
#                             and FALLBACK-1 is not implicated.
#    inlineFallbacks > 0  ->  it DID engage on a blocking route. Then the
#                             latency numbers matter, and the cap wants
#                             revisiting.
#
#  Reading the counter turns "the numbers look about the same" into a fact.
#  Latency is still reported, because a regression from some other cause would
#  show there and nowhere else.
#
#  ── Baselines, measured 2026-08-18 BEFORE FALLBACK-1 ──
#
#    /slow/50 c=200   pool   555.5 req/s  mean 353.15ms  max 410.23ms  sd  38.46ms
#                     inline 555.5 req/s  mean 351.88ms  max   1.14s   sd 175.28ms
#    /slow/50 c=1000  pool   555.6 req/s  mean   1.63s   max   1.85s   sd 412.62ms
#                     inline 555.4 req/s  mean   1.63s   max   4.64s   sd 582.45ms
#
#  ~555 req/s is the ceiling either way: 28 threads / 50ms = 560.
#
#  Usage:  bash run-slow-latency-ab.sh [--conns "200 1000"] [--secs 10]
#  Needs:  ./HorseNghttp2TestServer built, h2load, curl with HTTP/2.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

CONN_LIST="200 1000"
SECS=10
PORT=9010
SERVER=./HorseNghttp2TestServer
OUT="slow-latency-$(date +%Y%m%d-%H%M%S).md"
CT=$(( $(nproc) / 2 )); [[ $CT -gt 14 ]] && CT=14; [[ $CT -lt 1 ]] && CT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conns) CONN_LIST="$2"; shift 2 ;;
    --secs)  SECS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$SERVER" ]] || { echo "ERROR: $SERVER not built — run build-fpc.sh." >&2; exit 1; }
command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found." >&2; exit 1; }
curl --http2-prior-knowledge -sS -o /dev/null http://127.0.0.1:1 2>&1 | grep -qi "not support" && {
  echo "ERROR: this curl has no HTTP/2 — the counter read is the point of this script." >&2
  exit 1; }

# A stale server from a previous run holds the port, every case skips, and the
# verdict below would then conclude from an empty table. Fail here instead.
if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
  echo "ERROR: port $PORT is already bound — a server from an earlier run is"
  echo "       still listening. This script would skip every case and then"
  echo "       report a verdict on no data."
  echo
  echo "  Who has it:"
  ss -ltnp 2>/dev/null | grep ":$PORT " | sed 's/^/    /'
  echo
  echo "  Free it:  pkill -x HorseNghttp2TestServer"
  echo "            (-x, not -f: an -f pattern also matches your own shell)"
  exit 1
fi

WORK=$(mktemp -d)
SRV=""
cleanup() {
  [[ -n "$SRV" ]] && kill -TERM "$SRV" 2>/dev/null
  # -x, never -f: an -f pattern also matches the shell running this script.
  pkill -x HorseNghttp2TestServer 2>/dev/null
  rm -rf "$WORK"
}
on_int() { echo; echo "Interrupted."; cleanup; exit 130; }
trap cleanup EXIT
trap on_int INT TERM

alive() {
  local pid=$1 st
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  [[ "$st" != "Z" ]]
}

declare -A RPS LAT SHED FB OK

run_case() {   # <label> <conns> <server args...>
  local LABEL=$1 C=$2; shift 2
  local O M

  ss -ltn 2>/dev/null | grep -q ":$PORT " && { echo "    SKIP — port $PORT busy"; return 1; }

  "$SERVER" "$@" < /dev/null > "$WORK/$LABEL.log" 2>&1 &
  SRV=$!
  sleep 2
  alive "$SRV" || { echo "    FAIL — server exited"; sed 's/^/      | /' "$WORK/$LABEL.log"; return 1; }
  grep -q "RESOLVED: epoll event loop" "$WORK/$LABEL.log" || {
    echo "    FAIL — engine not resolved"; kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; return 1; }

  O=$(timeout $(( SECS + 60 )) h2load -D "$SECS" -t "$CT" -c "$C" -m 1 \
        "http://127.0.0.1:$PORT/slow/50" 2>&1)

  # Counters read while the server is STILL RUNNING — this is the measurement,
  # not a footnote. After the kill they are gone.
  M=$(curl -s --http2-prior-knowledge "http://127.0.0.1:$PORT/metrics/shed" 2>/dev/null)
  SHED[$LABEL]=$(grep -oE '"sheddedRequests":[0-9]+' <<< "$M" | grep -oE '[0-9]+$')
  FB[$LABEL]=$(grep -oE '"inlineFallbacks":[0-9]+' <<< "$M" | grep -oE '[0-9]+$')

  kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

  RPS[$LABEL]=$(grep -oE '[0-9.]+ req/s' <<< "$O" | head -1 | grep -oE '^[0-9.]+')
  LAT[$LABEL]=$(grep -E '^time for request:' <<< "$O" | sed 's/time for request:\s*//')

  printf "    %s req/s | %s\n" "${RPS[$LABEL]:-?}" "${LAT[$LABEL]:-?}"
  printf "    counters: shed=%s fallbacks=%s\n" "${SHED[$LABEL]:-?}" "${FB[$LABEL]:-?}"
  # Only a case that reached here has data. The verdict checks this rather
  # than reading an unset counter as zero.
  [[ -n "${FB[$LABEL]:-}" && -n "${RPS[$LABEL]:-}" ]] && OK[$LABEL]=1
  sleep 2
  return 0
}

{
  echo "# /slow/50 latency A/B — does FALLBACK-1 cost anything in normal operation?"
  echo
  echo "- host: \`$(uname -srm)\`, $(nproc) cores"
  echo "- h2load \`-D $SECS -t $CT -c N -m 1\` against \`/slow/50\`, epoll engine"
  echo
  echo "The counter is the verdict. \`inlineFallbacks = 0\` means the fallback"
  echo "path never ran, so it cannot be responsible for any latency difference."
} | tee "$OUT"

for C in $CONN_LIST; do
  echo | tee -a "$OUT"
  echo "## c=$C" | tee -a "$OUT"
  echo "  [pool + FALLBACK-1 c=$C]"; run_case "pool-$C" "$C" eventloop
  echo "  [inline c=$C]";            run_case "inline-$C" "$C" eventloop inline
done

{
  echo
  echo "## Results"
  echo
  echo "| case | req/s | time for request (min / max / mean / sd / +-sd) | shed | fallbacks |"
  echo "|---|---|---|---|---|"
  for C in $CONN_LIST; do
    for M in pool inline; do
      K="$M-$C"
      printf "| %s c=%s | %s | %s | %s | %s |\n" "$M" "$C" \
        "${RPS[$K]:-—}" "${LAT[$K]:-—}" "${SHED[$K]:-—}" "${FB[$K]:-—}"
    done
  done
  echo
  echo "## Baseline before FALLBACK-1 (2026-08-18)"
  echo
  echo "| case | req/s | mean | max | sd |"
  echo "|---|---|---|---|---|"
  echo "| pool c=200 | 555.5 | 353.15ms | 410.23ms | 38.46ms |"
  echo "| inline c=200 | 555.5 | 351.88ms | **1.14s** | 175.28ms |"
  echo "| pool c=1000 | 555.6 | 1.63s | 1.85s | 412.62ms |"
  echo "| inline c=1000 | 555.4 | 1.63s | **4.64s** | 582.45ms |"
  echo
  echo "## Verdict"
  echo
  # Did anything actually run? An unset counter is NOT a zero reading, and
  # the first version of this script drew a green verdict from four skipped
  # cases because ${FB[...]:-0} silently supplied one.
  MISSING=""
  for C in $CONN_LIST; do
    for M in pool inline; do
      [[ -n "${OK[$M-$C]:-}" ]] || MISSING="$MISSING $M-c$C"
    done
  done

  ANY=0
  for C in $CONN_LIST; do
    [[ -n "${OK[pool-$C]:-}" ]] || continue
    [[ "${FB[pool-$C]}" -gt 0 ]] && ANY=1
  done

  if [[ -n "$MISSING" ]]; then
    echo "**INCONCLUSIVE — these cases produced no data:**$MISSING"
    echo
    echo "No verdict is drawn. A missing counter is not a reading of zero, and"
    echo "treating it as one is how a harness reports success for a run that"
    echo "never happened. Fix the cause above and re-run."
  elif [[ "$ANY" -eq 0 ]]; then
    echo "**FALLBACK-1 did not engage** — \`inlineFallbacks = 0\` on every pool row."
    echo "The queue never filled on this route, which is what the 0 5xx in the"
    echo "pre-FALLBACK-1 runs already implied. The path is therefore not"
    echo "implicated in any latency difference from baseline; compare the pool"
    echo "rows against the baseline table above and treat any gap as run-to-run"
    echo "variance or a separate regression."
    echo
    echo "The inline rows are the control: they should still show the 2.5-2.8x"
    echo "worse max that made inline-by-default the wrong answer. If they do not,"
    echo "something about the measurement changed, not the server."
  else
    echo "**FALLBACK-1 DID engage on a blocking route** — \`inlineFallbacks > 0\`."
    echo "That was not expected here: /slow/50 filled the queue. Now the latency"
    echo "numbers matter directly, because inline execution on a 50ms handler is"
    echo "exactly the case that produced the 4.64s tail. Compare the pool rows to"
    echo "the baseline: if max has drifted toward the inline figure, lower"
    echo "MaxInlineFallback, or set INLINE_FALLBACK_DISABLED for blocking routes."
  fi
} | tee -a "$OUT"

echo
echo "Results: $OUT"
