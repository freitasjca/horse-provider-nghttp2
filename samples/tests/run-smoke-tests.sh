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

# ── Timeouts ──────────────────────────────────────────────────────────────
# Without these the suite hangs forever and prints nothing when the server is
# not listening: Windows Firewall drops unsolicited inbound rather than
# rejecting it, so there is no RST to end curl's connect. A dead server has to
# look like a failure, not a stall. Every response in this suite is served in
# milliseconds, so these bounds only ever fire on a genuine fault.
CURL_H2_FLAGS+=(--connect-timeout 5 --max-time 15)

# ── Sanity check ──────────────────────────────────────────────────────────
if ! curl --version | grep -q HTTP2; then
  echo "ERROR: curl was built WITHOUT HTTP/2 support." >&2
  echo "       Install a newer curl (>= 7.47) with nghttp2 linked." >&2
  exit 2
fi

echo "Target:    $HOST"
echo "Transport: $H2_MODE (curl flags: ${CURL_H2_FLAGS[*]})"
echo

# ── Reachability pre-flight ───────────────────────────────────────────────
# One probe before the suite, so an unreachable server reports itself once and
# plainly instead of as N indistinguishable test failures.
if ! curl -sS -o /dev/null "${CURL_H2_FLAGS[@]}" "$HOST/ping" 2>/dev/null; then
  echo "ERROR: cannot reach $HOST/ping" >&2
  echo "       Is HorseNghttp2TestServer running, and on the right port?" >&2
  echo "       Reaching a Windows host from WSL: use the host IP, not localhost," >&2
  echo "       and allow the port through Windows Firewall — it DROPS unsolicited" >&2
  echo "       inbound rather than rejecting it, so a blocked port looks like a" >&2
  echo "       hang rather than a refusal." >&2
  exit 2
fi

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

  # Repeated headers are joined with ' | ' rather than concatenated: deleting
  # the newlines outright ran adjacent values together ("HttpOnlyuser=tester"),
  # which read like a server bug in the output and could let a substring match
  # across the seam. Use expect_header_count to assert how many there are.
  local hval
  hval=$(curl -sS -I "${CURL_H2_FLAGS[@]}" "$HOST$path" 2>&1 \
    | grep -i "^$header:" | sed "s|^$header:[[:space:]]*||i" | tr -d '\r' \
    | paste -sd'|' - | sed 's/|/ | /g')

  if [[ "$hval" == *"$expected"* ]]; then
    echo "✓ $name  ($header: $hval)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name  ($header: '$hval', expected substring '$expected')"
    FAILED=$((FAILED + 1))
  fi
}

# expect_header_count <name> <path> <header-name> <expected-count>
# Asserts how many times a header appears, which a value match cannot do.
# FIX-HEADER-DUP is precisely about Set-Cookie surviving as separate headers
# rather than being folded into one, and a substring test passes either way —
# both values are present whether they arrived as two headers or one merged
# one. Only the count tells those apart.
expect_header_count() {
  local name=$1 path=$2 header=$3 expected=$4

  local count
  count=$(curl -sS -I "${CURL_H2_FLAGS[@]}" "$HOST$path" 2>/dev/null \
    | grep -ci "^$header:")

  if [[ "$count" == "$expected" ]]; then
    echo "✓ $name  ($header x$count)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name  ($header appeared $count time(s), expected $expected)"
    FAILED=$((FAILED + 1))
  fi
}

# expect_body_size <name> <path> <expected-bytes>
# For bodies too large to compare literally. The point of the large-body test
# is that every DATA frame arrived and was reassembled, which a byte count
# establishes just as well as a 64 KB string literal would — without putting
# one in the source.
expect_body_size() {
  local name=$1 path=$2 expected=$3

  local size
  size=$(curl -sS "${CURL_H2_FLAGS[@]}" "$HOST$path" 2>/dev/null | wc -c | tr -d ' ')

  if [[ "$size" == "$expected" ]]; then
    echo "✓ $name  ($size bytes)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name  (got $size bytes, expected $expected)"
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

expect_body       "GET /ping"                    GET  /ping   'pong'

# ── Routing: path params, multi params, query string ──────────────────────
expect_body       "GET /params/path/:id"         GET  /params/path/42 \
                  '{"id":"42"}'
expect_body       "GET /params/multi/:a/:b"      GET  /params/multi/foo/bar \
                  '{"a":"foo","b":"bar"}'
expect_body       "GET /params/query"            GET  '/params/query?name=alice&value=wonderland' \
                  '{"name":"alice","value":"wonderland"}'

# ── Request body round-trip ───────────────────────────────────────────────
# The size field is the useful assertion: it proves the DATA frames were
# reassembled to exactly the right length, not merely that some text arrived.
expect_body       "POST /echo/body (text)"       POST /echo/body \
                  '{"size":11,"body":"hello world"}' \
                  -d 'hello world'
# JSON body doubles as a JSON-escaping check — the handler escapes the quotes
# it echoes back, so this fails loudly if escaping regresses on either side.
expect_body       "POST /echo/body (JSON)"       POST /echo/body \
                  '{"size":9,"body":"{\"k\":\"v\"}"}' \
                  -H 'Content-Type: application/json' -d '{"k":"v"}'

# ── Request header round-trip (HPACK decode → Horse → HPACK encode) ───────
expect_body       "GET /headers/echo (body)"     GET  /headers/echo \
                  '{"X-Test-Header":"nghttp2-smoke"}' \
                  -H 'X-Test-Header: nghttp2-smoke'

# ── Response headers set through the RawWebResponse adapter ───────────────
# Covers the path Horse.CORS and horse-security-headers take: middleware
# writing to Res.RawWebResponse.SetCustomHeader rather than Res.AddHeader.
expect_header     "GET /raw/webresponse → X-Via-RawResponse" \
                                                 /raw/webresponse \
                                                 'x-via-rawresponse'  'via-raw'
expect_header     "GET /raw/webresponse → X-Via-AddHeader" \
                                                 /raw/webresponse \
                                                 'x-via-addheader'    'via-add'

# ── Content-Type + status codes ───────────────────────────────────────────
expect_header     "GET /methods/get → Content-Type application/json" \
                                                 /methods/get \
                                                 'content-type'  'application/json'
expect_body       "GET /methods/get body"        GET  /methods/get \
                  '{"method":"GET"}'

expect_status     "GET /status/400"              GET  /status/400          '400'
expect_status     "GET /status/500"              GET  /status/500          '500'
expect_status     "GET /nope-not-a-route"        GET  /nope-not-a-route    '404'

# ── Large response — exercises multi-DATA-frame reassembly ────────────────
expect_body_size  "GET /response/large (multi-DATA frame)"  /response/large  65536

# ── Cookies ───────────────────────────────────────────────────────────────
expect_body       "GET /cookies/set (route body)" GET /cookies/set  'cookies-set'
# FIX-HEADER-DUP: two Set-Cookie headers must survive as two headers. The
# count is the assertion that actually protects that — the value checks below
# would pass just as happily against one merged header carrying both cookies.
expect_header_count "GET /cookies/set → two distinct Set-Cookie headers" \
                                                 /cookies/set  'set-cookie'  2
expect_header     "GET /cookies/set → Set-Cookie session" \
                                                 /cookies/set \
                                                 'set-cookie'  'session=abc123'
expect_header     "GET /cookies/set → Set-Cookie user" \
                                                 /cookies/set \
                                                 'set-cookie'  'user=tester'
expect_body       "GET /cookies/echo (Cookie header parsed)" \
                                                 GET /cookies/echo \
                  '{"session":"abc123","user":"tester"}' \
                  -H 'Cookie: session=abc123; user=tester'

# ── Content-Disposition (download path) ───────────────────────────────────
expect_header     "GET /download → Content-Disposition" \
                                                 /download \
                                                 'content-disposition'  'attachment'

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
