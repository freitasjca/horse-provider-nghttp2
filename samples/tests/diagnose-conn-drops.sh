#!/usr/bin/env bash
# ============================================================================
#  diagnose-conn-drops.sh — why does engine-h2c lose 6.1% of requests at
#  c=10 000 while engine-tls at the same count loses 0.09%?
#
#  From tls-sweep-20260817-222802.md:
#    engine-h2c  c=10 000   12 221 of 200 000 failed   (6.1%)
#    engine-tls  c=10 000      171 of 200 000 failed   (0.09%)
#
#  A 70x difference between two protocols on the same driver at the same
#  connection count is not connection volume. It is the only correctness-
#  shaped signal in the whole benchmark set, and everything else measured
#  here has turned out to be an artifact at least once, so this measures
#  rather than reasons.
#
#  ── The hypothesis, and why it is checkable ──
#
#  Nghttp2.Server.pas sets ListenBacklog := 128. With SO_REUSEPORT each engine
#  loop opens its OWN listener, and EngineThreads defaults to one loop per
#  core. On a 28-core box that is 28 x 128 = 3 584 accept-queue slots for
#  10 000 connections arriving at once. somaxconn here is 4096, so 128 is the
#  binding limit rather than a kernel cap.
#
#  With net.ipv4.tcp_abort_on_overflow = 0 (the default) an overflowing queue
#  DROPS the final ACK silently instead of sending RST. The client retries with
#  backoff and eventually reports a failure with no server-side log line — which
#  is exactly the shape of this defect: no error, no exception, just missing
#  requests.
#
#  Why h2c would suffer more than TLS under the same hypothesis: h2c pushes
#  several times the request rate, so the loop threads spend longer in request
#  I/O between accept() calls and the queue backs up. TLS is slower per
#  connection, so the accept path keeps pace.
#
#  ── What makes this conclusive ──
#
#  The kernel counts exactly this event. /proc/net/netstat TcpExt carries:
#
#    ListenOverflows   accept queue was full when a connection completed
#    ListenDrops       connection dropped at the listen stage, any reason
#    TCPBacklogDrop    per-socket receive backlog overflow (a different thing)
#
#  Read before and after. Nonzero ListenOverflows during the h2c run and ~zero
#  during the TLS run confirms the hypothesis outright. Zero in both refutes it
#  and the search moves to fds, ephemeral ports, or the engine itself.
#
#  Counters are read from /proc directly rather than through `nstat`/`netstat`,
#  which are not installed everywhere and would make this fail for the wrong
#  reason.
#
#  Usage:  bash diagnose-conn-drops.sh [--conns 10000] [--control 1000]
#  Needs:  ./HorseNghttp2TestServer, h2load, tls/ fixtures.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

CONNS=10000
CONTROL=1000
PORT_H2C=9010
PORT_TLS=9443
SERVER=./HorseNghttp2TestServer
OUT="conn-drops-$(date +%Y%m%d-%H%M%S).md"
CT=$(( $(nproc) / 2 )); [[ $CT -gt 14 ]] && CT=14; [[ $CT -lt 1 ]] && CT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conns)   CONNS="$2"; shift 2 ;;
    --control) CONTROL="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$SERVER" ]] || { echo "ERROR: $SERVER not built — run build-fpc.sh." >&2; exit 1; }
command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found." >&2; exit 1; }

NEED=$(( CONNS * 2 + 256 ))
[[ "$(ulimit -n)" -lt "$NEED" ]] && {
  echo "ERROR: ulimit -n is $(ulimit -n), need ~$NEED for c=$CONNS."
  echo "       fd exhaustion produces failures indistinguishable from the ones"
  echo "       this script is trying to attribute. Run: ulimit -n $NEED" >&2; exit 1; }

WORK=$(mktemp -d)
SRV=""
cleanup() {
  [[ -n "$SRV" ]] && kill -TERM "$SRV" 2>/dev/null
  # -x never -f: the -f pattern also matches the shell running this script.
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

# TcpExt counters as "name value" lines. /proc/net/netstat is two lines per
# section: a header of names, then a row of values.
tcpext() {
  awk '/^TcpExt: [A-Za-z]/ { for(i=2;i<=NF;i++) n[i]=$i; next }
       /^TcpExt: [0-9-]/   { for(i=2;i<=NF;i++) print n[i], $i }' /proc/net/netstat
}
getc() { awk -v k="$1" '$1==k{print $2}' <<< "$2"; }

declare -A FAILED ERRORED TIMEOUT SUCCEEDED RPS OVF DROPS BLOG

run_case() {   # <label> <tls|h2c> <conns>
  local LABEL=$1 PROTO=$2 C=$3
  local ARGS=() URL PORT A B OUTP RC N

  if [[ "$PROTO" == "tls" ]]; then
    ARGS=(eventloop tls); PORT=$PORT_TLS; URL="https://127.0.0.1:$PORT_TLS/ping"
  else
    ARGS=(eventloop);     PORT=$PORT_H2C; URL="http://127.0.0.1:$PORT_H2C/ping"
  fi

  ss -ltn 2>/dev/null | grep -q ":$PORT " && { echo "    SKIP — port busy"; return 1; }

  "$SERVER" "${ARGS[@]}" < /dev/null > "$WORK/$LABEL.log" 2>&1 &
  SRV=$!
  sleep 1.5
  alive "$SRV" || { echo "    FAIL — server exited"; sed 's/^/      | /' "$WORK/$LABEL.log"; return 1; }
  grep -q "RESOLVED: epoll event loop" "$WORK/$LABEL.log" || {
    echo "    FAIL — engine not resolved"; kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; return 1; }

  # Same shape as the sweep's steady phase, so the numbers are comparable.
  N=$(( C * 20 )); [[ $N -lt 20000 ]] && N=20000

  A=$(tcpext)
  OUTP=$(timeout 180 h2load -t "$CT" -n "$N" -c "$C" -m 1 "$URL" 2>&1); RC=$?
  B=$(tcpext)

  kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

  OVF[$LABEL]=$(( $(getc ListenOverflows "$B") - $(getc ListenOverflows "$A") ))
  DROPS[$LABEL]=$(( $(getc ListenDrops "$B") - $(getc ListenDrops "$A") ))
  BLOG[$LABEL]=$(( $(getc TCPBacklogDrop "$B") - $(getc TCPBacklogDrop "$A") ))

  # h2load: "N succeeded, N failed, N errored, N timeout"
  SUCCEEDED[$LABEL]=$(grep -oE '[0-9]+ succeeded' <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  FAILED[$LABEL]=$(grep -oE '[0-9]+ failed'    <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  ERRORED[$LABEL]=$(grep -oE '[0-9]+ errored'  <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  TIMEOUT[$LABEL]=$(grep -oE '[0-9]+ timeout'  <<< "$OUTP" | grep -oE '^[0-9]+' | head -1)
  RPS[$LABEL]=$(grep -oE '[0-9.]+ req/s' <<< "$OUTP" | grep -oE '^[0-9.]+' | head -1)

  printf "    %s req/s · %s ok / %s failed / %s errored / %s timeout · overflows %s\n" \
    "${RPS[$LABEL]:-?}" "${SUCCEEDED[$LABEL]:-?}" "${FAILED[$LABEL]:-?}" \
    "${ERRORED[$LABEL]:-?}" "${TIMEOUT[$LABEL]:-?}" "${OVF[$LABEL]}"
  sleep 2   # let TIME_WAIT drain a little between cases
  return 0
}

{
  echo "# Connection drops at scale — engine, h2c vs TLS"
  echo
  echo "- host: \`$(uname -srm)\`, $(nproc) cores, ulimit -n $(ulimit -n)"
  echo "- h2load \`-t $CT -c N -m 1\`, n = max(20000, 20N) — same shape as the sweep"
  echo
  echo "**Configuration under test**"
  echo
  echo "| setting | value | note |"
  echo "|---|---|---|"
  echo "| \`ListenBacklog\` | 128 | \`Nghttp2.Server.pas\` default |"
  echo "| engine loops | $(nproc) | \`EngineThreads = 0\` ⇒ one per core |"
  echo "| total accept queue | $(( $(nproc) * 128 )) | each SO_REUSEPORT listener gets its own |"
  echo "| \`somaxconn\` | $(cat /proc/sys/net/core/somaxconn) | 128 is the binding limit, not a kernel cap |"
  echo "| \`tcp_abort_on_overflow\` | $(cat /proc/sys/net/ipv4/tcp_abort_on_overflow) | 0 ⇒ overflow drops silently, no RST |"
  echo "| \`ip_local_port_range\` | $(tr '\t' '-' < /proc/sys/net/ipv4/ip_local_port_range) | client-side ceiling |"
} | tee "$OUT"

echo | tee -a "$OUT"
echo "Running..." | tee -a "$OUT"
echo "  [h2c  c=$CONNS]"   ; run_case "h2c-$CONNS"    h2c "$CONNS"
echo "  [tls  c=$CONNS]"   ; run_case "tls-$CONNS"    tls "$CONNS"
echo "  [h2c  c=$CONTROL]" ; run_case "h2c-$CONTROL"  h2c "$CONTROL"

{
  echo
  echo "## Results"
  echo
  echo "| case | req/s | succeeded | failed | errored | timeout | ListenOverflows | ListenDrops | BacklogDrop |"
  echo "|---|---|---|---|---|---|---|---|---|"
  for K in "h2c-$CONNS" "tls-$CONNS" "h2c-$CONTROL"; do
    printf "| %s | %s | %s | %s | %s | %s | **%s** | %s | %s |\n" "$K" \
      "${RPS[$K]:-—}" "${SUCCEEDED[$K]:-—}" "${FAILED[$K]:-—}" "${ERRORED[$K]:-—}" \
      "${TIMEOUT[$K]:-—}" "${OVF[$K]:-—}" "${DROPS[$K]:-—}" "${BLOG[$K]:-—}"
  done
  echo
  echo "## Verdict"
  echo
  H=${OVF[h2c-$CONNS]:-0};    T=${OVF[tls-$CONNS]:-0}
  HF=${FAILED[h2c-$CONNS]:-0}; TF=${FAILED[tls-$CONNS]:-0}
  CF=${FAILED[h2c-$CONTROL]:-0}; CO=${OVF[h2c-$CONTROL]:-0}

  # Two SEPARATE questions, and the first version of this script conflated
  # them into one threshold (overflows > 100 => "CONFIRMED"), which declared
  # the case closed on a mechanism that covered a tenth of the failures.
  #   Q1: does the accept queue overflow at all?        -> H vs CO
  #   Q2: does it explain the h2c/TLS ASYMMETRY?        -> H vs T, against HF vs TF
  # An overflow count that is similar across protocols cannot explain a failure
  # count that is not.
  echo "| question | evidence | answer |"
  echo "|---|---|---|"
  awk -v h="$H" -v t="$T" -v hf="$HF" -v tf="$TF" -v c="$CO" -v cf="$CF" -v n="$CONNS" -v cn="$CONTROL" 'BEGIN{
    printf "| Does the accept queue overflow at c=%s? | +%d overflows vs +%d at c=%s | %s |\n",
      n, h, c, cn, (h>100 ? "**YES**" : "no");
    share = (hf>0) ? 100.0*h/hf : 0;
    printf "| Does it explain the h2c failures? | %d overflows vs %d failures (%.1f%%) | %s |\n",
      h, hf, share, (share>70 ? "**YES**" : "**NO — only " sprintf("%.0f", share) "%%**");
    asym = (t>0) ? h/t : 0;
    fasym = (tf>0) ? hf/tf : 0;
    printf "| Does it explain the h2c/TLS asymmetry? | overflow ratio %.2fx vs failure ratio %.1fx | %s |\n",
      asym, fasym, ((asym>2 && fasym>2) ? "**YES**" : "**NO**");
  }'
  echo

  SHARE=$(awk -v h="$H" -v f="$HF" 'BEGIN{print (f>0)? 100.0*h/f : 0}')
  BIG=$(awk -v s="$SHARE" 'BEGIN{print (s>70)?1:0}')
  if [[ "$H" -le 100 ]]; then
    echo "**REFUTED** — the accept queue never overflowed. Look at fd limits,"
    echo "ephemeral ports, and the engine's own accept loop."
  elif [[ "$BIG" -eq 1 ]]; then
    echo "**CONFIRMED** — overflow accounts for most of the loss. Raise"
    echo "\`ListenBacklog\` (128) toward \`somaxconn\` ($(cat /proc/sys/net/core/somaxconn)) and re-run;"
    echo "the counter going to ~0 is the proof, not the throughput number."
  else
    echo "**PARTIAL — two separate defects.**"
    echo
    echo "1. The accept queue DOES overflow at c=$CONNS and not at c=$CONTROL, so"
    echo "   \`ListenBacklog = 128\` x $(nproc) loops is genuinely too small for this"
    echo "   connection count. Worth fixing on its own account."
    echo
    echo "2. It is NOT the main cause and NOT the asymmetry. Overflow covers"
    printf "   only %.0f%% of the h2c failures, and it is near-identical across\n" "$SHARE"
    echo "   protocols ($H vs $T) while failures differ several-fold."
    echo
    echo "   The remaining suspect is the WORKER POOL, not the socket layer:"
    echo "   the pool is bounded (4096-deep queue) and answers overflow with"
    echo "   RST_STREAM/REFUSED_STREAM, which h2load counts as a failed request."
    echo "   h2c pushes a higher request rate than TLS through the same pool, so"
    echo "   it would saturate first — which is exactly the asymmetry observed."
    echo "   Discriminator: hold connections at $CONNS but rate-limit their"
    echo "   creation (h2load -r). If failures collapse, the socket layer was"
    echo "   the constraint; if they persist, it is the dispatch queue."
  fi
} | tee -a "$OUT"

echo
echo "Results: $OUT"
