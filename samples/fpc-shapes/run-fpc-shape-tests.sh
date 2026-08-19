#!/usr/bin/env bash
# run-fpc-shape-tests.sh
# Compile + runtime smoke tests for the three FPC app-type shape units.
# Run on Linux with FPC trunk 3.3.1 installed.
#
# Usage:
#   cd patches/horse-provider-nghttp2/samples/fpc-shapes
#   bash run-fpc-shape-tests.sh

set -euo pipefail

TRUNK=${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}
TU=${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}

# Resolve source paths relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_ROOT="$(cd "$SCRIPT_DIR/../../../../" && pwd)"
PROV="$PATCHES_ROOT/patches/horse-provider-nghttp2/src"
DNG="$PATCHES_ROOT/patches/Delphi-nghttp2/src"
HORSE="$PATCHES_ROOT/horse/src"

FPC_FLAGS="-n -MDelphi -O1 -gl -dHORSE_PROVIDER_NGHTTP2 -dHORSE_GRPC_NO_FFI \
  -Fu. -Fu$PROV -Fu$DNG -Fu$HORSE \
  -Fu$TU/rtl -Fu$TU/rtl-console -Fu$TU/rtl-objpas -Fu$TU/rtl-extra \
  -Fu$TU/rtl-generics -Fu$TU/fcl-base -Fu$TU/fcl-web -Fu$TU/fcl-json \
  -Fu$TU/regexpr -Fu$TU/pthreads -Fu$TU/openssl -Fu$TU/fcl-net -Fu$TU/hash"
# HORSE_GRPC_NO_FFI: shape tests exercise lifecycle only (signal handlers,
# Listen/StopListen) — not gRPC dispatch. Suppresses the ffi.manager uses
# in Grpc.Registry so these tests compile without the libffi package.

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

cd "$SCRIPT_DIR"

# ── Unit 1: FPC.Daemon ────────────────────────────────────────────────────────
echo ""
echo "── FPC.Daemon ──────────────────────────────────────────────────────────"

echo "  Compiling TestNghttp2FPCDaemon..."
if $TRUNK $FPC_FLAGS TestNghttp2FPCDaemon.lpr > /tmp/fpc-daemon.log 2>&1; then
  pass "compile"
else
  fail "compile"; cat /tmp/fpc-daemon.log; FAIL=$((FAIL+1)); echo "Skipping runtime."; \
  echo ""; echo "── FPC.HTTPApplication ─────────────────────────────────────────────────"; \
  echo "  Skipped (Daemon compile failed — shared infrastructure)"; \
  echo ""; echo "── FPC.LCL (compile-only) ──────────────────────────────────────────────"; \
  echo "  Compiling TestNghttp2FPCLCL..."; \
  if $TRUNK $FPC_FLAGS -dHORSE_APPTYPE_LCL \
      ${LCL_UNITS:+-Fu$LCL_UNITS} TestNghttp2FPCLCL.lpr \
      > /tmp/fpc-lcl.log 2>&1; then pass "compile"; \
  else grep -qi "Can't find unit Forms\|unit Forms not found" /tmp/fpc-lcl.log && \
      echo "  SKIP  LCL units not in this FPC install (needs Lazarus)" || \
      { fail "compile"; cat /tmp/fpc-lcl.log; }; fi; \
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit $FAIL
fi

echo "  Starting server on port 9210..."
./TestNghttp2FPCDaemon &
SERVER_PID=$!
sleep 0.4

BODY=$(curl -s --http2-prior-knowledge http://localhost:9210/ping 2>/dev/null || true)
if [ "$BODY" = '"pong"' ] || [ "$BODY" = 'pong' ]; then
  pass "GET /ping → pong"
else
  fail "GET /ping (got: '$BODY')"
fi

kill -TERM "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "SIGTERM → exit 0"
else
  fail "SIGTERM → exit $EXIT_CODE (expected 0)"
fi

# ── Unit 2: FPC.HTTPApplication ───────────────────────────────────────────────
echo ""
echo "── FPC.HTTPApplication ─────────────────────────────────────────────────"

echo "  Compiling TestNghttp2FPCHTTPApp..."
if $TRUNK $FPC_FLAGS TestNghttp2FPCHTTPApp.lpr > /tmp/fpc-httpapp.log 2>&1; then
  pass "compile"
else
  fail "compile"; cat /tmp/fpc-httpapp.log
fi

echo "  Starting server on port 9211..."
./TestNghttp2FPCHTTPApp &
SERVER_PID=$!
sleep 0.4

BODY=$(curl -s --http2-prior-knowledge http://localhost:9211/ping 2>/dev/null || true)
if [ "$BODY" = '"pong"' ] || [ "$BODY" = 'pong' ]; then
  pass "GET /ping → pong"
else
  fail "GET /ping (got: '$BODY')"
fi

kill -TERM "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "SIGTERM → exit 0"
else
  fail "SIGTERM → exit $EXIT_CODE (expected 0)"
fi

# ── Unit 3: FPC.LCL (compile-only) ───────────────────────────────────────────
echo ""
echo "── FPC.LCL (compile-only) ──────────────────────────────────────────────"

LCL_UNITS=${LCL_UNITS:-$TU/lcl}

echo "  Compiling TestNghttp2FPCLCL..."
if $TRUNK $FPC_FLAGS -dHORSE_APPTYPE_LCL \
    -Fu$LCL_UNITS TestNghttp2FPCLCL.lpr > /tmp/fpc-lcl.log 2>&1; then
  pass "compile"
elif grep -qi "Can't find unit Forms\|unit Forms not found" /tmp/fpc-lcl.log; then
  echo "  SKIP  LCL units not in this FPC install (needs Lazarus — compile-only test skipped)"
else
  fail "compile"; cat /tmp/fpc-lcl.log
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "FPC shape tests: $PASS passed, $FAIL failed"
exit $FAIL
