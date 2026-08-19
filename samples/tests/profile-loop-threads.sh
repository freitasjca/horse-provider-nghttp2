#!/usr/bin/env bash
# ============================================================================
#  profile-loop-threads.sh — where does the epoll engine's CPU go under TLS,
#  and is that why TLS caps it at ~27k req/s?
#
#  run-tls-sweep.sh found the ceiling: engine h2c is still climbing at
#  c=10 000 (74 549 req/s) while engine TLS flattens from c=1000 onward
#  (23 088 -> 26 939 -> 27 086). Peak threads reads 57 flat in every engine
#  cell, so the loops are a fixed CPU budget — and the obvious conclusion is
#  that record encryption is spending it.
#
#  "Obvious conclusion" is what produced the 22.3x figure and the "free on
#  fast routes" claim, both of which measurement later corrected. So this
#  measures it. It is also why the script runs h2c as a CONTROL rather than
#  profiling TLS alone: the interesting quantity is the DELTA between the two,
#  and a single-mode profile has nothing to subtract.
#
#  ── Two measurements, deliberately in this order ──
#
#  1. USER vs SYSTEM time per thread, from /proc/<pid>/task/<tid>/stat.
#     Free, unbiased, and it splits the hypothesis cleanly:
#
#        TLS adds USER time ....... crypto in OpenSSL. The hypothesis holds.
#        TLS adds SYSTEM time ..... syscalls — more, smaller write()s because
#                                   records are framed differently. The fix is
#                                   buffering, not crypto.
#        neither is saturated ..... the ceiling is NOT loop-thread CPU at all,
#                                   and any code change aimed at it is aimed at
#                                   the wrong thing. Look at memory bandwidth
#                                   (1 270 MB at 10k TLS conns) or the client.
#
#     That third outcome is the one worth taking seriously, and no amount of
#     stack sampling would reveal it — a profiler shows you where the time
#     that IS spent goes, never that there is less of it than you assumed.
#
#  2. Stack samples via gdb, to name functions.
#
#     NEITHER PROFILER WORKS IN THIS CONTAINER — probed at startup and stated
#     in the report rather than left to show as an empty table.
#
#     PERF IS NOT AVAILABLE HERE. WSL2 exposes no PMU: `perf record` fails with
#     "No permission to enable cycles:Pu event" even as root, and the packaged
#     perf is built for 6.8 against a 6.18 kernel. gdb attach-and-backtrace is
#     the fallback.
#
#     Read the histogram with its bias in mind. Attaching STOPS the process for
#     tens of milliseconds, so threads are caught disproportionately at points
#     where they park — epoll_wait, recv, the queue lock. A leaf that is hot
#     because it BLOCKS looks identical to one that is hot because it COMPUTES.
#     Measurement 1 is what separates those; this one only names the code.
#
#  Usage:  bash profile-loop-threads.sh [--conns 1000] [--secs 8] [--samples 15]
#  Needs:  ./HorseNghttp2TestServer, h2load, gdb, tls/ fixtures.
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

CONNS=1000
# h2load defaults to ONE thread and pegs one core. run-tls-sweep.sh was fixed
# for this; THIS script was not, and its own "h2load CPU%" column read 111.9%
# in the run that exposed it — the guard was reporting the fault while the
# load stayed single-threaded. A client-bound profile still answers "is any
# server thread saturated" (nothing is), but it cannot answer "where does the
# CPU go at real load", because real load never arrives.
CLIENT_THREADS=$(( $(nproc) / 2 )); [[ $CLIENT_THREADS -gt 14 ]] && CLIENT_THREADS=14
[[ $CLIENT_THREADS -lt 1 ]] && CLIENT_THREADS=1
SECS=8
SAMPLES=15
ROUTE=/ping
PORT_H2C=9010
PORT_TLS=9443
SERVER=./HorseNghttp2TestServer
OUT="loop-profile-$(date +%Y%m%d-%H%M%S).md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conns)   CONNS="$2"; shift 2 ;;
    --secs)    SECS="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --client-threads) CLIENT_THREADS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$SERVER" ]] || { echo "ERROR: $SERVER not built — run build-fpc.sh." >&2; exit 1; }
command -v h2load > /dev/null 2>&1 || { echo "ERROR: h2load not found." >&2; exit 1; }
command -v gdb    > /dev/null 2>&1 || { echo "ERROR: gdb not found (apt install gdb)." >&2; exit 1; }

WORK=$(mktemp -d)
SRV=""; LOAD=""
cleanup() {
  [[ -n "$LOAD" ]] && kill -TERM "$LOAD" 2>/dev/null
  [[ -n "$SRV"  ]] && kill -TERM "$SRV"  2>/dev/null
  # -x, never -f: `pkill -f HorseNghttp2TestServer` also matches the shell
  # running THIS script, because the pattern appears in its own command line.
  # That kills the caller, and the symptom is an immediate exit with no output.
  pkill -x HorseNghttp2TestServer 2>/dev/null
  rm -rf "$WORK"
}
on_int() { echo; echo "Interrupted."; cleanup; exit 130; }
trap cleanup EXIT
trap on_int INT TERM

# Write to the console AND the report. Deliberately not `run_mode | tee`:
# a pipeline runs the function in a SUBSHELL, and every USR/SYS/TOT assignment
# would be discarded on exit — the same defect that once made check-loop-thread
# print a table and a verdict that contradicted it.
say() { echo "$*"; echo "$*" >> "$OUT"; }

alive() {
  local pid=$1 st
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  [[ "$st" != "Z" ]]
}

HZ=$(getconf CLK_TCK)

# Can gdb attach AT ALL? Probe once, on a throwaway child, before any load
# runs. Without this the stack section silently prints "no samples", which
# reads as "nothing was caught" when the truth is "this can never work here".
#
# Two independent blockers, and the second is not fixable from inside:
#   yama.ptrace_scope=1 ... attach limited to descendants; sudo normally lifts it
#   seccomp             ... the container profile can deny the ptrace syscall
#                           outright, and then even root gets
#                           "ptrace: Inappropriate ioctl for device"
PTRACE_OK=0
PTRACE_WHY=""
probe_ptrace() {
  sleep 30 & local victim=$!
  local out
  out=$(timeout 15 gdb -p "$victim" -batch -nx -ex "set pagination off" -ex "bt 1" 2>&1)
  kill -TERM "$victim" 2>/dev/null
  if grep -q '^#0' <<< "$out"; then PTRACE_OK=1; return; fi
  if grep -qi 'Inappropriate ioctl' <<< "$out"; then
    PTRACE_WHY="the ptrace syscall is denied (container seccomp) — root does not help"
  elif grep -qi 'ptrace_scope' <<< "$out"; then
    PTRACE_WHY="yama.ptrace_scope=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null) blocks attach; try sudo, or sysctl -w kernel.yama.ptrace_scope=0"
  else
    PTRACE_WHY="gdb could not attach: $(head -1 <<< "$out")"
  fi
}
probe_ptrace

# utime/stime per thread. Split on the LAST ')' — comm can contain spaces and
# parentheses, so column indexing off the front is wrong.
snap() {   # <pid> -> "tid utime stime" per line
  local pid=$1 t tid rest u s
  for t in /proc/"$pid"/task/*/; do
    tid=${t%/}; tid=${tid##*/}
    rest=$(cat "$t/stat" 2>/dev/null) || continue
    rest=${rest##*') '}
    u=$(awk '{print $12}' <<< "$rest")
    s=$(awk '{print $13}' <<< "$rest")
    echo "$tid ${u:-0} ${s:-0}"
  done
}

# Whole-process CPU ticks (utime+stime, all threads) for any pid.
proc_ticks() {
  local pid=$1 rest
  rest=$(cat "/proc/$pid/stat" 2>/dev/null) || { echo 0; return; }
  rest=${rest##*') '}
  awk '{print $12 + $13}' <<< "$rest"
}

declare -A USR SYS TOT NTHREAD BUSY CLI

run_mode() {   # <h2c|tls>
  local MODE=$1
  local ARGS=() URL PORT A B RESOLVED

  if [[ "$MODE" == "tls" ]]; then
    ARGS=(eventloop tls); PORT=$PORT_TLS; URL="https://127.0.0.1:$PORT_TLS$ROUTE"
  else
    ARGS=(eventloop);     PORT=$PORT_H2C; URL="http://127.0.0.1:$PORT_H2C$ROUTE"
  fi

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    say "  SKIP — port $PORT busy"; return 1
  fi

  "$SERVER" "${ARGS[@]}" < /dev/null > "$WORK/$MODE.log" 2>&1 &
  SRV=$!
  sleep 1.5

  alive "$SRV" || { say "  FAIL — server exited"; sed 's/^/    | /' "$WORK/$MODE.log"; return 1; }

  # Same gate as every other harness here: `eventloop` degrades silently, and
  # profiling the thread driver while believing it is the engine would send
  # the conclusion in the wrong direction entirely.
  RESOLVED=$(grep -oE 'RESOLVED: .*' "$WORK/$MODE.log" | head -1)
  if [[ "$RESOLVED" != *"epoll event loop"* ]]; then
    say "  FAIL — engine not resolved, got: ${RESOLVED:-nothing}"
    kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; return 1
  fi

  # h2load's OWN duration mode (-D), not a request count.
  #
  # This was `-n $(( 40000 * (SECS+6) ))` — a request count sized from an
  # ASSUMED throughput. The assumption was 40k req/s; the engine actually does
  # 92k at c=1000 h2c, so the run finished in 6s against a 10.5s window and
  # both modes aborted with "h2load finished before the window closed".
  #
  # Deriving n from a guessed rate is the same defect twice over: guess too
  # low and the server is idle for part of the window, guess too high and the
  # run outlives the harness. -D removes the estimate — h2load stops on the
  # clock, so the load is guaranteed to span the sampling window AND the stack
  # sampling that follows it, whatever the server turns out to be capable of.
  local DUR=$(( SECS + 40 ))     # covers ramp + /proc window + gdb samples
  local CT=$CLIENT_THREADS
  [[ $CT -gt $CONNS ]] && CT=$CONNS
  timeout $(( DUR + 30 )) h2load -D "$DUR" -t "$CT" -c "$CONNS" -m 1 \
    "$URL" > "$WORK/$MODE.h2load" 2>&1 &
  LOAD=$!
  sleep 2.5      # let the ramp and the handshakes finish

  # h2load itself, so the client can be ruled in or out as the constraint.
  # check-loop-thread.sh's own verdict text says to "check whether h2load is
  # pegged before changing anything server-side" — and the first version of
  # THIS script did not measure it, which is how a 22.5%-of-the-box server
  # nearly got a code change aimed at it. LOAD is the `timeout` wrapper; the
  # client is its child.
  local CPID CA CB
  CPID=$(pgrep -P "$LOAD" h2load 2>/dev/null | head -1)
  CA=$(proc_ticks "${CPID:-0}")

  A=$(snap "$SRV")
  sleep "$SECS"
  B=$(snap "$SRV")
  CB=$(proc_ticks "${CPID:-0}")
  CLI[$MODE]=$(awk -v d="$(( CB - CA ))" -v hz="$HZ" -v sec="$SECS" \
                  'BEGIN{printf "%.1f", (d/hz)/sec*100}')

  local LOAD_ALIVE=1
  alive "$LOAD" || LOAD_ALIVE=0

  # ── Stack samples, while the load is still on ──
  : > "$WORK/$MODE.stacks"
  if [[ $LOAD_ALIVE -eq 1 && $PTRACE_OK -eq 1 ]]; then
    local i
    for ((i=0; i<SAMPLES; i++)); do
      # stderr kept: a silent failure here is what made section 3 look empty
      timeout 20 gdb -p "$SRV" -batch -nx \
        -ex "set pagination off" -ex "set confirm off" \
        -ex "thread apply all bt 1" >> "$WORK/$MODE.stacks" 2>&1
      sleep 0.15
    done
  fi

  kill -TERM "$LOAD" 2>/dev/null; LOAD=""
  kill -TERM "$SRV"  2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

  if [[ $LOAD_ALIVE -eq 0 ]]; then
    say "  INVALID — h2load finished before the window closed; raise --secs"
    return 1
  fi

  # ── Aggregate the per-thread CPU ──
  local ROWS
  ROWS=$(while read -r tid u s; do
    local pu ps
    pu=$(awk -v t="$tid" '$1==t{print $2}' <<< "$A")
    ps=$(awk -v t="$tid" '$1==t{print $3}' <<< "$A")
    [[ -z "${pu:-}" ]] && continue
    awk -v du="$(( u - pu ))" -v ds="$(( s - ps ))" -v hz="$HZ" -v sec="$SECS" -v tid="$tid" \
      'BEGIN{ up=(du/hz)/sec*100; sp=(ds/hz)/sec*100; printf "%.1f %.1f %.1f %s\n", up+sp, up, sp, tid }'
  done <<< "$B")

  read -r TOTP USRP SYSP NT NB < <(awk '{t+=$1; u+=$2; s+=$3; n++; if($1>20) b++}
    END{printf "%.1f %.1f %.1f %d %d", t+0, u+0, s+0, n+0, b+0}' <<< "$ROWS")

  TOT[$MODE]=$TOTP; USR[$MODE]=$USRP; SYS[$MODE]=$SYSP
  NTHREAD[$MODE]=$NT; BUSY[$MODE]=$NB

  echo "$ROWS" | sort -rn > "$WORK/$MODE.rows"
  local RPS
  RPS=$(grep -oE '[0-9.]+ req/s' "$WORK/$MODE.h2load" 2>/dev/null | grep -oE '^[0-9.]+' | head -1)
  say "  ${RPS:-?} req/s   total CPU ${TOTP}%  (user ${USRP}%  sys ${SYSP}%)   ${NB} threads >20%"
  return 0
}

{
  echo "# Where the engine's CPU goes — TLS vs h2c"
  echo
  echo "- host: \`$(uname -srm)\`, $(nproc) cores"
  echo "- load: h2load \`-t $CLIENT_THREADS -c $CONNS -m 1\`, sampling ${SECS}s, $SAMPLES stack samples"
  echo "- both modes run the epoll engine; only the protocol differs"
  echo
  echo "perf is unavailable (WSL2 exposes no PMU), so stacks come from gdb"
  echo "attach-and-backtrace. Attaching stops the process, so the stack"
  echo "histogram is biased toward threads parked in blocking calls. The"
  echo "user/system split below is unbiased and is what carries the argument."
} | tee "$OUT"

echo | tee -a "$OUT"
echo "Running h2c (control)..." | tee -a "$OUT"
run_mode h2c; OK_H2C=$?
sleep 1
echo "Running tls..." | tee -a "$OUT"
run_mode tls; OK_TLS=$?

{
  echo
  echo "## 1. CPU split (unbiased, from /proc)"
  echo
  echo "| mode | server CPU% | user% | sys% | threads | >20% | **h2load CPU%** |"
  echo "|---|---|---|---|---|---|---|"
  for M in h2c tls; do
    printf "| %s | %s | %s | %s | %s | %s | %s |\n" "$M" \
      "${TOT[$M]:-—}" "${USR[$M]:-—}" "${SYS[$M]:-—}" "${NTHREAD[$M]:-—}" "${BUSY[$M]:-—}" \
      "${CLI[$M]:-—}"
  done
  echo
  echo "h2load runs on this same box and is part of the system under test."
  for M in h2c tls; do
    [[ -n "${CLI[$M]:-}" ]] || continue
    awk -v c="${CLI[$M]}" -v m="$M" -v t="$CLIENT_THREADS" 'BEGIN{
      cap = t * 100;
      if (c > cap * 0.9)
        printf "  %-4s CLIENT SATURATED (%.0f%% of a %d-thread ceiling of %d%%) — every\n         server figure here is a LOWER BOUND; raise --client-threads.\n", m, c, t, cap;
      else
        printf "  %-4s client at %.0f%% of %d%% ceiling — not the constraint.\n", m, c, cap;
    }'
  done
  echo
  if [[ -n "${TOT[h2c]:-}" && -n "${TOT[tls]:-}" ]]; then
    awk -v uh="${USR[h2c]}" -v ut="${USR[tls]}" -v sh="${SYS[h2c]}" -v st="${SYS[tls]}" \
        -v th="${TOT[h2c]}" -v tt="${TOT[tls]}" -v cores="$(nproc)" 'BEGIN{
      du = ut - uh; ds = st - sh; dt = tt - th;
      printf "TLS adds %.1f%% CPU overall: %.1f%% user, %.1f%% system.\n\n", dt, du, ds;
      if (dt <= 0)
        print "TLS did not add measurable CPU. The ceiling is NOT loop-thread CPU — do not go looking for a hot function.";
      else if (du > ds * 2)
        print "Dominated by USER time -> crypto. The record-encryption hypothesis holds.";
      else if (ds > du * 2)
        print "Dominated by SYSTEM time -> syscalls, not crypto. TLS reframes writes; the fix is buffering, not a faster cipher.";
      else
        print "User and system both rose materially. Neither half alone explains it; read the stacks before choosing a fix.";
      printf "\nCeiling check: %.0f%% of %d cores is %.1f%% of the box.\n", tt, cores, tt/cores;
      print "A total far below 100% x cores with throughput flat means the";
      print "constraint is off-CPU — memory bandwidth, the client, or the loopback.";
    }'
  fi

  echo
  echo "## 2. Busiest threads"
  echo
  for M in h2c tls; do
    [[ -f "$WORK/$M.rows" ]] || continue
    echo "### $M"
    echo
    echo "| CPU% | user% | sys% | tid |"
    echo "|---|---|---|---|"
    awk '$1>1 {printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}' "$WORK/$M.rows" | head -12
    echo
  done

  echo "## 3. Stack samples (gdb — biased toward blocking points)"
  echo
  if [[ $PTRACE_OK -eq 0 ]]; then
    echo "**UNAVAILABLE on this host** — $PTRACE_WHY"
    echo
    echo "perf is out too (no PMU under the WSL2 kernel), so there is no way to"
    echo "sample stacks from inside this container. That is a limitation of the"
    echo "environment, not a missing result: section 1 needs no profiler and is"
    echo "what decides whether a hot spot exists at all. To get stacks, run this"
    echo "script on a host where ptrace is permitted."
    echo
  fi
  for M in h2c tls; do
    [[ -s "$WORK/$M.stacks" ]] || { echo "### $M — no samples"; echo; continue; }
    echo "### $M"
    echo
    echo "| count | leaf frame |"
    echo "|---|---|"
    sed -nE 's/^#0[[:space:]]+(0x[0-9a-f]+ in )?([A-Za-z_][A-Za-z0-9_.:$@]*).*/\2/p' "$WORK/$M.stacks" \
      | sort | uniq -c | sort -rn | head -15 \
      | awk '{printf "| %s | `%s` |\n", $1, $2}'
    echo
  done

  echo "## How to act on this"
  echo
  echo "Section 1 decides WHETHER there is a hot spot to chase; section 3 only"
  echo "names it. If total CPU is well under the box's capacity while throughput"
  echo "is flat, no function-level change will move the ceiling and the next"
  echo "measurement belongs elsewhere — memory bandwidth first, given TLS at"
  echo "c=10 000 peaked at 1 270 MB against 542 MB for h2c."
} | tee -a "$OUT"

echo
echo "Results: $OUT"
[[ $OK_H2C -eq 0 && $OK_TLS -eq 0 ]] || echo "NOTE: at least one mode did not complete cleanly — see above."
