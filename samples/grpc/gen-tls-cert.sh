#!/usr/bin/env bash
# ============================================================================
#  gen-tls-cert.sh
#  Generate self-signed test certs for HorseNghttp2GrpcDemo TLS + mTLS modes.
#  (Twin of samples/tests/gen-tls-cert.sh — same shape, scoped to this demo.)
#
#  Produces (all in tls/ next to this script):
#    Server-side TLS (needed for `HorseNghttp2GrpcDemo tls`):
#      cert.pem       — server cert, SAN=127.0.0.1,::1,localhost, 30-day validity
#      key.pem        — server RSA 2048-bit private key (unencrypted)
#    mTLS extras (needed for `HorseNghttp2GrpcDemo mtls`):
#      ca.pem          — self-signed CA (signs the client cert)
#      ca-key.pem      — CA's private key (only used by this script)
#      client-cert.pem — client cert signed by the CA
#      client-key.pem  — client private key (unencrypted)
#
#  Regenerate whenever the cert expires (30 days). Don't ship these files —
#  they're strictly for local testing (SAN=127.0.0.1, not a real hostname).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/tls"

mkdir -p "$CERT_DIR"

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found on PATH." >&2
    echo "  Debian/Ubuntu: apt install openssl" >&2
    echo "  macOS:         brew install openssl" >&2
    echo "  Windows:       install Git for Windows (bundles openssl)" >&2
    exit 1
fi

echo "── Server cert (TLS) ─────────────────────────────────────────"
openssl req -x509 -newkey rsa:2048 \
    -keyout "${CERT_DIR}/key.pem" \
    -out "${CERT_DIR}/cert.pem" \
    -days 30 -nodes \
    -subj "/CN=127.0.0.1/O=HorseNghttp2GrpcDemo/OU=Server" \
    -addext "subjectAltName=IP:127.0.0.1,IP:::1,DNS:localhost" \
    2>&1 | grep -v "^\.\+$" || true

echo
echo "── CA (signs client certs for mTLS) ─────────────────────────"
openssl req -x509 -newkey rsa:2048 \
    -keyout "${CERT_DIR}/ca-key.pem" \
    -out "${CERT_DIR}/ca.pem" \
    -days 30 -nodes \
    -subj "/CN=HorseNghttp2GrpcDemoCA/O=HorseNghttp2GrpcDemo/OU=CA" \
    2>&1 | grep -v "^\.\+$" || true

echo
echo "── Client cert (signed by the CA) ───────────────────────────"
openssl req -newkey rsa:2048 -nodes \
    -keyout "${CERT_DIR}/client-key.pem" \
    -out    "${CERT_DIR}/client-req.pem" \
    -subj "/CN=grpc-demo-client/O=HorseNghttp2GrpcDemo/OU=Client" \
    2>&1 | grep -v "^\.\+$" || true

openssl x509 -req \
    -in       "${CERT_DIR}/client-req.pem" \
    -CA       "${CERT_DIR}/ca.pem" \
    -CAkey    "${CERT_DIR}/ca-key.pem" \
    -CAcreateserial \
    -out      "${CERT_DIR}/client-cert.pem" \
    -days 30 \
    2>&1 | grep -v "^\.\+$" || true

rm -f "${CERT_DIR}/client-req.pem" "${CERT_DIR}/ca.srl"

echo
echo "Generated:"
ls -la "${CERT_DIR}/"
echo
echo "Verify chain:  openssl verify -CAfile ${CERT_DIR}/ca.pem ${CERT_DIR}/client-cert.pem"
echo
echo "Server modes:"
echo "  HorseNghttp2GrpcDemo             (h2c on 18020)"
echo "  HorseNghttp2GrpcDemo tls         (h2 over TLS on 18443)"
echo "  HorseNghttp2GrpcDemo mtls        (h2 over TLS + client cert required)"
echo
echo "Client — Delphi-native suite:"
echo "  HorseNghttp2GrpcTestClient.exe https://127.0.0.1:18443"
echo "  HorseNghttp2GrpcTestClient.exe https://127.0.0.1:18443 --client-cert ${CERT_DIR}/client-cert.pem --client-key ${CERT_DIR}/client-key.pem"
echo
echo "Client — grpcurl:"
echo "  grpcurl -insecure -proto greeter.proto -d '{\"name\":\"World\"}' localhost:18443 greeter.Greeter/Greet"
echo "  grpcurl -insecure -cert ${CERT_DIR}/client-cert.pem -key ${CERT_DIR}/client-key.pem \\"
echo "          -proto greeter.proto -d '{\"name\":\"World\"}' localhost:18443 greeter.Greeter/Greet"
