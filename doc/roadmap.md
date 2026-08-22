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
| Concurrent dispatch — worker pool, streams no longer serialised per connection | **✓** (18.3× on blocking routes) |
| Graceful shutdown — drain waits for delivery, two-stage GOAWAY (RFC 9113 §6.8) | **✓** |
| Memory-BIO TLS — OpenSSL never touches the socket (event-loop prerequisite) | **✓** |
| Saturated-queue inline fallback (`FALLBACK-1`) | **✓** |
| `SheddedRequests` class counter — capacity signal (`OBSERV-1`) | **✓** |
| **Event-loop I/O** — epoll (Linux) + IOCP (Windows), opt-in via `UseEventLoop` | **✓** (both engines' graceful shutdown validated under load 2026-08-22 — 3/3 delivery shapes each, resolved-driver asserted) |
| Password-protected private keys | implemented, untested — `SSLKeyPassword` reaches a wired `passwd_cb`, but no fixture uses an encrypted key |
| **Streaming / SSE** — `Res.SendStream`, Web Streams + Server-Sent Events | **✓** (STREAM-1 — see [streaming.md](streaming.md)) |
| **gRPC — repeated fields** (packed numerics + LEN-per-element) | **✓** (M1c.2 — any `TArray<T>`; decoder accepts both wire forms; 75/75 on Delphi 12 + FPC 3.3.1) |
| **gRPC — server-streaming RPCs** | **✓** (M6a — `RegisterServerStream`; 24/24 on FPC 3.3.1) |
| **Incremental inbound transport** (INBOUND-1) | **✓ transport layer** — `ReadInbound` / `AppendInbound` / `MarkInboundEnded` on `INghttp2Stream`, plus `OnShouldStreamInbound` which moves dispatch from END_STREAM to HEADERS for opted-in streams. Regression-clean, and now exercised by M6b's client-streaming and bidi paths. |
| **gRPC — client-streaming + bidirectional RPCs** | **✓** (M6b — `RegisterClientStream` / `RegisterBidiStream`; 35/35 on FPC 3.3.1) |
| **WebSocket over HTTP/2** (RFC 8441 extended CONNECT) | **DONE — validated end-to-end 2026-08-21.** `build-fpc.sh` stage 18, 4/4: extended CONNECT accepted (`:status 200`), server frame delivered, masked client frame round-tripped as `echo:hello`. Required two Horse core fixes, upstreamed as HashLoad/horse PR #551 (FPC-only `FeedBytes` interface-to-class cast) and PR #549 (epoll transport treating `EAGAIN` as a disconnect, which masked the first). See [websocket.md](websocket.md). |
| gRPC — map fields, unsigned / ZigZag / fixed scalar variants | planned |
| gRPC — `.proto` → `.pas` code generator | planned |
| **Streaming — producer backpressure** | **✓** (BACKPRESSURE-1 — 1 MB high / 256 KB low watermarks; stage 16 streams 17 MB with 2.9 MB peak RSS growth) |
| HTTP/3 over QUIC | **investigated, deferred** — see below |

Full plan: `plans/horse-provider-nghttp2.md` + `plans/horse-grpc-nghttp2.md` in the workspace root.

---

## HTTP/3 / QUIC — investigated, deferred (2026-08-20)

Recorded as a decision rather than an omission, so it does not get re-raised
from scratch.

### The argument that decides it

**A reverse proxy already delivers HTTP/3 to clients today, with no work
here.** This provider has no HTTP/1.1, so it already sits behind nginx or
Apache in most real deployments — see [deployment.md](deployment.md). nginx
speaks HTTP/3 to browsers while speaking HTTP/2 to the origin, which is how
essentially everyone deploys HTTP/3. Terminating QUIC *at the origin* buys
almost nothing unless there is no proxy in the path at all.

### What building it would cost

The library precedent is encouraging: **ngtcp2** (transport) and **nghttp3**
(framing) are by the same author as nghttp2 and follow the same API idioms, so
`Delphi-nghttp2`'s FFI and session patterns would transfer well. Everything
around that gets harder:

- **Two libraries plus a QUIC-capable TLS stack**, where nghttp2 was one.
  Mainline OpenSSL historically did not expose the QUIC TLS interface ngtcp2
  needs — that meant quictls or BoringSSL; OpenSSL 3.5's QUIC server support
  is recent and ngtcp2's support for it newer still. The single-libnghttp2
  dependency already costs a shipping list, a version floor, and an
  acquisition guide per platform. This multiplies that.
- **UDP instead of TCP.** `Nghttp2.Socket.pas` already carries four compiler
  branches for `select()`. QUIC wants per-packet ECN, GSO/GRO and pacing —
  more platform surface, and worse Windows/Linux/macOS divergence.
- **No test client.** `TNghttp2Client` cannot measure streaming arrival timing
  and has no extended CONNECT; for HTTP/3 there would be no Pascal client at
  all, so every gate would be external tooling from day one.

### And this provider has open work first

gRPC lacks map fields, the unsigned/ZigZag/fixed scalar variants, and codegen.
Starting a second protocol widens the surface faster than validation can
follow — and the
expensive half of this work has consistently been *proving* behaviour, not
writing it.

### What would flip the decision

- HTTP/3 termination genuinely needed **at the origin** — an edge device or
  appliance with no proxy in front.
- **gRPC-over-HTTP/3** becomes a requirement.
- ngtcp2 + mainline OpenSSL QUIC settle enough that the dependency story looks
  like libnghttp2's does today.
