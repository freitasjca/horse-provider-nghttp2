#!/usr/bin/env bash
# =============================================================================
#  build-fpc.sh
#  FPC/Linux build + run for the nghttp2 provider after the async-dispatch
#  work (2026-08). Everything here has only ever been through dcc64 on
#  Windows; this script exists to put the FPC/Unix code paths in front of a
#  compiler for the first time.
#
#  The highest-risk file is Nghttp2.Socket.pas. Its SocketWaitReadable has
#  four compiler branches and only the Windows one has ever been compiled —
#  and that one shipped a bug (FD_SET is a record TYPE in stock
#  Winapi.WinSock2, so FD_SET(sock,set) parsed as a typecast → E2029). The
#  FPC/Unix branch calls fpFD_ZERO/fpFD_SET/fpSelect, copied verbatim from
#  Delphi-Cross-Socket's shipped FPC branch, so it should be sound — but
#  "should" is what the Windows branch had going for it too.
#
#  Stages run in order of narrowing scope, so a failure names its own cause
#  instead of arriving as a wall of errors from a whole-program build:
#
#    1  Nghttp2.Socket   alone   — the select() branch, in isolation
#    2  Session + Server alone   — deferred submit, GOAWAY, drain bookkeeping
#       + Nghttp2.Engine.Epoll   — nothing references it, so it is only ever
#                                  compiled because this stage names it
#    3  test server              — full provider + Horse
#    4  test client              — the 94-check suite binary
#    5  run 94-check suite                        (thread driver, h2c)
#    6  run graceful-shutdown test (needs h2load)
#    7  connection-thread leak growth
#    8  two-stage GOAWAY frame trace
#    9  94-check suite over TLS
#   10  94-check suite over mTLS, positive + negative
#   11  gRPC over h2c
#   12  94-check suite via the epoll EVENT LOOP   (h2c)
#   13  94-check suite over TLS via the EVENT LOOP  (B4d: handshake driven by
#       HandshakeStep from RunOnce, reads via ReadNB, writes via WriteNB)
#   14  94-check suite over mTLS via the EVENT LOOP, positive AND negative —
#       the negative is the one that matters: a resumable handshake that
#       wrongly SUCCEEDS passes every positive check ever written
#
#  Stages 1-11 all exercise the thread-per-connection driver. Stage 12 is the
#  only one that executes the epoll engine, and it fails rather than passes if
#  the engine turns out to be unavailable — a silent fallback there would
#  report green for code that never ran.
#
#  Usage:
#    cd patches/horse-provider-nghttp2/samples/tests
#    bash build-fpc.sh                # compile + run
#    bash build-fpc.sh --compile-only # stages 1-4 only
#
#  Environment:
#    TRUNK_FPC    path to the fpc binary   (default /usr/local/fpc-trunk/bin/fpc)
#    TRUNK_UNITS  path to its unit tree    (default .../units/x86_64-linux)
#
#  Exit code = number of failed stages. 0 = all good.
# =============================================================================

set -uo pipefail

TRUNK=${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}
TU=${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../../" && pwd)"
PROV="$ROOT/patches/horse-provider-nghttp2/src"
DNG="$ROOT/patches/Delphi-nghttp2/src"
HORSE="$ROOT/horse/src"

COMPILE_ONLY=0
[[ "${1:-}" == "--compile-only" ]] && COMPILE_ONLY=1

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

# ── Toolchain check ──────────────────────────────────────────────────────────
if [[ ! -x "$TRUNK" ]]; then
  echo "ERROR: fpc not found at $TRUNK" >&2
  echo "       Set TRUNK_FPC (and TRUNK_UNITS) to your install." >&2
  exit 2
fi

FPCVER=$("$TRUNK" -iV 2>/dev/null)
echo "FPC:    $TRUNK  (version $FPCVER)"
echo "Units:  $TU"
echo "Source: $DNG"
echo "        $PROV"
echo "        $HORSE"
# 3.2.2 lacks TCustomAttribute in Rtti, which the gRPC registry needs. Plain
# HTTP/2 is documented to work on 3.2.2, so this is a warning rather than a
# hard stop — but an attribute-related error below means this is why.
case "$FPCVER" in
  3.2.*) echo "WARN:   3.2.x — gRPC units need trunk 3.3.1; plain HTTP/2 should still build." ;;
esac
echo

# -dHORSE_GRPC_NO_FFI: nothing here exercises gRPC dispatch, and the define
# drops the ffi.manager dependency so the build does not also require libffi.
FLAGS="-n -MDelphi -O1 -gl -dHORSE_PROVIDER_NGHTTP2 -dHORSE_GRPC_NO_FFI \
  -Fu. -Fu$PROV -Fu$DNG -Fu$HORSE \
  -Fu$TU/rtl -Fu$TU/rtl-console -Fu$TU/rtl-objpas -Fu$TU/rtl-extra \
  -Fu$TU/rtl-generics -Fu$TU/fcl-base -Fu$TU/fcl-web -Fu$TU/fcl-json \
  -Fu$TU/regexpr -Fu$TU/pthreads -Fu$TU/openssl -Fu$TU/fcl-net -Fu$TU/hash"

WORK=$(mktemp -d)

# Every server this script launches, so an interrupt cannot leave one running.
# An orphaned server holds the port and answers the next run's traffic, which
# then reads as "client fine, server failed to bind" — a genuinely confusing
# way to lose an afternoon.
SERVERS=()

cleanup() {
  local pid
  for pid in "${SERVERS[@]:-}"; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done
  # Keep the logs when anything failed — deleting them is exactly the moment
  # you need them, and a failing stage with no evidence costs another run.
  if [[ $FAIL -eq 0 ]]; then
    rm -rf "$WORK"
  else
    echo
    echo "Logs kept for diagnosis: $WORK"
    ls -1 "$WORK"/*.log 2>/dev/null | sed 's/^/  /'
  fi
}
trap cleanup EXIT INT TERM
# -FU sends every .ppu/.o to a scratch directory. FPC will happily reuse a
# cached .ppu built with different -d flags — a stale unit silently linking
# the wrong provider is a trap this repo has hit before — and a fresh temp
# dir per run makes that impossible without touching the checkout.
OUT="-FU$WORK"

cd "$SCRIPT_DIR"

PORT=9010
TLS_PORT=9443
GRPC_PORT=18020
GRPC="$(cd "$SCRIPT_DIR/../grpc" 2>/dev/null && pwd)" || GRPC=""

# Both run stages bind the same hardcoded port, so the second must not start
# until the first has actually let go of it. Without this the stage-6 server
# can lose the bind, exit 1, and leave h2load talking to the stage-5 server
# that is still shutting down — which reads as "client fine, server failed".
port_in_use() {      # <port> — 0 if something is listening
  timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

wait_port_free() {   # <port> <timeout-seconds>
  local port=$1 deadline=$((SECONDS + $2))
  while (( SECONDS < deadline )); do
    port_in_use "$port" || return 0
    sleep 0.2
  done
  return 1
}

# Deliberately reports rather than kills. These binaries get run by hand all
# the time during development, and silently killing a server someone is
# using would be a worse failure than the one it prevents.
require_port_free() {   # <port>
  port_in_use "$1" || return 0
  echo
  echo "ERROR: something is already listening on 127.0.0.1:$1" >&2
  ss -ltnp 2>/dev/null | grep ":$1 " | sed 's/^/       /' >&2
  echo "       Usually an orphaned HorseNghttp2TestServer from an interrupted" >&2
  echo "       run. It will answer this run's traffic while the server started" >&2
  echo "       here fails to bind, which reads as a server fault that is not one." >&2
  echo "       Clear it with:  pkill -f HorseNghttp2TestServer" >&2
  return 1
}

# run_client_suite <logname> <label> <target-url> [extra client args...]
# The 94-check client against one endpoint. Same everywhere, so the TLS and
# mTLS stages differ only in their arguments.
run_client_suite() {
  local logname=$1 label=$2 target=$3
  shift 3
  if timeout 120 ./HorseNghttp2TestClient "$target" "$@" \
       < /dev/null > "$WORK/$logname.log" 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
  grep -E "passed, .* failed" "$WORK/$logname.log" | tail -1 | sed 's/^/    /'
}

compile_unit() {   # <label> <source-path>
  # Separate statements on purpose. In a single `local a=$1 b=$2 c="...$b..."`
  # bash expands every word before the builtin runs, so $b is still unset when
  # c is built — which under `set -u` prints "unbound variable" and leaves all
  # logs sharing one filename.
  local label=$1
  local src=$2
  local log="$WORK/$(basename "$src").log"
  echo "  compiling $label ..."
  if $TRUNK $FLAGS $OUT "$src" > "$log" 2>&1; then
    pass "$label"
    return 0
  fi
  fail "$label"
  echo "  ── first errors ─────────────────────────────────────────────"
  grep -E "Error|Fatal" "$log" | head -12 | sed 's/^/    /'
  echo "  ── full log: $log ───────────────────────────────────────────"
  return 1
}

# ── 1 · the select() branch, alone ───────────────────────────────────────────
echo "── 1  Nghttp2.Socket (SocketWaitReadable FPC/Unix branch) ──────────────"
if ! compile_unit "Nghttp2.Socket.pas" "$DNG/Nghttp2.Socket.pas"; then
  echo
  echo "  This is the branch that has never been compiled. Check the uses"
  echo "  clause first: the FPC/Unix path needs BaseUnix alongside Sockets"
  echo "  for fpSelect/fpFD_ZERO/fpFD_SET/TFDSet/TTimeVal."
  echo
  echo "Stages: $PASS passed, $FAIL failed"
  exit $FAIL
fi

# ── 2 · async transport core, alone ──────────────────────────────────────────
echo
echo "── 2  Nghttp2.Session + Nghttp2.Server (async dispatch core) ───────────"
compile_unit "Nghttp2.Session.pas" "$DNG/Nghttp2.Session.pas" || true
compile_unit "Nghttp2.Server.pas"  "$DNG/Nghttp2.Server.pas"  || true

# The epoll engine is reachable from NOTHING by design — Nghttp2.Server holds
# only a function pointer, so linking the unit is what enables it. That also
# means no program here drags it in, and without this line it would never be
# compiled at all. Compile it explicitly or it rots.
compile_unit "Nghttp2.Engine.Epoll.pas" "$DNG/Nghttp2.Engine.Epoll.pas" || true
  # The IOCP engine is Windows-only and compiles to an EMPTY unit here. That is
  # exactly why it is named: an empty unit still has to be a valid one, and a
  # broken {$IF DEFINED(MSWINDOWS)} guard would otherwise go unnoticed on the
  # compiler that runs most often. Same reason stage 2 names the epoll unit at
  # all — nothing references either, so an unnamed engine is never compiled.
  compile_unit "Nghttp2.Engine.Iocp.pas" "$DNG/Nghttp2.Engine.Iocp.pas" || true

# ── 3 / 4 · whole programs ───────────────────────────────────────────────────
echo
echo "── 3  HorseNghttp2TestServer ───────────────────────────────────────────"
SERVER_OK=0
compile_unit "HorseNghttp2TestServer.dpr" "HorseNghttp2TestServer.dpr" && SERVER_OK=1

echo
echo "── 4  HorseNghttp2TestClient ───────────────────────────────────────────"
CLIENT_OK=0
compile_unit "HorseNghttp2TestClient.dpr" "HorseNghttp2TestClient.dpr" && CLIENT_OK=1

if [[ $COMPILE_ONLY -eq 1 ]]; then
  echo
  echo "Stages: $PASS passed, $FAIL failed  (--compile-only)"
  exit $FAIL
fi

if [[ $SERVER_OK -eq 0 || $CLIENT_OK -eq 0 ]]; then
  echo
  echo "Skipping run stages — a program failed to build."
  echo "Stages: $PASS passed, $FAIL failed"
  exit $FAIL
fi

# ── 5 · the 94-check suite ───────────────────────────────────────────────────
echo
echo "── 5  94-check suite (h2c) ─────────────────────────────────────────────"
# </dev/null on every binary: these test programs end with a
# "Press ENTER to exit..." ReadLn, which parks the script forever when they
# inherit the terminal. EOF makes that read return immediately.
# timeout: a hang must fail the stage, not the run.
if ! require_port_free "$PORT"; then
  fail "94-check suite (port $PORT occupied before we started)"
  echo
  echo "Stages: $PASS passed, $FAIL failed"
  exit $FAIL
fi

stdbuf -o0 -e0 ./HorseNghttp2TestServer < /dev/null > "$WORK/server.log" 2>&1 &
SRV=$!
SERVERS+=("$SRV")
sleep 0.6

if timeout 120 ./HorseNghttp2TestClient < /dev/null > "$WORK/client.log" 2>&1; then
  pass "94-check suite"
elif [[ $? -eq 124 ]]; then
  fail "94-check suite (timed out after 120s)"
else
  fail "94-check suite"
fi
grep -E "passed, .* failed" "$WORK/client.log" | tail -1 | sed 's/^/    /'
kill -TERM "$SRV" 2>/dev/null || true
wait "$SRV" 2>/dev/null || true

if ! wait_port_free "$PORT" 15; then
  echo "    WARN  port $PORT still bound after 15s — stage 6 may fail to bind"
fi

# ── 6 · graceful shutdown under load ─────────────────────────────────────────
echo
echo "── 6  graceful shutdown under load ─────────────────────────────────────"
if ! command -v h2load > /dev/null 2>&1; then
  echo "  SKIP  h2load not installed (apt install nghttp2-client)"
else
  stdbuf -o0 -e0 ./HorseNghttp2TestServer shutdown-after=3000 shutdown-timeout=10000 \
    < /dev/null > "$WORK/shutdown.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  sleep 0.6

  # Confirm THIS server owns the port before loading it. Without the check a
  # failed bind is invisible here: h2load happily talks to whatever else is
  # listening and reports a perfect run, while the exit code comes from a
  # process that died at startup.
  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "shutdown server exited at startup — see log below"
    tail -4 "$WORK/shutdown.log" | sed 's/^/    | /'
    echo
    echo "Stages: $PASS passed, $FAIL failed"
    exit $FAIL
  fi

  # The delivery WITNESSES — plural, and that is the point.
  #
  # A single witness is one sample against a coin-flip race, so it passes
  # about half the time and this stage reported 21/21 while graceful shutdown
  # was losing ~50% of in-flight replies. A green suite over a broken feature
  # is worse than no suite: it stops anyone looking.
  #
  # A shutdown happens once per server lifecycle, so the race cannot be
  # sampled by repeating the stage without restarting. It CAN be sampled
  # across connections in the SAME drain — verify-drain-delivery's 4-connection
  # case loses 1-2 of 4 consistently — so four concurrent witnesses give four
  # draws for one shutdown, and ALL four must be delivered.
  #
  # /slow/5000 against a 3000 ms trigger leaves every one of them genuinely in
  # flight when the drain begins.
  #
  # EIGHT, not four: a clean draw happens often enough that four witnesses
  # still let this stage pass roughly one run in five over a broken feature.
  # Each witness is an independent draw against a ~50% per-connection race, so
  # eight makes an all-clean run rare enough that a PASS means something.
  WITNESSES=8
  WITPIDS=()
  NGWIT=""
  if command -v nghttp > /dev/null 2>&1; then
    for w in $(seq $WITNESSES); do
      ( timeout 60 nghttp http://127.0.0.1:9010/slow/5000 \
          > "$WORK/witness.$w.log" 2>&1; echo $? > "$WORK/witness.$w.rc" ) &
      WITPIDS+=($!)
    done
    NGWIT=yes
    sleep 0.3
  fi

  timeout 60 h2load -n 200 -c 4 -m 25 http://127.0.0.1:9010/slow/500 \
    < /dev/null > "$WORK/h2load.log" 2>&1 || true

  # Only the witness jobs. A bare `wait` would also reap the server, and the
  # `wait "$SRV"` below would then return 127 — reported as a drain failure
  # that never happened.
  for _p in "${WITPIDS[@]:-}"; do
    [[ -n "$_p" ]] && wait "$_p" 2>/dev/null
  done

  # The server self-terminates via its own StopListenGraceful. If a defect
  # parks it there instead, do not inherit the hang — kill and fail.
  if ! timeout 60 tail --pid="$SRV" -f /dev/null 2>/dev/null; then
    kill -TERM "$SRV" 2>/dev/null || true
  fi
  wait "$SRV" 2>/dev/null
  SHUT_EXIT=$?

  # ── Why the gate is an nghttp witness, not h2load's own counters ──
  #
  # This stage used to assert `h2load started == succeeded`, and it failed on
  # every run for days while the server was behaving correctly.
  #
  # h2load counts a request "started" when it hands it to its OWN session, and
  # it abandons outstanding streams the moment the graceful GOAWAY notice
  # arrives — it printed `finished in 3.00s` against a t=3000 trigger, every
  # time. So that comparison measures the load generator's reaction to a
  # shutdown, not whether the server delivered.
  #
  # Measured head-to-head, 10 runs each, identical server/route/trigger:
  # nghttp   10 pass / 0 fail
  # curl 7.81 4 pass / 6 fail
  # A ~60% server-side race would have caught nghttp too (p ~ 1e-4 for 0/10),
  # and an `nghttp -v` frame trace showed a byte-perfect RFC 9113 §6.8
  # exchange: notice GOAWAY(2^31-1), the in-flight stream finishing, a final
  # GOAWAY whose last_stream_id COVERS it, then HEADERS + DATA/END_STREAM.
  # curl 7.81 mishandles the graceful notice; that is a client defect and it
  # must not fail this suite.
  #
  # So: h2load still runs, purely to put a real backlog under the drain, and
  # its counters are reported as INFORMATION. The pass/fail comes from a
  # conforming client that was mid-request across the trigger.
  STARTED=$(grep -oE '[0-9]+ started' "$WORK/h2load.log" | grep -oE '^[0-9]+' || echo 0)
  SUCCEEDED=$(grep -oE '[0-9]+ succeeded' "$WORK/h2load.log" | grep -oE '^[0-9]+' || echo 0)
  SHED=$(grep -oE '[0-9]+ 5xx' "$WORK/h2load.log" | grep -oE '^[0-9]+' || echo 0)

  WIT_OK=0
  WIT_BAD=""
  if [[ -n "$NGWIT" ]]; then
    for w in $(seq $WITNESSES); do
      rc=$(cat "$WORK/witness.$w.rc" 2>/dev/null || echo "?")
      # rc=0 alone is NOT delivery: nghttp exits 0 while printing
      # "Some requests were not processed". Assert the complete body.
      if [[ "$rc" == "0" ]] && grep -q '"sleptMs":5000' "$WORK/witness.$w.log" 2>/dev/null; then
        WIT_OK=$((WIT_OK + 1))
      else
        WIT_BAD="$WIT_BAD $w(rc=$rc)"
      fi
    done
  fi

  # INFORMATIONAL. h2load's own counters are a load report, not a verdict —
  # see the block above for why they cannot be one.
  echo "    load (informational): h2load started=$STARTED succeeded=$SUCCEEDED 5xx=$SHED"
  echo "    witnesses: $WIT_OK/$WITNESSES delivered${WIT_BAD:+  failed:$WIT_BAD}"

  if [[ "$SHUT_EXIT" -ne 0 ]]; then
    fail "server-side drain (exit $SHUT_EXIT — deadline hit or requests stranded)"
  elif [[ -z "$NGWIT" ]]; then
    # No witness means no gate. Refuse to report a pass rather than degrading
    # to "the server did not crash", which is what this stage checked before.
    fail "graceful shutdown — no nghttp witness (install nghttp2-client); stage cannot verify delivery"
  elif [[ "$WIT_OK" -eq "$WITNESSES" ]]; then
    # WEAK GATE, and it must say so. h2load's /slow/500 connections finish
    # continuously while these witnesses run /slow/5000, so an h2load
    # connection is always the FIRST to finish during the drain, and these
    # witnesses never are. Any failure mode that only bites the
    # first-to-finish connection is therefore invisible here — one such mode
    # (WSL2 mirrored networking) cost this investigation days precisely
    # because this stage stayed green through it. Stage 6b uses the
    # single-connection shapes that see it.
    pass "graceful shutdown — all $WITNESSES in-flight requests delivered (weak gate, see stage 6b)"
  else
    fail "graceful shutdown — $((WITNESSES - WIT_OK))/$WITNESSES in-flight request(s) never delivered"
  fi

  # Shedding is a separate property and gets its own line rather than being
  # folded into the delivery verdict: a 503 is an ANSWER, and conflating it
  # with a severed reply is the error that made the old gate unreadable.
  if [[ "$SHED" -gt 0 ]]; then
    echo "    NOTE: $SHED request(s) shed with 5xx under load (backpressure, not loss)"
  fi
fi


# ── 6b · graceful-shutdown delivery, in the shapes stage 6 cannot see ────────
echo
echo "── 6b  graceful-shutdown delivery (single-connection shapes) ───────────"
if [[ ! -x ./verify-drain-delivery.sh ]] && [[ ! -f ./verify-drain-delivery.sh ]]; then
  echo "  SKIP  verify-drain-delivery.sh not present"
elif ! command -v nghttp > /dev/null 2>&1; then
  echo "  SKIP  nghttp not installed (apt install nghttp2-client)"
else
  # Stage 6's witnesses are never the first connection to finish, so they miss
  # this. These shapes are: 1 request, 4 concurrent on 4 connections, and 8
  # streams on 1 connection — each with the request genuinely in flight when
  # the drain starts, and no competing load to finish ahead of them.
  #
  # If this stage fails on WSL2, check the networking mode BEFORE suspecting
  # the provider: `networkingMode=mirrored` injects an RST at the sequence
  # numbers the client has just ACKed, and these shapes fail ~100% under it
  # while stage 6 stays green. `networkingMode=NAT` in %USERPROFILE%\.wslconfig
  # plus `wsl --shutdown` is the fix. See
  # plans/HANDOFF-nghttp2-shutdown-2026-08-18.md — that artifact was diagnosed
  # as a provider defect for two days.
  if bash ./verify-drain-delivery.sh > "$WORK/drain-delivery.log" 2>&1; then
    grep -E '^  [ABC] |passed,' "$WORK/drain-delivery.log" | sed 's/^/    /'
    pass "graceful-shutdown delivery — all shapes delivered"
  else
    grep -E '^  [ABC] |passed,' "$WORK/drain-delivery.log" | sed 's/^/    /'
    fail "graceful-shutdown delivery — in-flight replies lost (if WSL2: check networkingMode)"
  fi
fi

# ── 7 · connection-thread leak check ─────────────────────────────────────────
# Connection threads used to be created FreeOnTerminate:=False and freed only
# by Stop, from a list each thread removed itself from on the way out — so
# every connection that closed NORMALLY leaked its TThread object and thread
# stack. Nothing in stages 5 and 6 can see that: both pass identically with
# the leak present, which is how it survived this long.
#
# Measured as growth across many short-lived connections, after a warm-up so
# the context pool and worker pool have reached steady state (both grow
# legitimately at first — the pool is capped at 512 contexts).
echo
echo "── 7  connection-thread leak check ─────────────────────────────────────"
if ! command -v h2load > /dev/null 2>&1; then
  echo "  SKIP  h2load not installed (apt install nghttp2-client)"
elif ! wait_port_free "$PORT" 15; then
  echo "  SKIP  port $PORT still bound after stage 6"
else
  LEAK_ROUNDS=${LEAK_ROUNDS:-20}
  LEAK_CONNS=${LEAK_CONNS:-50}
  # Generous by design: this is looking for growth proportional to 1000
  # leaked thread stacks, not for allocator noise. A real leak here is
  # hundreds of MB, so a threshold this loose still catches it while never
  # firing on ordinary heap churn.
  LEAK_MAX_KB=${LEAK_MAX_KB:-32768}

  stdbuf -o0 -e0 ./HorseNghttp2TestServer < /dev/null > "$WORK/leak.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  sleep 0.6

  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "leak check — server exited at startup"
    tail -4 "$WORK/leak.log" | sed 's/^/    | /'
  else
    # Warm-up: let the pools settle so their legitimate growth is not counted.
    timeout 60 h2load -n 200 -c "$LEAK_CONNS" "http://127.0.0.1:$PORT/ping" \
      < /dev/null > /dev/null 2>&1 || true

    read -r RSS0 NLWP0 <<< "$(ps -o rss=,nlwp= -p "$SRV" 2>/dev/null)"

    for _ in $(seq 1 "$LEAK_ROUNDS"); do
      timeout 60 h2load -n 100 -c "$LEAK_CONNS" "http://127.0.0.1:$PORT/ping" \
        < /dev/null > /dev/null 2>&1 || true
    done

    read -r RSS1 NLWP1 <<< "$(ps -o rss=,nlwp= -p "$SRV" 2>/dev/null)"

    CONNS=$(( LEAK_ROUNDS * LEAK_CONNS ))
    if [[ -z "${RSS0:-}" || -z "${RSS1:-}" ]]; then
      fail "leak check — could not read process stats"
    else
      DRSS=$(( RSS1 - RSS0 ))
      DNLWP=$(( NLWP1 - NLWP0 ))
      echo "    $CONNS connections opened and closed"
      echo "    RSS   ${RSS0} -> ${RSS1} KB   (delta ${DRSS} KB)"
      echo "    threads ${NLWP0} -> ${NLWP1}     (delta ${DNLWP})"
      if [[ "$DRSS" -lt "$LEAK_MAX_KB" ]]; then
        pass "no connection-thread leak (< ${LEAK_MAX_KB} KB growth)"
      else
        fail "possible leak — RSS grew ${DRSS} KB over $CONNS connections"
      fi
    fi
    kill -TERM "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
  fi
fi

# ── 8 · two-stage GOAWAY on the wire ─────────────────────────────────────────
# RFC 9113 §6.8 shutdown is two frames: an open-ended notice
# (last_stream_id = 2^31-1) telling the peer to stop opening streams, then a
# definitive one naming the last stream actually processed. Only the second
# lets a client tell a request that was served from one it must replay.
#
# Nothing else here can see this. Every other stage passes identically when
# stage 2 is missing — they did, before it existed. So this reads the frames.
echo
echo "── 8  two-stage GOAWAY (RFC 9113 §6.8) ─────────────────────────────────"
if ! command -v nghttp > /dev/null 2>&1; then
  echo "  SKIP  nghttp not installed (apt install nghttp2-client)"
elif ! wait_port_free "$PORT" 15; then
  echo "  SKIP  port $PORT still bound after stage 7"
else
  # The request must outlive the shutdown trigger, so the connection is live
  # when stage 1 arrives and still owed a response when stage 2 follows.
  stdbuf -o0 -e0 ./HorseNghttp2TestServer shutdown-after=2500 shutdown-timeout=15000 \
    < /dev/null > "$WORK/goaway-server.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  sleep 0.6

  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "GOAWAY check — server exited at startup"
    tail -4 "$WORK/goaway-server.log" | sed 's/^/    | /'
  else
    timeout 60 nghttp -v "http://127.0.0.1:$PORT/slow/4000" \
      < /dev/null > "$WORK/goaway.log" 2>&1 || true
    wait "$SRV" 2>/dev/null || true

    # nghttp -v puts the frame header and its fields on separate lines, so
    # collect the ids rather than trying to match a single line.
    # Plain array assignment rather than mapfile: these are bare integers, so
    # word splitting is safe, and it works on bash 3.2 (macOS) too.
    GIDS=( $(grep -oE 'last_stream_id=[0-9]+' "$WORK/goaway.log" | sed 's/.*=//') )

    echo "    GOAWAY frames seen: ${#GIDS[@]}  ids: ${GIDS[*]:-none}"
    if [[ "${#GIDS[@]}" -lt 2 ]]; then
      fail "two-stage GOAWAY — expected 2 frames, saw ${#GIDS[@]}"
      echo "    (stage 2 is not reaching the wire)"
    elif [[ "${GIDS[0]}" != "2147483647" ]]; then
      fail "two-stage GOAWAY — first frame should be open-ended (2147483647), got ${GIDS[0]}"
    elif [[ "${GIDS[1]}" == "2147483647" ]]; then
      fail "two-stage GOAWAY — second frame still open-ended; terminate_session did not name a real stream"
    else
      pass "two-stage GOAWAY — notice 2147483647 then cutoff ${GIDS[1]}"
    fi
  fi
fi

# ── 9 · TLS ──────────────────────────────────────────────────────────────────
# No rebuild: TLS is a runtime choice, so the binaries from stages 3 and 4
# serve it unchanged. Only the certs and libssl need to be present.
echo
echo "── 9  94-check suite over TLS ──────────────────────────────────────────"
if [[ ! -f tls/cert.pem || ! -f tls/key.pem ]]; then
  echo "  SKIP  tls/cert.pem or tls/key.pem missing — run: bash gen-tls-cert.sh"
elif ! wait_port_free "$TLS_PORT" 15; then
  echo "  SKIP  port $TLS_PORT still bound by:"
  ss -ltnp 2>/dev/null | grep ":$TLS_PORT " | sed 's/^/        /'
  echo "        Nothing here binds it — clear it with: pkill -f HorseNghttp2TestServer"
else
  stdbuf -o0 -e0 ./HorseNghttp2TestServer tls < /dev/null > "$WORK/tls-server.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  sleep 0.8
  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "TLS server exited at startup"
    tail -4 "$WORK/tls-server.log" | sed 's/^/    | /'
  else
    run_client_suite tls-client "94-check suite over TLS" "https://127.0.0.1:$TLS_PORT"
  fi
  kill -TERM "$SRV" 2>/dev/null || true
  wait "$SRV" 2>/dev/null || true
fi

# ── 10 · mTLS, both directions ───────────────────────────────────────────────
# Positive first, deliberately. It proves the server is up and the certs are
# good, so the negative run that follows can only be failing for the reason
# under test. Reversed, a negative "pass" would also be produced by a server
# that never started.
echo
echo "── 10  94-check suite over mTLS (positive + negative) ──────────────────"
if [[ ! -f tls/ca.pem || ! -f tls/client-cert.pem || ! -f tls/client-key.pem ]]; then
  echo "  SKIP  tls/ca.pem or client cert/key missing — run: bash gen-tls-cert.sh"
elif ! wait_port_free "$TLS_PORT" 15; then
  echo "  SKIP  port $TLS_PORT still bound by:"
  ss -ltnp 2>/dev/null | grep ":$TLS_PORT " | sed 's/^/        /'
  echo "        Nothing here binds it — clear it with: pkill -f HorseNghttp2TestServer"
else
  stdbuf -o0 -e0 ./HorseNghttp2TestServer mtls < /dev/null > "$WORK/mtls-server.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  sleep 0.8
  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "mTLS server exited at startup"
    tail -4 "$WORK/mtls-server.log" | sed 's/^/    | /'
  else
    run_client_suite mtls-client "mTLS positive (client cert presented)" \
      "https://127.0.0.1:$TLS_PORT" \
      --client-cert tls/client-cert.pem --client-key tls/client-key.pem

    # Negative: the same client with no certificate must be refused at the
    # TLS handshake. A clean run here would mean the server is not enforcing.
    if timeout 120 ./HorseNghttp2TestClient "https://127.0.0.1:$TLS_PORT" \
         < /dev/null > "$WORK/mtls-negative.log" 2>&1; then
      fail "mTLS negative — uncertified client was ACCEPTED"
    else
      pass "mTLS negative — uncertified client refused"
    fi
  fi
  kill -TERM "$SRV" 2>/dev/null || true
  wait "$SRV" 2>/dev/null || true
fi

# ── 11 · gRPC over h2c ───────────────────────────────────────────────────────
# Built separately from every other stage: the demo registers via
# RegisterService<IGreeter>, which dispatches through TRttiMethod.Invoke, and
# FPC routes that through ffi.manager. So -dHORSE_GRPC_NO_FFI must be OFF and
# the libffi units must be on the search path — the opposite of the flags the
# HTTP stages use, where dropping ffi keeps the build free of libffi entirely.
echo
echo "── 11  gRPC over h2c ───────────────────────────────────────────────────"
if [[ -z "$GRPC" || ! -f "$GRPC/HorseNghttp2GrpcDemo.dpr" ]]; then
  echo "  SKIP  samples/grpc not found next to this directory"
elif [[ ! -d "$TU/libffi" ]]; then
  echo "  SKIP  libffi units not in this FPC install ($TU/libffi)"
  echo "        RegisterService<T> needs them; rebuild FPC with the libffi package."
elif ! wait_port_free "$GRPC_PORT" 15; then
  echo "  SKIP  port $GRPC_PORT still bound by:"
  ss -ltnp 2>/dev/null | grep ":$GRPC_PORT " | sed 's/^/        /'
  echo "        Clear it with: pkill -f HorseNghttp2GrpcDemo"
else
  # A DIFFERENT unit output directory from every other stage, and this is not
  # cosmetic: those stages compiled with -dHORSE_GRPC_NO_FFI, and FPC happily
  # reuses a cached .ppu built under different -d flags. Sharing the directory
  # would silently relink the no-ffi build and RegisterService<T> would fail at
  # run time with nothing in the compile log to explain why.
  GRPC_OUT="-FU$WORK/grpc-units"
  mkdir -p "$WORK/grpc-units"

  GRPC_FLAGS="-n -MDelphi -O1 -gl -dHORSE_PROVIDER_NGHTTP2 \
    -Fu. -Fu$PROV -Fu$DNG -Fu$HORSE \
    -Fu$TU/rtl -Fu$TU/rtl-console -Fu$TU/rtl-objpas -Fu$TU/rtl-extra \
    -Fu$TU/rtl-generics -Fu$TU/fcl-base -Fu$TU/fcl-web -Fu$TU/fcl-json \
    -Fu$TU/regexpr -Fu$TU/pthreads -Fu$TU/openssl -Fu$TU/fcl-net \
    -Fu$TU/hash -Fu$TU/libffi"

  GRPC_OK=1
  pushd "$GRPC" > /dev/null
  for prog in HorseNghttp2GrpcDemo HorseNghttp2GrpcTestClient; do
    echo "  compiling $prog.dpr ..."
    if $TRUNK $GRPC_FLAGS $GRPC_OUT "$prog.dpr" > "$WORK/$prog.log" 2>&1; then
      pass "$prog.dpr"
    else
      fail "$prog.dpr"
      grep -E "Error|Fatal" "$WORK/$prog.log" | head -8 | sed 's/^/    /'
      GRPC_OK=0
    fi
  done

  if [[ $GRPC_OK -eq 1 ]]; then
    stdbuf -o0 -e0 ./HorseNghttp2GrpcDemo < /dev/null > "$WORK/grpc-server.log" 2>&1 &
    SRV=$!
    SERVERS+=("$SRV")
    sleep 0.8
    if ! kill -0 "$SRV" 2>/dev/null; then
      fail "gRPC demo exited at startup"
      tail -4 "$WORK/grpc-server.log" | sed 's/^/    | /'
    else
      # A failure here that compiled cleanly is usually libffi missing at run
      # time rather than a protocol fault — TRttiMethod.Invoke is what needs it.
      if timeout 120 ./HorseNghttp2GrpcTestClient \
           < /dev/null > "$WORK/grpc-client.log" 2>&1; then
        pass "gRPC suite (h2c)"
      else
        fail "gRPC suite (h2c)"
        echo "    if this compiled but failed at run time, check: apt install libffi8"
      fi
      grep -E "passed, .* failed" "$WORK/grpc-client.log" | tail -1 | sed 's/^/    /'
    fi
    kill -TERM "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
  fi
  popd > /dev/null
fi

# ── 12 · 94-check suite driven by the epoll event loop ───────────────────────
#
# Every stage above exercises the THREAD driver. This is the only one that
# runs the epoll engine, and until it exists Nghttp2.Engine.Epoll is compiled
# but never executed — the compile step in stage 2 proves it links, nothing
# more.
#
# Same 94 checks, same client, same routes; only the connection driver
# changes. That is deliberate: a dedicated engine test would be a second
# definition of correct, and the point is that the engine must be
# indistinguishable from the thread driver at the protocol level.
#
# h2c only. A TLS listener falls back to thread-per-connection by design, so
# an `eventloop tls` run would silently measure the thread driver again.
echo
echo "── 12  94-check suite via epoll event loop (h2c) ────────────────────────"
if [[ $SERVER_OK -eq 0 || $CLIENT_OK -eq 0 ]]; then
  echo "  SKIP  test programs did not build"
elif ! require_port_free "$PORT"; then
  fail "event-loop suite (port $PORT occupied before we started)"
else
  stdbuf -o0 -e0 ./HorseNghttp2TestServer eventloop \
    < /dev/null > "$WORK/eventloop-server.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  # Longer than elsewhere: TDriverProbe reports the resolved driver ~400 ms
  # in, and that line is the whole point of the stage.
  sleep 1.2

  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "event-loop server exited at startup"
    tail -6 "$WORK/eventloop-server.log" | sed 's/^/    | /'
  else
    { grep -E "^\[driver\]" "$WORK/eventloop-server.log" | tail -1 | sed 's/^/    /'; } || true

    # The gate that makes this stage mean anything. `eventloop` is a REQUEST
    # that degrades silently — wrong platform, engine unit not linked — and a
    # fallback run passes all 94 checks while testing the driver that stage 5
    # already covered. Without this check the stage would report green for
    # code that never ran.
    if grep -q "RESOLVED: epoll event loop" "$WORK/eventloop-server.log"; then
      if timeout 120 ./HorseNghttp2TestClient \
           < /dev/null > "$WORK/eventloop-client.log" 2>&1; then
        pass "94-check suite via event loop"
      elif [[ $? -eq 124 ]]; then
        fail "94-check suite via event loop (timed out after 120s)"
        echo "    a hang here is the engine, not the protocol — suspect a"
        echo "    connection parked with output held and no writable wake"
      else
        fail "94-check suite via event loop"
      fi
      grep -E "passed, .* failed" "$WORK/eventloop-client.log" | tail -1 | sed 's/^/    /'
    else
      fail "event loop requested but NOT resolved — stage would have retested the thread driver"
      echo "    check that Nghttp2.Engine.Epoll is linked and the target is Linux"
    fi
  fi

  kill -TERM "$SRV" 2>/dev/null || true
  wait "$SRV" 2>/dev/null || true
  wait_port_free "$PORT" 15 || true
fi

# ── 13 · TLS driven by the epoll event loop ──────────────────────────────────
#
# Stage 9 runs the same 94 checks over TLS on the THREAD driver. This runs them
# on the engine, which is a different code path end to end: the handshake is
# driven a step at a time from RunOnce via HandshakeStep, reads go through
# ReadNB, and writes are encrypted with WriteNB before the socket sees them.
#
# Until B4d that combination was refused outright — Setup called the blocking
# DoHandshake, which on a shared loop thread would stall every other connection
# that loop owned.
echo
echo "── 13  94-check suite over TLS via epoll event loop ─────────────────────"
if [[ $SERVER_OK -eq 0 || $CLIENT_OK -eq 0 ]]; then
  echo "  SKIP  test programs did not build"
elif [[ ! -f tls/cert.pem || ! -f tls/key.pem ]]; then
  echo "  SKIP  tls/cert.pem or tls/key.pem missing — run: bash gen-tls-cert.sh"
elif ! wait_port_free "$TLS_PORT" 15; then
  echo "  SKIP  port $TLS_PORT still bound"
else
  stdbuf -o0 -e0 ./HorseNghttp2TestServer eventloop tls \
    < /dev/null > "$WORK/eventloop-tls.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  sleep 1.2      # TDriverProbe reports the resolved driver ~400 ms in

  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "event-loop TLS server exited at startup"
    tail -6 "$WORK/eventloop-tls.log" | sed 's/^/    | /'
  else
    { grep -E "^\[driver\]" "$WORK/eventloop-tls.log" | tail -1 | sed 's/^/    /'; } || true

    # The gate that gives this stage meaning. Before B4d the engine DECLINED
    # to own accept whenever a TLS context was set, so `eventloop tls` fell
    # back to the thread driver — passing all 94 checks while re-testing
    # stage 9. Without this check a regression to that behaviour reads green.
    if grep -q "RESOLVED: epoll event loop" "$WORK/eventloop-tls.log"; then
      run_client_suite eventloop-tls-client \
        "94-check suite over TLS via event loop" "https://127.0.0.1:$TLS_PORT"
    else
      fail "TLS + eventloop requested but engine NOT resolved — would have retested stage 9"
    fi
  fi
  kill -TERM "$SRV" 2>/dev/null || true
  wait "$SRV" 2>/dev/null || true
  wait_port_free "$TLS_PORT" 15 || true
fi

# ── 14 · mTLS driven by the epoll event loop ─────────────────────────────────
#
# Stage 10 covers mTLS on the THREAD driver. This is the same client-cert
# verification on the engine, where the handshake is resumable and every
# certificate exchange happens across several epoll wakes instead of inside one
# blocking call.
#
# Positive first, for the same reason as stage 10: it proves the server is up
# and the certs are good, so the negative run that follows can only be failing
# for the reason under test.
#
# The negative case matters more here than anywhere else in the suite. A
# handshake rewritten to be resumable that accidentally SUCCEEDS where it
# should fail passes every positive check ever written — this is the only
# stage that would catch it on the engine.
echo
echo "── 14  94-check suite over mTLS via epoll event loop ────────────────────"
if [[ $SERVER_OK -eq 0 || $CLIENT_OK -eq 0 ]]; then
  echo "  SKIP  test programs did not build"
elif [[ ! -f tls/ca.pem || ! -f tls/client-cert.pem || ! -f tls/client-key.pem ]]; then
  echo "  SKIP  tls/ca.pem or client cert/key missing — run: bash gen-tls-cert.sh"
elif ! wait_port_free "$TLS_PORT" 15; then
  echo "  SKIP  port $TLS_PORT still bound"
else
  stdbuf -o0 -e0 ./HorseNghttp2TestServer eventloop mtls \
    < /dev/null > "$WORK/eventloop-mtls.log" 2>&1 &
  SRV=$!
  SERVERS+=("$SRV")
  sleep 1.2      # TDriverProbe reports the resolved driver ~400 ms in

  if ! kill -0 "$SRV" 2>/dev/null; then
    fail "event-loop mTLS server exited at startup"
    tail -6 "$WORK/eventloop-mtls.log" | sed 's/^/    | /'
  else
    { grep -E "^\[driver\]" "$WORK/eventloop-mtls.log" | tail -1 | sed 's/^/    /'; } || true

    # Same gate as stages 12 and 13: a silent fallback would re-test stage 10
    # under the engine's name and report green.
    if ! grep -q "RESOLVED: epoll event loop" "$WORK/eventloop-mtls.log"; then
      fail "mTLS + eventloop requested but engine NOT resolved — would have retested stage 10"
    else
      run_client_suite eventloop-mtls-client \
        "mTLS positive via event loop (client cert presented)" \
        "https://127.0.0.1:$TLS_PORT" \
        --client-cert tls/client-cert.pem --client-key tls/client-key.pem

      if timeout 120 ./HorseNghttp2TestClient "https://127.0.0.1:$TLS_PORT" \
           < /dev/null > "$WORK/eventloop-mtls-negative.log" 2>&1; then
        fail "mTLS negative via event loop — uncertified client was ACCEPTED"
      else
        pass "mTLS negative via event loop — uncertified client refused"
      fi
    fi
  fi
  kill -TERM "$SRV" 2>/dev/null || true
  wait "$SRV" 2>/dev/null || true
  wait_port_free "$TLS_PORT" 15 || true
fi

echo
echo "Stages: $PASS passed, $FAIL failed"
exit $FAIL
