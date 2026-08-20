# Platform coverage

Validated at **runtime** on all three, not merely compiled:

| Gate | Windows / Delphi | Linux / FPC 3.3.1 | Linux64 / Delphi |
|---|---|---|---|
| 106-check regression, h2c | compiles; run pending | 106/106 | 94/94 (pre-STREAM-1) |
| 106-check regression, TLS | 106/106 | 106/106 | — |
| 106-check regression, mTLS | 106/106 | 106/106 | — |
| 106-check via epoll event loop — h2c / TLS / mTLS | n/a (IOCP) | 106/106 each | — |
| mTLS negative | — | rejected (thread + event loop) | — |
| Streaming & SSE — content, ordering, concurrency | ✓ (checks 33–37, TLS + mTLS) | ✓ (checks 33–37) | — |
| Streaming — **incremental arrival**, thread driver | ✓ gaps 63/69/68/69 ms, span 269 ms (cross-machine) | ✓ 5 events spanned 247 ms | — |
| Streaming — **incremental arrival**, event loop | ✓ IOCP: gaps 63/62/63/62 ms, span 250 ms | ✓ epoll (stage 15) | — |
| gRPC native client — h2c / TLS / mTLS | **35/35** (h2c) | **35/35** (h2c) | 16/16 (pre-M6a) |
| gRPC server-streaming (M6a) | ✓ + grpcurl | ✓ | — |
| gRPC client-streaming + bidi (M6b) | ✓ (checks 05–06) + handler-stamp trace | ✓ (checks 05–06) | — |
| gRPC over TLS / mTLS | 16/16 (pre-M6a) | 16/16 (pre-M6a) | — |
| grpcurl interop — unary | ✓ | ✓ | — |
| grpcurl interop — server-streaming | ✓ | ✓ (also cross-machine to the Windows server) | — |
| curl smoke suite | 25/25 | 25/25 | — |
| Protobuf codec (incl. repeated fields, M1c.2) | 75/75 | 75/75 | — |
| Graceful shutdown — thread driver | ✓ (see WSL2 note) | ✓ (see WSL2 note) | — |
| Graceful shutdown — event-loop (epoll/IOCP) | ⚠ IOCP not re-validated | ⚠ epoll 96/184 open | — |
| Connection-thread leak (25 000 conns) | — | ✓ flat | — |
| Two-stage GOAWAY (frame trace) | — | ✓ | — |

Linux64 / Delphi is exercised through PAServer with the client on a separate machine, so it also covers the cross-machine path rather than loopback only.

## Notes

- **WSL2 mirrored networking** causes ~50% reply loss on the graceful shutdown test — this is an environment artifact. Switching to `networkingMode=NAT` in `%USERPROFILE%\.wslconfig` (then `wsl --shutdown`) gives 27/27 passes over 9 consecutive runs. Full investigation: `plans/HANDOFF-nghttp2-shutdown-2026-08-18.md`.
- **IOCP graceful shutdown** was validated with the old `h2load started == succeeded` gate, which was later shown to measure the load generator's GOAWAY reaction rather than server delivery. Needs re-validation with `verify-drain-delivery.sh`. See [doc/graceful-shutdown.md](graceful-shutdown.md).
- **epoll graceful shutdown** under load: `build-fpc.sh` stage 6 `eventloop` path reports 96/184. Thread driver is fully validated.
- **The suite grew 94 → 106** with STREAM-1: checks 33–37 replaced the four `501` streaming stubs with real assertions. The count is the same binary on every platform, so an older `94/94` line above records a run predating that change, not a smaller suite.
- **The incremental-arrival gate needs a per-frame-timestamping client**, which no Pascal client here is: `TNghttp2Client` returns a *completed* response, so buffered and streamed delivery are byte-identical to it. `build-fpc.sh` stage 15 covers Linux/epoll. Windows was measured by hand — see below.
- **Do not read check 37's latency as that evidence.** The Windows runs report `GET /stream/sse total: 330 ms` against 2–6 ms for every other request, and the contrast invites the conclusion that frames were observed arriving. They were not. The handler sleeps 4 × 60 ms whatever the transport does with the bytes, so an implementation that buffered all five events and flushed them at the end reports the same ~330 ms. That number measures when the response **completed**, not when frames **arrived**. Nor is unstamped `curl -N` output sufficient — the five events appear in order either way once the transfer is done. Only per-line timestamps separate the two:
  ```bash
  curl --http2-prior-knowledge -N -s http://HOST:9010/stream/sse \
  | while IFS= read -r line; do printf '%s  %s\n' "$(date +%H:%M:%S.%3N)" "$line"; done
  ```
  Windows / thread driver, measured 2026-08-20 from WSL2 to the Windows host (a real interface, not loopback): event gaps **63 / 69 / 68 / 69 ms** against a 60 ms sleep, span 269 ms. The pacing is reproduced per event with ~5–9 ms hop overhead — a shape buffered delivery cannot produce.
- **Windows / IOCP event loop** (`HorseNghttp2TestServer.exe eventloop`, resolving `IOCP completion port`), same cross-machine measurement: gaps **63 / 62 / 63 / 62 ms**, span 250 ms — tighter and more uniform than the thread driver's, within 2–3 ms of the handler's 60 ms sleep. This was the run most likely to expose a defect: a successful `nghttp2_session_resume_data` whose socket flush waits for the next poll tick would stall frames exactly as the 2.8× event-loop stall did in the earlier engine work. It does not. All four driver × platform combinations are now confirmed to deliver incrementally.
