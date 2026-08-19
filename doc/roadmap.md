# Roadmap

All items marked **✓** ship in the v1.0.0 public release. Internal milestone labels (M0–M5) reflect the development sequence, not semver versions.

| Layer | State |
|---|---|
| Native FFI to libnghttp2 — server-side | **✓** |
| Native FFI to libnghttp2 — client-side (`TNghttp2Client`) | **✓** |
| Request + Response bridges (Horse ↔ HTTP/2) | **✓** |
| Per-connection session (stream table + HPACK) | **✓** |
| TCP server (accept loop, cross-platform sockets) | **✓** |
| Context pool + provider entry point | **✓** |
| Worker pool (CPU-offload for handlers) | **✓** |
| `Horse.pas` NGHTTP2 hooks (upstream PR pending) | **✓** |
| Smoke test server + curl-driven suite | **✓** |
| 94-check parity suite | **✓** (94/94 h2c + h2/TLS) |
| TLS + ALPN — server + client (OpenSSL 3.x / 1.1.x auto-detect) | **✓** |
| mTLS (client cert verification) | **✓** |
| Cross-product app-type units — Delphi (VCL / Daemon / Windows Service) | **✓** |
| Cross-product app-type units — FPC (Daemon / LCL / HTTPApplication) | **✓** |
| FPC trunk 3.3.1 — full parity (HTTP/2 + gRPC + TLS + mTLS) | **✓** |
| gRPC-over-HTTP/2 — unary RPCs, M4a + M4c registration styles | **✓** (see `samples/grpc/`) |
| Protobuf codec — all scalar types + nested messages | **✓** |
| Concurrent dispatch — worker pool, streams no longer serialised per connection | **✓** (22.3× on blocking routes) |
| Graceful shutdown — drain waits for delivery, two-stage GOAWAY (RFC 9113 §6.8) | **✓** |
| Memory-BIO TLS — OpenSSL never touches the socket (event-loop prerequisite) | **✓** |
| Saturated-queue inline fallback (`FALLBACK-1`) | **✓** |
| `SheddedRequests` class counter — capacity signal (`OBSERV-1`) | **✓** |
| **Event-loop I/O** — epoll (Linux) + IOCP (Windows), opt-in via `UseEventLoop` | **✓** (IOCP graceful shutdown under load to be re-validated) |
| Password-protected private keys | implemented, untested — `SSLKeyPassword` reaches a wired `passwd_cb`, but no fixture uses an encrypted key |
| gRPC — repeated fields (packed + LEN-per-element) | planned |
| gRPC — streaming RPCs (server / client / bidi) | planned |
| gRPC — `.proto` → `.pas` code generator | planned |
| Streaming / SSE (replace current 501 stubs) | planned |

Full plan: `plans/horse-provider-nghttp2.md` + `plans/horse-grpc-nghttp2.md` in the workspace root.
