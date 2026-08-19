#!/usr/bin/env bash
# ============================================================================
#  verify-drain-delivery.sh — does graceful shutdown deliver in-flight
#  requests to a CONFORMING client?
#
#  Why this exists
#  ───────────────
#  build-fpc.sh stage 6 asserted `h2load started == succeeded` and failed on
#  every run for days while the server was behaving correctly. This script
#  answers the question that gate could not: does a CONFORMING client, with a
#  request genuinely in flight across the trigger, get its response?
#
#  ANSWER (2026-08-19): yes. 9 consecutive runs, 27/27 cases, after the host
#  was switched off WSL2 mirrored networking. `nghttp -v` shows a byte-perfect
#  RFC 9113 §6.8 exchange: notice GOAWAY(2^31-1) -> the in-flight stream
#  finishes -> final GOAWAY whose last_stream_id COVERS it -> HEADERS +
#  DATA/END_STREAM.
#
#  Under WSL2 `networkingMode=mirrored` the SAME binary fails cases A and C
#  ~100% of the time: the mirrored stack injects an RST at the sequence
#  numbers the client has just ACKed while the server socket keeps writing.
#  If this script fails, check the networking mode before the provider.
#
#  Every case here uses nghttp. Using curl would re-measure curl, which is
#  exactly the mistake stage 6 made with h2load — and which cost this
#  investigation five wrong diagnoses before a frame trace settled it.
#  (An earlier version of this header blamed curl 7.81 for mishandling the
#  graceful notice. That was wrong twice over: the asymmetry was the RST race,
#  and the nghttp side of the comparison was measuring `nghttp -n`, which
#  discards the body. Both are recorded in the handoff's Refuted table.)
#
#  The three shapes are the ones stage 6 actually loads the server with:
#
#    A  1 request                    — baseline
#    B  4 concurrent, 4 CONNECTIONS  — mirrors h2load -c 4 -m 1
#    C  8 concurrent, 1 CONNECTION   — mirrors -m N multiplexing, the only
#                                      case where many streams share one
#                                      session through the drain
#
#  All three PASS => the framework contract holds (horse/.agents/AGENTS.md,
#  "Server Lifecycle & Graceful Shutdown"). A FAIL in B or C => a concurrency
#  defect the single-request case cannot see, and the stage-6 gate must NOT be
#  relaxed until it is understood.
#
#  Guards, and why they are not optional
#  ────────────────────────────────────
#  Two separate investigations were derailed by unguarded runs: an orphaned
#  server answering the next run's traffic (errno 98), and a curl racing the
#  bind and reporting "Connection reset by peer" that was later shown to be a
#  teardown from the PREVIOUS server. Both produced confident wrong
#  conclusions. So every case here refuses to report unless its own server
#  owns the port, and every case waits for the bind.
#
#  `pkill -x HorseNghttp2TestServer` does NOT work — Linux truncates comm to
#  15 chars and the name is 22, so it exits 0 having killed nothing. Kill by
#  the truncation, and fall back to the port's real owner.
#
#  Usage:  bash verify-drain-delivery.sh          (run from samples/tests)
# ============================================================================
set -u

SERVER=./HorseNghttp2TestServer
PORT=9010
SERVER_COMM="$(basename "$SERVER" | cut -c1-15)"

# Request longer than the trigger, so every request IS in flight when the
# drain starts. 3 s work, drain fires at 1 s, 20 s ceiling so the deadline is
# never the thing under test.
SLOW_MS=3000
TRIGGER_MS=1000
TIMEOUT_MS=20000

[[ -x "$SERVER" ]] || { echo "ERROR: run me from samples/tests"; exit 1; }
command -v nghttp > /dev/null 2>&1 || { echo "ERROR: nghttp not installed (apt install nghttp2-client)"; exit 1; }
command -v ss   > /dev/null 2>&1 || { echo "ERROR: ss not available"; exit 1; }

PASSES=0; FAILURES=0; VOIDS=0

port_bound() { ss -ltn 2>/dev/null | grep -q ":$PORT "; }

freeport() {
  local i pids
  pkill -x "$SERVER_COMM" 2>/dev/null || true
  for i in $(seq 60); do port_bound || return 0; sleep 0.1; done
  pids=$(ss -ltnp 2>/dev/null | grep ":$PORT " \
         | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ')
  if [[ -n "${pids// /}" ]]; then
    kill -TERM $pids 2>/dev/null || true; sleep 1
    kill -KILL $pids 2>/dev/null || true
  fi
  for i in $(seq 60); do port_bound || return 0; sleep 0.1; done
  return 1
}

# Starts a server and blocks until it is actually listening. Returns non-zero
# (and prints nothing) if it never binds — the caller marks the case VOID.
start_server() {
  local log=$1 i
  freeport || return 1
  "$SERVER" shutdown-after=$TRIGGER_MS shutdown-timeout=$TIMEOUT_MS \
    < /dev/null > "$log" 2>&1 &
  SRV=$!
  for i in $(seq 100); do
    grep -q 'fpBind' "$log" 2>/dev/null && return 1
    kill -0 "$SRV" 2>/dev/null || return 1
    port_bound && return 0
    sleep 0.05
  done
  return 1
}

finish_server() {
  if ! timeout 40 tail --pid="$SRV" -f /dev/null 2>/dev/null; then
    kill -TERM "$SRV" 2>/dev/null || true
  fi
  wait "$SRV" 2>/dev/null
}

# A reply counts only if BOTH the status is 200 and the body is the complete
# JSON the route promises. A truncated body with a 200 status is exactly what
# a severed response looks like, so checking the code alone would pass it.
count_ok() {
  # Counts OCCURRENCES, not files: case C multiplexes 8 responses onto one
  # connection and nghttp concatenates their bodies into a single stream, so
  # "files containing a body" would report 1 for a perfect 8/8 run.
  local dir=$1 n=0 f k
  for f in "$dir"/out.*; do
    [[ -f "$f" ]] || continue
    k=$(grep -o "\"sleptMs\":$SLOW_MS" "$f" 2>/dev/null | wc -l)
    n=$((n + k))
  done
  echo "$n"
}

# On failure, say WHY. The first version of this script sent curl's stderr to
# /dev/null and reported "0/1 delivered" with no way to tell a server defect
# from a client error from a bug in the harness — which is how case A came
# back FAIL for a shape that had already been observed working by hand.
# A check that cannot explain its own failure is not a check.
dump_detail() {
  local dir=$1 i rc err sz
  for f in "$dir"/rc.*; do
    [[ -f "$f" ]] || continue
    i=${f##*.}
    rc=$(cat "$f" 2>/dev/null)
    sz=0; [[ -f "$dir/out.$i" ]] && sz=$(wc -c < "$dir/out.$i")
    err=$(tr -d '\r' < "$dir/err.$i" 2>/dev/null | grep -v '^\s*$' | tail -1)
    printf '        req %-3s client-exit=%-3s body=%-6s %s\n' \
      "$i" "${rc:-?}" "${sz}B" "${err:-}"
  done
}

report() {
  local name=$1 want=$2 got=$3 log=$4 dir=$5
  local drain
  drain=$(grep -oE 'returned after: [0-9]+ ms' "$log" | grep -oE '[0-9]+' | head -1)
  printf '  %-34s %d/%d delivered   drain %sms   ' \
    "$name" "$got" "$want" "${drain:-n/a}"
  if [[ "$got" == "$want" ]]; then
    echo "→ PASS"; PASSES=$((PASSES + 1))
  else
    echo "→ FAIL"; FAILURES=$((FAILURES + 1))
    dump_detail "$dir"
  fi
}

echo "verify-drain-delivery — does the drain deliver to a conforming client?"
echo "  route /slow/$SLOW_MS · trigger ${TRIGGER_MS}ms · timeout ${TIMEOUT_MS}ms"
echo "  every request is in flight when the drain starts"
echo

# ── A · one request ─────────────────────────────────────────────────────────
WORK=$(mktemp -d)
if ! start_server "$WORK/server.log"; then
  echo "  !! A VOID — server never bound"; VOIDS=$((VOIDS + 1))
else
  nghttp "http://127.0.0.1:$PORT/slow/$SLOW_MS" \
    > "$WORK/out.1" 2> "$WORK/err.1"
  echo $? > "$WORK/rc.1"
  finish_server
  report "A  1 request" 1 "$(count_ok "$WORK")" "$WORK/server.log" "$WORK"
fi
rm -rf "$WORK"

# ── B · 4 concurrent, separate connections (mirrors h2load -c 4 -m 1) ───────
WORK=$(mktemp -d)
if ! start_server "$WORK/server.log"; then
  echo "  !! B VOID — server never bound"; VOIDS=$((VOIDS + 1))
else
  for i in 1 2 3 4; do
    ( nghttp "http://127.0.0.1:$PORT/slow/$SLOW_MS" \
        > "$WORK/out.$i" 2> "$WORK/err.$i"
      echo $? > "$WORK/rc.$i" ) &
  done
  wait
  finish_server
  report "B  4 concurrent, 4 connections" 4 "$(count_ok "$WORK")" "$WORK/server.log" "$WORK"
fi
rm -rf "$WORK"

# ── C · 8 concurrent streams on ONE connection ──────────────────────────────
# --parallel makes curl multiplex same-host HTTP/2 requests over a single
# connection, which is the shape -m N produces and the one no other case here
# covers: many streams sharing one session through the drain.
WORK=$(mktemp -d)
if ! start_server "$WORK/server.log"; then
  echo "  !! C VOID — server never bound"; VOIDS=$((VOIDS + 1))
else
  URLS=()
  for i in 1 2 3 4 5 6 7 8; do
    # DISTINCT URLs. nghttp COLLAPSES identical URIs — eight copies of one URL
    # produced a single HEADERS frame (verified in a -v trace: only
    # stream_id=13 was ever opened) while this case asserted eight bodies, so
    # it could never score above 1/8 and failed unconditionally. The query
    # parameter is ignored by /slow/:ms and exists only to keep the URIs
    # distinct.
    URLS+=("http://127.0.0.1:$PORT/slow/$SLOW_MS?n=$i")
  done
  # nghttp multiplexes several URIs over ONE connection by default — the same
  # shape h2load's -m N produces, and the only case here where many streams
  # share a single session through the drain.
  nghttp "${URLS[@]}" > "$WORK/out.0" 2> "$WORK/err.0"
  echo $? > "$WORK/rc.0"
  finish_server
  report "C  8 streams, 1 connection" 8 "$(count_ok "$WORK")" "$WORK/server.log" "$WORK"
fi
rm -rf "$WORK"

freeport || true

echo
echo "────────────────────────────────────────────────────────────────"
echo "$PASSES passed, $FAILURES failed, $VOIDS void"
echo
if [[ $VOIDS -gt 0 ]]; then
  echo "A void case measured nothing — do not read the totals above as data."
elif [[ $FAILURES -eq 0 ]]; then
  echo "All shapes delivered. The framework contract holds."
else
  echo "A shape lost replies. Before suspecting the provider: on WSL2, check"
  echo "that %USERPROFILE%\\.wslconfig has networkingMode=NAT — mirrored mode"
  echo "fails A and C ~100% of the time and is NOT a server defect."
  echo "Otherwise this is real; do not relax the gate."
fi

# Exit code = failures, so a suite can consume this. It used to exit 0
# unconditionally, which made it unusable as a gate.
exit $((FAILURES + VOIDS))
