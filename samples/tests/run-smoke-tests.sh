#!/usr/bin/env bash
# =============================================================================
#  run-smoke-tests.sh
#  curl-driven HTTP/2 smoke suite against HorseNghttp2TestServer.
#
#  Auto-detects transport from the HOST env var:
#    HOST=http://…    → h2c (prior-knowledge, --http2-prior-knowledge)
#    HOST=https://…   → h2 over TLS (--http2 --insecure for self-signed)
#
#  Requires: bash, curl (built with HTTP/2 support — `curl --version | grep HTTP2`).
#
#  Usage:
#    ./run-smoke-tests.sh                                    # h2c, localhost:9010
#    HOST=http://192.168.1.5:9010 ./run-smoke-tests.sh       # h2c custom host
#    HOST=https://127.0.0.1:9443 ./run-smoke-tests.sh        # h2 over TLS (native suite)
#
#  Server:
#    HorseNghttp2TestServer.exe          → h2c on port 9010
#    HorseNghttp2TestServer.exe tls      → h2 over TLS on port 9443 (needs tls/cert.pem + key.pem)
#
#  Exit code = number of failed tests. 0 = all pass.
# =============================================================================

set -uo pipefail

HOST="${HOST:-http://localhost:9010}"
FAILED=0
PASSED=0

# ── Transport auto-detection ──────────────────────────────────────────────
# https:// → h2 over TLS with --insecure (self-signed cert is normal for test)
# http://  → h2c prior-knowledge
if [[ "$HOST" == https://* ]]; then
  H2_MODE="tls"
  CURL_H2_FLAGS=(--http2 --insecure)
else
  H2_MODE="h2c"
  CURL_H2_FLAGS=(--http2-prior-knowledge)
fi

# ── Sanity check ──────────────────────────────────────────────────────────
if ! curl --version | grep -q HTTP2; then
  echo "ERROR: curl was built WITHOUT HTTP/2 support." >&2
  echo "       Install a newer curl (>= 7.47) with nghttp2 linked." >&2
  exit 2
fi

echo "Target:    $HOST"
echo "Transport: $H2_MODE (curl flags: ${CURL_H2_FLAGS[*]})"
echo

# ── Test primitive ────────────────────────────────────────────────────────
# expect_body <name> <method> <path> <expected> [curl extra args...]

expect_body() {
  local name=$1 method=$2 path=$3 expected=$4
  shift 4

  local actual
  actual=$(curl -sS "${CURL_H2_FLAGS[@]}" \
    -X "$method" "${@}" "$HOST$path" 2>&1) || {
    echo "✗ $name  (curl failed: $actual)"
    FAILED=$((FAILED + 1))
    return
  }

  if [[ "$actual" == "$expected" ]]; then
    echo "✓ $name"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAILED=$((FAILED + 1))
  fi
}

# expect_status <name> <method> <path> <expected_status> [extra args...]
expect_status() {
  local name=$1 method=$2 path=$3 expected=$4
  shift 4

  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' "${CURL_H2_FLAGS[@]}" \
    -X "$method" "${@}" "$HOST$path" 2>&1) || {
    echo "✗ $name  (curl failed: $status)"
    FAILED=$((FAILED + 1))
    return
  }

  if [[ "$status" == "$expected" ]]; then
    echo "✓ $name  (HTTP $status)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name  (expected $expected, got $status)"
    FAILED=$((FAILED + 1))
  fi
}

# expect_header <name> <path> <header-name> <expected-value-substring>
expect_header() {
  local name=$1 path=$2 header=$3 expected=$4

  local hval
  hval=$(curl -sS -I "${CURL_H2_FLAGS[@]}" "$HOST$path" 2>&1 \
    | grep -i "^$header:" | sed "s|^$header:[[:space:]]*||i" | tr -d '\r\n')

  if [[ "$hval" == *"$expected"* ]]; then
    echo "✓ $name  ($header: $hval)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name  ($header: '$hval', expected substring '$expected')"
    FAILED=$((FAILED + 1))
  fi
}

# expect_protocol <name> <path>  — verifies the response arrived over HTTP/2
expect_protocol() {
  local name=$1 path=$2

  local proto
  proto=$(curl -sS -o /dev/null -w '%{http_version}' "${CURL_H2_FLAGS[@]}" \
    "$HOST$path" 2>&1)

  if [[ "$proto" == "2" || "$proto" == "2.0" ]]; then
    echo "✓ $name  (HTTP/$proto)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name  (got HTTP/$proto, expected HTTP/2)"
    FAILED=$((FAILED + 1))
  fi
}

# ── The suite ─────────────────────────────────────────────────────────────

echo "Smoke suite against $HOST"
echo "─────────────────────────────────────────────────────────────"

expect_protocol   "HTTP/2 negotiated (prior-knowledge)"  /ping

expect_body       "GET /ping"                    GET  /ping                'pong'
expect_body       "GET /param/:id"               GET  /param/42            'id=42'
expect_body       "GET /param/:a/and/:b"         GET  /param/foo/and/bar   'a=foo,b=bar'
expect_body       "GET /query?name=alice"        GET  '/query?name=alice'  'name=alice'
expect_body       "POST /echo"                   POST /echo                'hello world' -d 'hello world'
expect_body       "POST /echo (JSON)"            POST /echo                '{"k":"v"}'   -H 'Content-Type: application/json' -d '{"k":"v"}'

expect_body       "GET /header-echo (User-Agent)" GET /header-echo         'ua=nghttp2-smoke' -H 'User-Agent: nghttp2-smoke'

expect_header     "GET /custom-header injects X-Custom-Header" \
                                                 /custom-header  \
                                                 'x-custom-header'  'nghttp2'

expect_header     "GET /json → Content-Type application/json" \
                                                 /json           \
                                                 'content-type'  'application/json'
expect_body       "GET /json body"               GET  /json                '{"protocol":"HTTP/2","provider":"nghttp2"}'

expect_status     "GET /error400"                GET  /error400            '400'
expect_status     "GET /nope-not-a-route"        GET  /nope-not-a-route    '404'

expect_body       "GET /large (57344 bytes — multi-DATA frame)" \
                                                 GET  /large  "$(printf 'The quick brown fox jumps over the lazy dog. 0123456789. %.0s' {1..1024})"

expect_body       "GET /cookie-set (route body)" GET  /cookie-set          'cookie-set'
expect_header     "GET /cookie-set → Set-Cookie" /cookie-set  \
                                                 'set-cookie'  'session=abc123'
expect_body       "GET /cookie-echo (Cookie header echoed)" \
                                                 GET /cookie-echo  \
                                                 'cookie=session=abc123'  \
                                                 -H 'Cookie: session=abc123'

# ── Baseline security headers from TResponseBridge.Flush ──────────────────
expect_header     "GET /ping → X-Content-Type-Options: nosniff" \
                                                 /ping  \
                                                 'x-content-type-options'  'nosniff'
expect_header     "GET /ping → X-Frame-Options: DENY" \
                                                 /ping  \
                                                 'x-frame-options'  'DENY'
expect_header     "GET /ping → Cache-Control: no-store" \
                                                 /ping  \
                                                 'cache-control'  'no-store'

echo "─────────────────────────────────────────────────────────────"
echo "Passed: $PASSED   Failed: $FAILED"
exit $FAILED
