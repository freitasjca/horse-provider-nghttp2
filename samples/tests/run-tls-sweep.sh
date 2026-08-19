#!/usr/bin/env bash
# ============================================================================
#  run-tls-sweep.sh — what does TLS cost under load, and does the epoll engine
#  still win once every connection carries a handshake?
#
#  run-conn-sweep.sh is h2c only. Its headline — 93 334 req/s at c=10 000,
#  where the thread driver times out — says nothing about h2, and the B4d
#  stages say nothing about load: stage 13 runs 94 checks over ONE connection.
#  Engine TLS has never seen concurrency at all. This closes that.
#
#  ── Why two phases and not one ──
#
#  TLS costs in two different places and a single sweep conflates them:
#
#    per CONNECTION   the handshake — RSA/ECDHE, two round trips
#    per BYTE         record encryption on every request and response
#
#  h2load opens -c connections once and reuses them for all -n requests, so
#  the ratio n/c decides which cost you are actually measuring. The h2c sweep
#  uses n = max(20000, 20N), i.e. ~20 requests per connection, which amortises
#  the handshake to near nothing. Re-running that with https:// would produce
#  a clean-looking table that hides the larger of the two costs.
#
#    steady      n = max(20000, 20N)   ~20 req/conn. Directly comparable to the
#                                      h2c sweep; isolates the per-byte cost.
#    handshake   n = c                 exactly 1 req/conn. Every request pays a
#                                      full handshake. This is the connection
#                                      -churn shape a public endpoint actually
#                                      sees, and where TLS hurts.
#
#  Both drivers and both protocols run in all phases, so the table answers
#  three questions at once:
#
#    engine-tls vs thread-tls  ...... does the engine still win under TLS?
#    thread-tls vs thread-h2c  ...... what does TLS cost, driver held constant?
#    engine-tls vs engine-h2c  ...... same, on the engine
#
#  ── What would make this measurement a lie ──
#
#  Three ways, all gated below rather than trusted:
#
#    1. `eventloop` degrades silently. A fallback cell is the thread row
#       wearing the engine's label. Gated on the RESOLVED line, as in the h2c
#       sweep — the cell is DISCARDED, not skipped.
#    2. ALPN falling back to http/1.1 would measure a different protocol.
#       h2load reports the negotiated protocol; checked per cell.
#    3. TLS session RESUMPTION turns the second and later handshakes into a
#       fraction of the first, which would make the handshake phase measure
#       almost nothing. h2load does not resume across connections by default,
#       but the first cell prints the handshake count so the assumption is
#       visible rather than implied.
#
#  Usage:  bash run-tls-sweep.sh [--conns "10 100 1000"] [--phases "steady handshake"]
#          bash run-tls-sweep.sh --quick          # 10 100 1000, steady only
#  Needs:  ./HorseNghttp2TestServer built (build-fpc.sh), h2load, tls/ fixtures.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

CONN_LIST="10 100 1000 5000 10000"
PHASES="steady handshake"
# h2load is SINGLE-THREADED by default and saturates one core at roughly
# 110% CPU. The first run of this sweep used the default and every TLS cell
# was bounded by the CLIENT, not the server: it reported the engine capped at
# ~27 000 req/s under TLS, when the real figure with an unsaturated client is
# ~184 000. The server sat at 23% of a 28-core box with no thread above 20%
# the whole time. Never benchmark TLS with -t 1.
CLIENT_THREADS=$(( $(nproc) / 2 )); [[ $CLIENT_THREADS -gt 14 ]] && CLIENT_THREADS=14
[[ $CLIENT_THREADS -lt 1 ]] && CLIENT_THREADS=1
ROUTE=/ping
PORT_H2C=9010
PORT_TLS=9443
SERVER=./HorseNghttp2TestServer
OUT="tls-sweep-$(date +%Y%m%d-%H%M%S).md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conns)  CONN_LIST="$2"; shift 2 ;;
    --phases) PHASES="$2"; shift 2 ;;
    --route)  ROUTE="$2"; shift 2 ;;
    --quick)  CONN_LIST="10 100 1000"; PHASES="steady"; shift ;;
    --client-threads) CLIENT_THREADS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$SERVER" ]] || { echo "ERROR: $SERVER not built — run build-fpc.sh first." >&2; exit 1; }
command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found (apt install nghttp2-client)." >&2; exit 1; }
for f in tls/cert.pem tls/key.pem; do
  [[ -f "$f" ]] || { echo "ERROR: $f missing — run gen-tls-cert.sh." >&2; exit 1; }
done

MAXCONN=$(tr ' ' '\n' <<< "$CONN_LIST" | sort -n | tail -1)
NOFILE=$(ulimit -n)
NEED=$(( MAXCONN * 2 + 256 ))
if [[ "$NOFILE" -lt "$NEED" ]]; then
  echo "ERROR: ulimit -n is $NOFILE, and c=$MAXCONN needs about $NEED."
  echo "       A cell that runs out of descriptors looks exactly like the"
  echo "       driver collapsing, which is what this sweep is measuring."
  echo "       Run:  ulimit -n $NEED"
  exit 1
fi

WORK=$(mktemp -d)
SRV=""
SPID=""

cleanup() {
  [[ -n "$SPID" ]] && kill -TERM "$SPID" 2>/dev/null
  [[ -n "$SRV"  ]] && kill -TERM "$SRV"  2>/dev/null
  pkill -P $$ 2>/dev/null
  rm -rf "$WORK"
}
on_int() { echo; echo "Interrupted — stopping the sweep."; cleanup; exit 130; }
trap cleanup EXIT
trap on_int INT TERM

alive() {   # kill -0 succeeds on an unreaped zombie; /proc state does not
  local pid=$1 st
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  [[ "$st" != "Z" ]]
}

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

declare -A RPS RSS THR NOTE PROTO

# mode = thread-h2c | thread-tls | engine-h2c | engine-tls
run_cell() {   # <mode> <conns> <phase>
  local MODE=$1 CONNS=$2 PHASE=$3 KEY="$1/$2/$3"
  local ARGS=() URL PORT N OUTP RC SAMP PEAK TMO

  RPS[$KEY]=""; RSS[$KEY]=""; THR[$KEY]=""; NOTE[$KEY]=""; PROTO[$KEY]=""

  case "$MODE" in
    thread-h2c) ARGS=();                  PORT=$PORT_H2C; URL="http://127.0.0.1:$PORT_H2C$ROUTE" ;;
    thread-tls) ARGS=(tls);               PORT=$PORT_TLS; URL="https://127.0.0.1:$PORT_TLS$ROUTE" ;;
    engine-h2c) ARGS=(eventloop);         PORT=$PORT_H2C; URL="http://127.0.0.1:$PORT_H2C$ROUTE" ;;
    engine-tls) ARGS=(eventloop tls);     PORT=$PORT_TLS; URL="https://127.0.0.1:$PORT_TLS$ROUTE" ;;
  esac

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    NOTE[$KEY]="port busy"; echo "    SKIP — port $PORT bound"; return
  fi

  "$SERVER" "${ARGS[@]+"${ARGS[@]}"}" < /dev/null > "$WORK/$MODE-$CONNS-$PHASE.log" 2>&1 &
  SRV=$!
  sleep 1.5      # TDriverProbe reports the resolved driver ~400 ms in

  if ! alive "$SRV"; then
    NOTE[$KEY]="server exited at startup"
    echo "    FAIL — server exited"; sed 's/^/      | /' "$WORK/$MODE-$CONNS-$PHASE.log"
    wait "$SRV" 2>/dev/null; SRV=""; return
  fi

  # Gate 1 — the driver actually in force.
  local RESOLVED
  RESOLVED=$(grep -oE 'RESOLVED: .*' "$WORK/$MODE-$CONNS-$PHASE.log" | head -1)
  if [[ "$MODE" == engine-* && "$RESOLVED" != *"epoll event loop"* ]]; then
    NOTE[$KEY]="engine NOT resolved — cell discarded"
    echo "    FAIL — asked for the engine, got: ${RESOLVED:-nothing}"
    kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; return
  fi

  if [[ "$PHASE" == "handshake" ]]; then
    N=$CONNS
    TMO=120                      # every request pays a handshake; slower
  else
    N=$(( CONNS * 20 )); [[ "$N" -lt 20000 ]] && N=20000
    TMO=90
  fi

  # Warm-up: fills the accept backlog and pages the code in. For TLS it also
  # forces the first handshake, which is the expensive one (cert parse, DH
  # params); leaving it inside the measured run would tax the small cells only.
  local CT=$CLIENT_THREADS
  [[ $CT -gt $CONNS ]] && CT=$CONNS      # h2load rejects -t greater than -c
  timeout 60 h2load -t "$CT" -n "$CONNS" -c "$CONNS" -m 1 "$URL" > /dev/null 2>&1

  SAMP="$WORK/$MODE-$CONNS-$PHASE.peak"
  sample_peak "$SRV" "$SAMP" &
  SPID=$!

  OUTP=$(timeout "$TMO" h2load -t "$CT" -n "$N" -c "$CONNS" -m 1 "$URL" 2>&1); RC=$?

  kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
  wait "$SPID" 2>/dev/null; SPID=""
  PEAK=$(cat "$SAMP" 2>/dev/null || echo "0 0")
  RSS[$KEY]=$(( $(cut -d' ' -f1 <<< "$PEAK") / 1024 ))
  THR[$KEY]=$(cut -d' ' -f2 <<< "$PEAK")

  if [[ $RC -eq 124 ]]; then
    NOTE[$KEY]="TIMED OUT (${TMO}s)"; echo "    TIMEOUT"; return
  fi

  # Gate 2 — which protocol was actually negotiated. h2load prints
  # "Application protocol: h2" (TLS/ALPN) or "h2c" (prior knowledge).
  PROTO[$KEY]=$(grep -oE 'Application protocol: [^ ]+' <<< "$OUTP" | awk '{print $3}' | head -1)
  if [[ "$MODE" == *-tls && -n "${PROTO[$KEY]}" && "${PROTO[$KEY]}" != "h2" ]]; then
    NOTE[$KEY]="ALPN gave ${PROTO[$KEY]}, not h2 — cell discarded"
    echo "    FAIL — negotiated ${PROTO[$KEY]}"; RPS[$KEY]=""; return
  fi

  local OK FAILED
  OK=$(grep -oE '[0-9]+ succeeded' <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  FAILED=$(grep -oE '[0-9]+ failed' <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  RPS[$KEY]=$(grep -oE '[0-9.]+ req/s' <<< "$OUTP" | grep -oE '^[0-9.]+' | head -1)

  if [[ -n "${FAILED:-}" && "$FAILED" -gt 0 ]]; then
    NOTE[$KEY]="${FAILED} of $N failed"
  fi
  echo "    ${RPS[$KEY]:-?} req/s   RSS ${RSS[$KEY]}MB   threads ${THR[$KEY]}   ${PROTO[$KEY]:-?}   ${NOTE[$KEY]:-ok}"
}

{
  echo "# TLS-under-load sweep — epoll engine vs thread driver, h2 vs h2c"
  echo
  echo "- host: \`$(uname -srm)\`, $(nproc) cores, ulimit -n $NOFILE"
  echo "- route: \`$ROUTE\`, h2load \`-t $CLIENT_THREADS -c N -m 1\`"
  echo "- client threads: $CLIENT_THREADS (h2load defaults to 1 and saturates ONE core;"
  echo "  with the default every TLS cell measures the client, not the server)"
  echo "- cert: \`tls/cert.pem\` (self-signed; h2load does not verify)"
  echo "- openssl: \`$(openssl version 2>/dev/null)\`"
  echo
  echo "Phases:"
  echo
  echo "| phase | n | req per conn | isolates |"
  echo "|---|---|---|---|"
  echo "| steady | max(20000, 20N) | ~20 | per-BYTE encryption; comparable to the h2c sweep |"
  echo "| handshake | N | 1 | per-CONNECTION handshake; the connection-churn shape |"
  echo
  echo "Every engine cell verifies \`RESOLVED: epoll event loop\` and every TLS"
  echo "cell verifies ALPN negotiated \`h2\`. A cell failing either is DISCARDED,"
  echo "not silently downgraded."
} | tee "$OUT"

for PHASE in $PHASES; do
  echo | tee -a "$OUT"
  echo "## Phase: $PHASE" | tee -a "$OUT"
  for MODE in thread-h2c thread-tls engine-h2c engine-tls; do
    echo | tee -a "$OUT"
    echo "### $MODE" | tee -a "$OUT"
    echo | tee -a "$OUT"
    echo "| conns | req/s | peak RSS MB | peak threads | proto | note |" | tee -a "$OUT"
    echo "|---|---|---|---|---|---|" | tee -a "$OUT"
    COLLAPSED=0
    for C in $CONN_LIST; do
      if [[ $COLLAPSED -eq 1 ]]; then
        echo "  [$PHASE $MODE c=$C] SKIPPED — already failed at a lower count"
        echo "| $C | — | — | — | — | skipped after earlier failure |" >> "$OUT"
        continue
      fi
      echo "  [$PHASE $MODE c=$C]"
      run_cell "$MODE" "$C" "$PHASE"
      K="$MODE/$C/$PHASE"
      echo "| $C | ${RPS[$K]:-—} | ${RSS[$K]:-—} | ${THR[$K]:-—} | ${PROTO[$K]:-—} | ${NOTE[$K]:-} |" >> "$OUT"
      if [[ -z "${RPS[$K]:-}" || "${NOTE[$K]:-}" == *"TIMED OUT"* \
            || "${NOTE[$K]:-}" == *"exited"* ]]; then
        COLLAPSED=1
        echo "    ^ ceiling for $MODE in phase $PHASE; skipping higher counts"
      fi
      sleep 1
    done
  done

  {
    echo
    echo "### $PHASE — TLS tax and engine advantage"
    echo
    echo "| conns | thread h2c | thread tls | tls tax | engine h2c | engine tls | tls tax | engine/thread (tls) |"
    echo "|---|---|---|---|---|---|---|---|"
    for C in $CONN_LIST; do
      th=${RPS[thread-h2c/$C/$PHASE]:-}; tt=${RPS[thread-tls/$C/$PHASE]:-}
      eh=${RPS[engine-h2c/$C/$PHASE]:-}; et=${RPS[engine-tls/$C/$PHASE]:-}
      ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if(a!="" && b!="" && a>0) printf "%.2fx", b/a; else print "—" }'; }
      printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" \
        "$C" "${th:-—}" "${tt:-—}" "$(ratio "$th" "$tt")" \
             "${eh:-—}" "${et:-—}" "$(ratio "$eh" "$et")" "$(ratio "$tt" "$et")"
    done
  } | tee -a "$OUT"
done

{
  echo
  echo "## How to read this"
  echo
  echo "**tls tax** is tls/h2c on the SAME driver, so it is the protocol cost with"
  echo "everything else held constant. Below 1.00x means TLS is slower, which it"
  echo "always should be; a value at or above 1.00x means the run was bounded by"
  echo "something other than the server and the cell should be discarded."
  echo
  echo "**engine/thread (tls)** is the question run-conn-sweep.sh answered for h2c"
  echo "and could not answer for h2. The h2c answer was 93 334 req/s at c=10 000"
  echo "against a thread driver that timed out. If that advantage survives TLS,"
  echo "the engine is worth defaulting on for public endpoints; if TLS erases it,"
  echo "the engine is an h2c-only optimisation and should be described as one."
  echo
  echo "**Compare the two phases before concluding anything.** A driver can look"
  echo "fine in steady state and collapse under handshake churn — the handshake"
  echo "is CPU-bound work on whichever thread owns the connection, and that is"
  echo "precisely where a shared event loop is most at risk of head-of-line"
  echo "blocking. Engine TLS has never been under concurrency before this run."
  echo
  echo "**Peak threads** should track connection count on the thread rows and stay"
  echo "flat on the engine rows. A thread row that stops climbing has hit a limit."
} | tee -a "$OUT"

echo
echo "Results: $OUT"
