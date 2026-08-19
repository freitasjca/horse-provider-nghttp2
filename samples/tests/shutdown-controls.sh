#!/usr/bin/env bash
# ============================================================================
#  shutdown-controls.sh — isolate the graceful-shutdown delivery failure
#
#  Why this exists
#  ───────────────
#  build-fpc.sh stage 6 fails: of 200 requests h2load starts, only ~133-163
#  are answered, while the server prints a clean drain verdict. Confirmed
#  100% reproducible (15/15 via repeat-shutdown.sh), with a NORMAL drain time
#  throughout (1808-1829 ms, spread 20) — so it is NOT the slow-drain flake
#  that repeat-shutdown.sh was written for.
#
#  Three explanations have already been falsified. Do not re-run them:
#    * NOT shedding — h2load reports `0 5xx`; nothing was answered with 503.
#    * NOT uncounted queue time — ExecutePipelineTrampoline calls
#      IncActiveRequests BEFORE FWorkerPool.Submit (Horse.Provider.Nghttp2.pas),
#      so SEC-30 does bracket queue time, exactly as documented.
#    * NOT a stream cap — MaxConcurrentStreams is 100 (Nghttp2.Server.pas),
#      and -c 4 -m 25 asks for 100.
#
#  The one hard fact left unexplained: `in flight at trigger` reads exactly
#  28 in every run, never varying. On this 28-core box that collides with the
#  worker count AND ProcessorCount, which is why cases 1 and 2 below pin it
#  down by forcing the pool to 8 and then 4 threads.
#
#  Baseline already established (control, not repeated here): the identical
#  load against a server with NO shutdown-after delivers 200/200 with zero
#  loss. The serving path is flawless; the failure is shutdown-specific.
#
#  The VOID guard is the point of this script
#  ──────────────────────────────────────────
#  A first, manual attempt at these controls produced four runs that looked
#  like clean data and were entirely worthless: an orphaned server held port
#  9010, each new server died with `fpBind :9010 failed (errno=98)`, and
#  h2load happily measured the ORPHAN. The tell was three cases returning
#  byte-identical output. So every case here is marked VOID unless its own
#  server is confirmed to have bound the port — a harness that reports a
#  passing number from the wrong process is worse than one that crashes.
#
#  THE pkill TRAP (this is what broke the manual attempt)
#  ──────────────────────────────────────────────────────
#  Linux truncates a process's `comm` to 15 characters (TASK_COMM_LEN).
#  `HorseNghttp2TestServer` is 22, so the kernel knows it as
#  `HorseNghttp2Tes` and `pkill -x HorseNghttp2TestServer` NEVER matches —
#  it exits 0 having killed nothing, and the orphan lives on. Every binary in
#  this directory is over the limit, so this applies to all of them.
#  (`HorseNghttp2TestClient` truncates to the SAME 15 chars as the server —
#  killing by truncated comm hits both. Harmless here, since the load
#  generator is h2load, but do not reuse the pattern blindly.)
#  Note also: `pkill -f HorseNghttp2TestServer` matches the caller's own
#  command line when invoked from a wrapper shell, killing the caller.
#  freeport() below avoids both traps and falls back to the port's real owner.
#
#  How to read the result
#  ──────────────────────
#    workers8 / workers4
#        in-flight-at-trigger 8 then 4 → the counter tracks worker occupancy,
#          i.e. only executing requests reach the drain despite the code
#          incrementing before Submit. That is the thread to pull.
#        stays 28 in all three → the number does not come from the pool at
#          all; move the search to the session layer.
#    late     shutdown fires after all 200 would have finished. Passing here
#             and failing at 3000 ms means only work outstanding AT THE
#             TRIGGER is lost — a drain problem, not a delivery problem.
#    m1       removes client-side stream queueing. Passing here implicates
#             multiplexed / pre-queued streams rather than delivery itself.
#    eventloop  is it driver-specific? The thread driver fails; IOCP passed
#             the equivalent test on Windows.
#
#  Usage:  bash shutdown-controls.sh          (run from samples/tests)
# ============================================================================
set -u

SERVER=./HorseNghttp2TestServer
PORT=9010

# The name the KERNEL knows, not the one on disk — see the pkill trap above.
SERVER_COMM="$(basename "$SERVER" | cut -c1-15)"

# ── Preconditions ───────────────────────────────────────────────────────────
[[ -x "$SERVER" ]] || {
  echo "ERROR: $SERVER not found or not executable." >&2
  echo "       Run this from samples/tests; build-fpc.sh leaves the binary here." >&2
  exit 1
}
command -v h2load > /dev/null 2>&1 || {
  echo "ERROR: h2load not installed (apt install nghttp2-client)." >&2
  exit 1
}
command -v ss > /dev/null 2>&1 || {
  echo "ERROR: ss not available; the VOID guard cannot verify the port." >&2
  exit 1
}

VOIDS=0
FAILURES=0
PASSES=0

port_bound() { ss -ltn 2>/dev/null | grep -q ":$PORT "; }

# Free the port, or say why it could not be freed. Never assume pkill worked.
freeport() {
  local i pids

  pkill -x "$SERVER_COMM" 2>/dev/null || true
  for i in $(seq 60); do
    port_bound || return 0
    sleep 0.1
  done

  # Still bound. Go after whoever actually holds it rather than guessing at
  # names — this is the authoritative answer and it survives any renaming.
  pids=$(ss -ltnp 2>/dev/null | grep ":$PORT " \
         | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ')
  if [[ -n "${pids// /}" ]]; then
    kill -TERM $pids 2>/dev/null || true
    sleep 1
    kill -KILL $pids 2>/dev/null || true
  fi

  for i in $(seq 60); do
    port_bound || return 0
    sleep 0.1
  done

  echo "ERROR: port $PORT still bound by pid(s): ${pids:-unknown}" >&2
  return 1
}

runcase() {
  local name=$1 m=$2; shift 2
  local log=/tmp/ctl-$name.log
  local srv started succeeded inflight drain

  if ! freeport; then
    echo "!! $name VOID — port busy"; echo
    VOIDS=$((VOIDS + 1)); return 1
  fi

  "$SERVER" "$@" < /dev/null > "$log" 2>&1 &
  srv=$!
  sleep 1.0

  # Two independent checks: the bind message, and the process still existing.
  # Either alone can miss — a bind failure races the sleep, and a process can
  # die for reasons that never mention fpBind.
  if grep -q 'fpBind' "$log" 2>/dev/null; then
    echo "!! $name VOID — bind failed (orphan holds the port)"; echo
    VOIDS=$((VOIDS + 1)); return 1
  fi
  if ! kill -0 "$srv" 2>/dev/null; then
    echo "!! $name VOID — server exited at startup:"
    tail -3 "$log" | sed 's/^/    | /'; echo
    VOIDS=$((VOIDS + 1)); return 1
  fi

  echo "── $name ──   args: $*   |   h2load -m $m"

  timeout 90 h2load -n 200 -c 4 -m "$m" "http://127.0.0.1:$PORT/slow/500" \
    < /dev/null > "/tmp/ctl-$name-h2load.log" 2>&1 || true

  # Shutdown cases self-terminate; a case without shutdown-after will not, so
  # do not inherit a hang either way.
  if ! timeout 40 tail --pid="$srv" -f /dev/null 2>/dev/null; then
    kill -TERM "$srv" 2>/dev/null || true
  fi
  wait "$srv" 2>/dev/null

  started=$(grep -oE '[0-9]+ started'   "/tmp/ctl-$name-h2load.log" | grep -oE '^[0-9]+' | head -1)
  succeeded=$(grep -oE '[0-9]+ succeeded' "/tmp/ctl-$name-h2load.log" | grep -oE '^[0-9]+' | head -1)
  started="${started:-0}"; succeeded="${succeeded:-0}"

  inflight=$(grep -oE 'in flight at trigger: [0-9]+' "$log" | grep -oE '[0-9]+' | head -1)
  drain=$(grep -oE 'returned after: [0-9]+ ms'       "$log" | grep -oE '[0-9]+' | head -1)

  grep -E 'requests:|status codes:' "/tmp/ctl-$name-h2load.log" | sed 's/^/    /'
  printf '    in-flight-at-trigger %-4s drain %-7s ' \
    "${inflight:-n/a}" "${drain:-n/a}ms"

  # 0 5xx distinguishes SEVERED from SHED. Without that line a non-2xx run
  # reads as data loss when the server may have answered every request.
  if [[ "$started" -gt 0 && "$started" == "$succeeded" ]]; then
    echo "→ ok ($succeeded/$started answered)"
    PASSES=$((PASSES + 1))
  else
    echo "→ *** DELIVERY FAILURE *** ($succeeded/$started answered)"
    FAILURES=$((FAILURES + 1))
  fi
  echo
}

echo "shutdown-controls — isolating the stage-6 delivery failure"
echo "  load: h2load -n 200 -c 4 -m <M> http://127.0.0.1:$PORT/slow/500"
echo "  each case is VOID unless its OWN server bound the port"
echo

runcase workers8   25 workers=8 shutdown-after=3000 shutdown-timeout=10000
runcase workers4   25 workers=4 shutdown-after=3000 shutdown-timeout=10000
runcase late       25           shutdown-after=8000 shutdown-timeout=10000
runcase m1          1           shutdown-after=3000 shutdown-timeout=10000
runcase eventloop  25 eventloop shutdown-after=3000 shutdown-timeout=10000
runcase w8-long    25 workers=8 shutdown-after=3000 shutdown-timeout=60000
runcase w4-long    25 workers=4 shutdown-after=3000 shutdown-timeout=60000

freeport || true

echo "────────────────────────────────────────────────────────────────"
echo "cases: $PASSES ok, $FAILURES delivery failure(s), $VOIDS void"
if [[ $VOIDS -gt 0 ]]; then
  echo
  echo "NOTE: $VOIDS case(s) VOID — those numbers do not exist. A void case"
  echo "      means the port was held by something else; nothing was measured."
fi
echo
echo "Reading it: workers8/workers4 reporting in-flight 8 then 4 means the"
echo "drain only sees EXECUTING requests. All three reporting 28 means the"
echo "number is not the pool's, and the session layer is next."
exit 0
