# Platform coverage

Validated at **runtime** on all three, not merely compiled:

| Gate | Windows / Delphi | Linux / FPC 3.3.1 | Linux64 / Delphi |
|---|---|---|---|
| 94-check regression, h2c | 94/94 | 94/94 | 94/94 |
| 94-check regression, TLS | 94/94 | 94/94 | — |
| 94-check regression, mTLS | 94/94 | 94/94 | — |
| mTLS negative | rejected | rejected | — |
| gRPC native client | 16/16 | 16/16 | 16/16 |
| gRPC over TLS / mTLS | 16/16 | 16/16 | — |
| grpcurl interop | ✓ | ✓ | — |
| curl smoke suite | 25/25 | 25/25 | — |
| Protobuf codec | 52/52 | 52/52 | — |
| Graceful shutdown — thread driver | ✓ (see WSL2 note) | ✓ (see WSL2 note) | — |
| Graceful shutdown — event-loop (epoll/IOCP) | ⚠ IOCP not re-validated | ⚠ epoll 96/184 open | — |
| Connection-thread leak (25 000 conns) | — | ✓ flat | — |
| Two-stage GOAWAY (frame trace) | — | ✓ | — |

Linux64 / Delphi is exercised through PAServer with the client on a separate machine, so it also covers the cross-machine path rather than loopback only.

## Notes

- **WSL2 mirrored networking** causes ~50% reply loss on the graceful shutdown test — this is an environment artifact. Switching to `networkingMode=NAT` in `%USERPROFILE%\.wslconfig` (then `wsl --shutdown`) gives 27/27 passes over 9 consecutive runs. Full investigation: `plans/HANDOFF-nghttp2-shutdown-2026-08-18.md`.
- **IOCP graceful shutdown** was validated with the old `h2load started == succeeded` gate, which was later shown to measure the load generator's GOAWAY reaction rather than server delivery. Needs re-validation with `verify-drain-delivery.sh`. See [doc/graceful-shutdown.md](graceful-shutdown.md).
- **epoll graceful shutdown** under load: `build-fpc.sh` stage 6 `eventloop` path reports 96/184. Thread driver is fully validated.
