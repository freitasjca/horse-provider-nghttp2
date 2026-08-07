# horse-provider-nghttp2

**Status: v1.1 (feature-complete for h2c AND h2/TLS in both directions).** Server + native Delphi client both work over cleartext HTTP/2 (h2c) and TLS+ALPN (h2). 36-test / 94-check matrix passes 94/94 on both transports. mTLS + gRPC + streaming are v2.

HTTP/2-native transport provider for the [Horse](https://github.com/HashLoad/horse) web framework, built on the [Delphi-nghttp2](https://github.com/freitasjca/Delphi-nghttp2) wrapper of the C library [libnghttp2](https://nghttp2.org/). Multiplexed streams, HPACK header compression, native ALPN over TLS — all transparent to existing Horse routes and middleware.

Companion to [`horse-provider-crosssocket`](https://github.com/freitasjca/horse-provider-crosssocket) (HTTP/1.1 async via Delphi-Cross-Socket) and [`horse-provider-mormot`](https://github.com/freitasjca/horse-provider-mormot) (mORMot2 stack, incl. `http.sys`).

---

## Roadmap

| Layer | State |
|---|---|
| Native FFI to libnghttp2 (server-side) | **v0.1 ✓** (in `Delphi-nghttp2/src/Nghttp2.Native.pas`) |
| Native FFI to libnghttp2 (client-side) | **v1.1 ✓** |
| Request + Response bridges (Horse ↔ HTTP/2 mapping) | **v0.1 ✓** |
| Per-connection Session (stream table + HPACK) | **v0.1 ✓** |
| TCP Server (accept loop, cross-platform sockets) | **v0.1 ✓** |
| Context pool + Provider entry point | **v0.1 ✓** |
| Worker pool (CPU-offload for handlers) | **v0.1 ✓** |
| `Horse.pas` NGHTTP2 hooks (upstream PR pending) | **v0.1 ✓** (via `patches/horse/src/Horse.pas` snapshot) |
| Smoke test server + curl-driven suite (h2c + TLS) | **v0.1 ✓** / **v1.1 ✓** (TLS support in `run-smoke-tests.sh`) |
| Native Delphi HTTP/2 client (`TNghttp2Client`) | **v1.1 ✓** |
| 36-test / 94-check parity suite (h2c + h2/TLS) | **v1.1 ✓** (94/94 on both) |
| TLS + ALPN (server + client, OpenSSL 3.x / 1.1.x auto-detect) | **v1.1 ✓** |
| Password-protected private keys | v2 |
| mTLS (client cert verification) | v2 |
| Cross-product units (VCL / Daemon / LCL / FPC.HTTPApp) | v2 |
| Streaming / SSE (replace current 501 stubs) | v2 |
| gRPC-over-HTTP/2 dispatch layer | v2 |

Full plan: `plans/horse-provider-nghttp2.md` in the workspace root.
Design guide: `patches/horse-provider-crosssocket/doc/building-a-new-provider.md` (nghttp2 is the worked example).

---

## System requirements

- **libnghttp2 ≥ 1.40** — install via system package manager:
  - Debian/Ubuntu: `apt install libnghttp2-14 libnghttp2-dev`
  - Fedora/RHEL: `dnf install libnghttp2 libnghttp2-devel`
  - macOS: `brew install nghttp2`
  - Windows: `vcpkg install nghttp2`, or a prebuilt binary from https://nghttp2.org/
- **Horse** — HashLoad/horse ≥ 3.3.0 (2026-08-01) with the seven NGHTTP2 hooks in `Horse.pas` applied. Either:
  - Wait for the upstream PR (spec: `patches/horse/src/HOOKS-FOR-NGHTTP2.md`) to merge — then no manual patching is needed, OR
  - Copy `patches/horse/src/Horse.pas` over your local horse checkout — see `patches/horse-provider-nghttp2/scripts/fork-sync-workflow.md`
- **Compiler** — Delphi 10.4 Sydney+ or FPC ≥ 3.3.1. Dual-compilation is a non-negotiable design rule; every unit compiles for both.

The provider loads the library by its stable SONAME (`libnghttp2.so.14` on Linux, `libnghttp2.dylib` on macOS, `nghttp2.dll` on Windows). No binaries are bundled in the repo — the platform's package manager owns the file, updates come with system updates.

---

## Activation

```pascal
{$DEFINE HORSE_PROVIDER_NGHTTP2}
```

Legacy alias `{$DEFINE HORSE_NGHTTP2}` is supported via the PATCH-HORSE-2 aliasing block in `Horse.pas` (Hook 1 of the seven).

Mutually exclusive with `HORSE_PROVIDER_CROSSSOCKET`, `HORSE_PROVIDER_MORMOT`, `HORSE_PROVIDER_ICS`, `HORSE_PROVIDER_HTTPSYS`, `HORSE_PROVIDER_EPOLL`, and `HORSE_PROVIDER_IOCP` — the FATAL guards in `Horse.pas` enforce this at compile time.

Cannot combine with any `HORSE_HOST_*` define (`APACHE`, `ISAPI`, `CGI`, `FCGI`) — those runtimes own the socket, and a self-hosted transport can't coexist.

---

## Minimal usage

```pascal
program MyHttp2Server;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}

uses
  Horse;

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

begin
  THorse.Get('/ping', GetPing);
  THorse.Listen(9200);
end.
```

Test with:
```
curl --http2-prior-knowledge http://localhost:9200/ping
```

The `--http2-prior-knowledge` flag tells curl to skip the HTTP/1.1 `Upgrade: h2c` dance and open the connection speaking HTTP/2 directly. This is the mode the provider serves in v1.

---

## Framework contract compliance

The provider implements the four Horse-framework contracts from `horse/.agents/AGENTS.md`:

| Contract | Implementation |
|---|---|
| `GetActivePort` override | `THorseProviderNghttp2.GetActivePort` returns `FPort` |
| `TriggerBeforeListen` at top of `Listen`/`InternalListen` | First line of `InternalListen` |
| `TriggerBeforeStop` at top of `StopListen`/`InternalStopListen` | First line of both `StopListen` and `StopListenGraceful` |
| `StopListenGraceful(TimeoutMS)` with active-request drain | `StopAcceptingNewConnections` → poll `Server.ActiveRequests → 0` (20 ms tick until deadline) → `ForceCloseAllConnections` → `Stop` |

The `SEC-30` active-request counter is a per-request `TInterlocked.Increment`/`Decrement` on `TNghttp2Server.FActiveRequests`, wrapping the `OnRequest` dispatch.

---

## Testing

See `samples/tests/README.md` for the smoke suite (server .dpr + curl driver, ~20 tests over ~12 routes covering HTTP methods, params, query, headers, cookies, error paths, large bodies, and baseline security headers).

Quick loop:
```
cd samples/tests
boss install
dcc32 -B HorseNghttp2TestServer.dpr    # or F9 in Delphi IDE
./HorseNghttp2TestServer &             # runs on :9200
./run-smoke-tests.sh                   # bash + curl driver
```

---

## Architecture

```
HTTP/2 client
    │  (h2c preface + SETTINGS)
    ▼
Horse.Provider.Nghttp2.Socket (TCP accept loop; per-connection thread)
    │
    ▼
Horse.Provider.Nghttp2.Session (nghttp2_session_server + stream table)
    │  callback: on_frame_recv w/ END_STREAM
    ▼
Horse.Provider.Nghttp2.pas / THorseProviderNghttp2.ExecutePipeline
    │  Request bridge (validation + shadow-field populate + non-owning body)
    │  Pool acquire
    │  Horse.Execute (middleware + route)
    │  Response bridge (CRLF-strip + hop-by-hop filter + emit)
    │  Pool release
    ▼
nghttp2_submit_response → mem_send → SocketSendAll
```

Deeper: `docs/architecture.md` in the workspace root.

---

## Limitations in v1

- **h2c only** — cleartext HTTP/2 via prior knowledge. Clients must use `curl --http2-prior-knowledge` or equivalent. TLS + ALPN lands in v1.1.
- **No HTTP/1.1 fallback** — the server speaks HTTP/2 exclusively. Clients that only know HTTP/1.1 will fail to connect.
- **No trailers, no server push** — RFC-permitted but out of scope. Server push is deprecated by browsers anyway.
- **No client-side bindings** — `Horse.Provider.Nghttp2.Native.pas` covers server-side only. Client-side (for tests, or for a mORMot-style outbound HTTP/2 client) is v2.
- **Console-shape provider only** — no VCL/Daemon/LCL/HTTPApp cross-product units. Deploy as a console binary; use OS-level tooling (systemd, Windows Service Wrapper) to daemonise if needed. Cross-product units come in v2.

---

## Contributing

See:
- `patches/horse-provider-crosssocket/doc/building-a-new-provider.md` — the design guide (this provider is its worked example)
- `docs/architecture.md` — request lifecycle, framework contracts
- `docs/middleware.md` — the four rules every Horse middleware must satisfy (they apply here too)
- `plans/horse-provider-nghttp2.md` — the running plan with progress log
- `horse/.agents/AGENTS.md` — Horse-maintainer authored framework contracts

Before opening a PR, run the smoke suite and confirm all tests pass.

---

## License

MIT. See `LICENSE`.
