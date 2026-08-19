# Architecture & contributing

## Request flow

```
HTTP/2 client
    │  (h2c preface + SETTINGS  –or–  TLS ALPN → h2)
    ▼
Horse.Provider.Nghttp2.Socket   — TCP accept loop; per-connection thread (or event-loop engine)
    │
    ▼
Horse.Provider.Nghttp2.Session  — nghttp2_session_server + stream table
    │  on_frame_recv w/ END_STREAM
    ▼
THorseProviderNghttp2.ExecutePipeline
    │  gRPC gate (TryDispatch) — intercepts application/grpc content-type
    │  Request bridge          — validates + shadow-field populate
    │  Pool acquire
    │  Horse.Execute           — middleware + route chain
    │  Response bridge         — CRLF-strip + hop-by-hop filter + emit
    │  Pool release
    ▼
nghttp2_submit_response → DATA frames (+ trailer HEADERS for gRPC)
    → mem_send → SocketSendAll
```

The worker pool intercepts between `ExecutePipeline` and the route chain: the connection thread hands the stream to a worker, which runs `Horse.Execute` and stages the response back; the connection thread then submits and sends. See [doc/concurrency.md](concurrency.md) for the invariants that make this safe.

## Unit responsibilities

| Unit | Responsibility |
|---|---|
| `Horse.Provider.Nghttp2` | Entry point; worker pool dispatch; `SheddedRequests`; `StopListenGraceful` |
| `Horse.Provider.Nghttp2.WorkerPool` | Bounded pool (4–64 threads, 4 096 queue). `Stop` drains rather than drops |
| `Horse.Provider.Nghttp2.Pool` | `THorseContext` pool; prewarm 32; `FIX-POOL-1` (Clear, never Body(nil)) |
| `Horse.Provider.Nghttp2.{Request,Response}` | Bridges: non-owning body, CRLF-strip, hop-by-hop filter, trailer prefix routing |
| `Horse.Provider.Nghttp2.Grpc.*` | gRPC dispatcher, registry, RTTI attributes |
| `Horse.Provider.Nghttp2.{VCL,Daemon,FPC.*}` | Cross-product app-type shape units |

Deeper: `docs/architecture.md` in the workspace root.

## Framework contract compliance

The provider implements all four Horse-framework contracts from `horse/.agents/AGENTS.md`:

| Contract | Implementation |
|---|---|
| `GetActivePort` override | Returns `FPort` |
| `TriggerBeforeListen` at top of `Listen` | First line of `InternalListen` |
| `TriggerBeforeStop` at top of `StopListen` | First line of both `StopListen` and `StopListenGraceful` |
| `StopListenGraceful(TimeoutMS)` | `StopAcceptingNewConnections` → poll `ActiveRequests → 0` → `AllConnectionsIdle` → `ForceCloseAllConnections` → `Stop` |

## Contributing

Before opening a PR, run both `HorseNghttp2TestClient.exe` (94/94) and `HorseNghttp2GrpcTestClient.exe` (16/16) and confirm all tests pass.

Reference docs:

- `patches/horse-provider-crosssocket/doc/building-a-new-provider.md` — design guide (this provider is its worked example)
- `docs/architecture.md` (workspace root) — request lifecycle, framework contracts
- `docs/middleware.md` (workspace root) — middleware authoring rules (`TNextProc`, not `TProc`, for FPC)
- `horse/.agents/AGENTS.md` — Horse-maintainer authored framework contracts
- `horse/.agents/skills/horse-grpc/SKILL.md` — gRPC patterns (RTTI context lifetime, ARC discipline)
