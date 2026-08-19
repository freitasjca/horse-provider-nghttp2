#!/usr/bin/env bash
# ============================================================================
#  run-floor-nghttp2.sh — the ONE measurement that changes a decision
#
#  Scenario S8 of plans/bench-plan-all-providers.md, narrowed to nghttp2:
#  raw TNghttp2Server vs the same transport under Horse. The delta is what
#  THorse.Execute + context pool + bridges cost per request.
#
#  ── Why this exists separately from run-p1.sh ──
#
#  run-p1.sh wants nine servers across four providers, and each one is its own
#  build-integration project: CrossSocket needs the DelphiToFPC shims, mORMot
#  pulls a large dependency tree, FPCHttp needs fcl-web, and the Epoll provider
#  currently fails to LINK on FPC trunk (a Horse-side WebSocket symbol) though
#  it built and ran fine on 3.2.2. Three rounds went into build archaeology
#  without producing a number.
#
#  This script gives up on breadth to get one real result, by reusing
#  build-fpc.sh's flag set verbatim — the one configuration proven to compile
#  this stack on this machine, every stage green.
#
#  ── Why the nghttp2 floor is the decisive one ──
#
#  The open question is whether more transport work (Step B: the epoll engine,
#  SO_REUSEPORT, TLS under the loop) is worth doing. If Horse's own per-request
#  cost dominates, then it is not — the remaining headroom belongs to
#  THorse.Execute, and no engine can reach below it. That verdict needs
#  exactly these two servers, not nine.
#
#  Usage:
#    bash run-floor-nghttp2.sh [--build] [--runs N]
#
#  Environment: TRUNK_FPC / TRUNK_UNITS, same defaults as build-fpc.sh.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

RUNS=3
DO_BUILD=0
REQS=20000   # 20k is seconds at these rates; 100k made a stall look like slowness
CONNS=1      # see note below
WORKERS=4

# ── Why one connection ──────────────────────────────────────────────────────
# This measurement is a per-request COST comparison, not a throughput test:
# raw vs wrapped on the identical transport, so the cleanest reading is one
# request at a time with nothing queued behind it. -c 1 -m 1 gives exactly
# that, and every extra connection adds scheduling noise to a delta that may
# be a few microseconds wide.
#
# It also sidesteps an unrelated problem: at -c 10 the wrapped server with
# --inline ran far slower than expected (minutes for a run that should take
# seconds). Inline dispatch under concurrency is a lightly-exercised path —
# build-fpc.sh always runs the worker pool — so that is worth chasing on its
# own, but it must not contaminate the floor number.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) DO_BUILD=1; shift ;;
    --runs)  RUNS="$2"; shift 2 ;;
    --reqs)  REQS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

TRUNK=${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}
TU=${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}

# Resolved against this script's own location:
#   patches/horse-provider-nghttp2/samples/tests
#   ../../..    = patches/          (Delphi-nghttp2 exists ONLY here)
#   ../../../.. = repo root         (horse/ sits beside patches/)
DNG=../../../Delphi-nghttp2/src
PROV=../../../horse-provider-nghttp2/src
HORSE=../../../../horse/src
BENCH=../../../horse-provider-crosssocket/samples/bench
# Middleware, for the bench server's --middleware mode. patches/ and the repo
# root are byte-identical for these two units today, so the root copies are
# used to match every other bench server's documented search paths.
GUARD=../../../../horse-request-guard/src
SECHDR=../../../../horse-security-headers/src

command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found (apt install nghttp2-client)." >&2; exit 1; }
[[ -x "$TRUNK" ]] || { echo "ERROR: trunk fpc not found at $TRUNK" >&2; exit 1; }

WORK=$(mktemp -d)
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill -TERM "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Verbatim from build-fpc.sh, which compiles this stack green on this machine.
# -n is load-bearing: without it fpc reads /etc/fpc.cfg and mixes distro 3.2.2
# .ppu files into a trunk build ("PPU Invalid Version 207 expecting 208").
BASE_FLAGS="-n -MDelphi -O2 -dHORSE_PROVIDER_NGHTTP2 -dHORSE_GRPC_NO_FFI \
  -Fu$PROV -Fu$DNG -Fu$HORSE -Fu$BENCH/Common -Fu$GUARD -Fu$SECHDR \
  -Fu$TU/rtl -Fu$TU/rtl-console -Fu$TU/rtl-objpas -Fu$TU/rtl-extra \
  -Fu$TU/rtl-generics -Fu$TU/fcl-base -Fu$TU/fcl-web -Fu$TU/fcl-json \
  -Fu$TU/regexpr -Fu$TU/pthreads -Fu$TU/openssl -Fu$TU/fcl-net -Fu$TU/hash"

BIN=./bench-bin
mkdir -p "$BIN"

if [[ $DO_BUILD -eq 1 ]]; then
  for pair in "HorseBenchNghttp2:$BENCH/Servers/Lazarus/Nghttp2" \
              "HorseBenchRawNghttp2:$BENCH/Servers/Lazarus/RawNghttp2"; do
    NAME=${pair%%:*}; DIR=${pair#*:}
    echo "building $NAME ..."
    # Separate unit dir per binary: FPC's .ppu cache ignores -d changes.
    # WIPE, not mkdir -p — the same defect that hit run-p1.sh. FPC's .ppu
    # cache does not account for changed switches or defines, so a directory
    # carrying units from an earlier build gets partially reused. It surfaced
    # here as "Horse.Core.RouterTree.pas: No matching implementation for
    # interface method Execute(...)" — a Horse unit that compiles perfectly
    # well, checked against a stale interface from a previous build.
    UD="$BIN/units-$NAME"; rm -rf "$UD"; mkdir -p "$UD"
    if $TRUNK $BASE_FLAGS -FU"$UD" -o"$BIN/$NAME" "$DIR/$NAME.lpr" \
         > "$BIN/$NAME.build.log" 2>&1; then
      echo "  ok"
    else
      echo "  FAILED — $BIN/$NAME.build.log"
      grep -E "Error|Fatal" "$BIN/$NAME.build.log" | head -8 | sed 's/^/    | /'
    fi
  done
  echo
fi

median() { sort -n | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){print a[(NR+1)/2]} else {printf "%.2f",(a[NR/2]+a[NR/2+1])/2} }'; }

declare -A RESULT

# Is a background child actually alive, or a zombie the shell has not reaped?
# `kill -0` cannot tell them apart — it succeeds on a zombie — so a server that
# died at startup passed the old check and the run then hung in h2load with no
# message at all. /proc's state field distinguishes them: Z = defunct.
alive() {
  local pid=$1 st
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  [[ "$st" != "Z" ]]
}

run_one() {   # <label> <binary> <port> [extra server args...]
  local LABEL=$1 BINARY=$2 PORT=$3; shift 3
  local RC OUT F

  echo "  [$LABEL] starting $BINARY on :$PORT $*"
  if [[ ! -x "$BINARY" ]]; then
    echo "  [$LABEL] SKIP — not built"; RESULT[$LABEL]=0; return
  fi
  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "  [$LABEL] SKIP — port $PORT already bound"; RESULT[$LABEL]=0; return
  fi

  "$BINARY" "$@" < /dev/null > "$WORK/$LABEL.log" 2>&1 &
  SRV=$!
  sleep 1

  if ! alive "$SRV"; then
    echo "  [$LABEL] FAIL — server is not running after 1s. Its output:"
    sed 's/^/    | /' "$WORK/$LABEL.log"
    wait "$SRV" 2>/dev/null; SRV=""; RESULT[$LABEL]=0; return
  fi
  if ! ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "  [$LABEL] FAIL — process is up but nothing is listening on :$PORT."
    sed 's/^/    | /' "$WORK/$LABEL.log"
    kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
    RESULT[$LABEL]=0; return
  fi
  echo "  [$LABEL] listening; probing with one request ..."

  # Single-request probe before any load. EVERY h2load call is wrapped in
  # timeout: without it a server that accepts but never answers hangs the
  # whole script with no output, which is exactly what happened.
  # Capture the status on its OWN line. `if ! OUT=$(...); then RC=$?` reads
  # $? AFTER the negation, so RC is always 0 — which is how a genuine h2load
  # failure got reported as "exited 0" and told us nothing.
  OUT=$(timeout 20 h2load -n 1 -c 1 -m 1 "http://127.0.0.1:$PORT/ping" 2>&1)
  RC=$?
  if [[ $RC -ne 0 ]]; then
    if [[ $RC -eq 124 ]]; then
      echo "  [$LABEL] FAIL — h2load hung on a single request (20s timeout)."
      echo "           The server accepted the connection and never replied."
    else
      echo "  [$LABEL] FAIL — h2load exited $RC on a single request. Full output:"
    fi
    echo "$OUT" | sed 's/^/    h2load | /'
    echo "    ---- server output ----"
    sed 's/^/    server | /' "$WORK/$LABEL.log"

    # HTTP-level second opinion. h2load reports transport failures tersely;
    # curl shows the frames, the status, and any GOAWAY/RST reason.
    if command -v curl > /dev/null 2>&1; then
      echo "    ---- curl --http2-prior-knowledge ----"
      timeout 20 curl -sS -v --http2-prior-knowledge \
        "http://127.0.0.1:$PORT/ping" 2>&1 | sed 's/^/    curl | /' | head -40
    fi

    kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
    RESULT[$LABEL]=0; return
  fi
  if ! grep -qE '1 succeeded' <<< "$OUT"; then
    echo "  [$LABEL] FAIL — probe request did not succeed:"
    echo "$OUT" | grep -E 'succeeded|failed|errored' | sed 's/^/    | /'
    kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
    RESULT[$LABEL]=0; return
  fi
  echo "  [$LABEL] probe ok; warm-up ..."

  timeout 60 h2load -n 2000 -c 20 -m 1 "http://127.0.0.1:$PORT/ping" > /dev/null 2>&1

  F=$(mktemp)
  for ((r=1; r<=RUNS; r++)); do
    echo "  [$LABEL] run $r/$RUNS ..."
    RUNOUT=$(timeout 90 h2load -n "$REQS" -c "$CONNS" -m 1 \
               "http://127.0.0.1:$PORT/ping" 2>&1); RC=$?
    if [[ $RC -eq 124 ]]; then
      echo "  [$LABEL] run $r TIMED OUT after 90s — recording nothing for it."
      echo "$RUNOUT" | tail -3 | sed 's/^/    h2load | /'
    else
      grep -oE '[0-9.]+ req/s' <<< "$RUNOUT" | grep -oE '^[0-9.]+' | head -1 >> "$F"
    fi
  done
  RESULT[$LABEL]=$(median < "$F")
  echo "  [$LABEL] => ${RESULT[$LABEL]} req/s"
  rm -f "$F"

  kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
  sleep 0.5
}

echo "nghttp2 framework floor — h2c, -c $CONNS -m 1, $RUNS runs, median"
echo "  compiler: $($TRUNK -iV 2>/dev/null)"
echo
# ── Both sides INLINE, deliberately ──────────────────────────────────────
# The raw server has no worker pool — a pool is something the Horse provider
# builds, not something TNghttp2Server owns. Running the wrapped server pooled
# against a raw server that cannot be would put a thread handoff on one side
# of the comparison and not the other, and the delta would no longer be "what
# Horse costs".

#  Inline on both sides isolates the one variable this measurement is about.
run_one raw   "$BIN/HorseBenchRawNghttp2" 9042
run_one horse "$BIN/HorseBenchNghttp2"    9041 --inline

RAW=${RESULT[raw]:-0}; HORSE_RPS=${RESULT[horse]:-0}
echo
if awk -v a="$RAW" -v b="$HORSE_RPS" 'BEGIN{exit !(a>0 && b>0)}'; then
  awk -v raw="$RAW" -v h="$HORSE_RPS" 'BEGIN{
    printf "raw   %10.2f req/s   %8.3f us/req\n", raw, 1e6/raw;
    printf "horse %10.2f req/s   %8.3f us/req\n", h,   1e6/h;
    printf "\nHorse costs %.3f us/req — %.1f%% of the wrapped per-request cost.\n",
           1e6/h - 1e6/raw, (1e6/h - 1e6/raw)/(1e6/h)*100;
    print "";
    if ((1e6/h - 1e6/raw)/(1e6/h) > 0.5)
      print "VERDICT: the framework DOMINATES. Transport work has poor return —";
    else
      print "VERDICT: the transport is a meaningful share. Engine work can still pay —";
    print "         see plans/bench-plan-all-providers.md decision criteria.";
  }'
else
  echo "Not enough data for a verdict — see the messages above."
fi
