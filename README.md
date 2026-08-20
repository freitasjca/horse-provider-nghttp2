# horse-provider-nghttp2

**Status: v1.0.0 — production-ready (h2c + TLS + mTLS + gRPC, Delphi + FPC trunk 3.3.1).**

HTTP/2-native transport provider for [Horse](https://github.com/HashLoad/horse), built on [Delphi-nghttp2](https://github.com/freitasjca/Delphi-nghttp2) v1.0.0 and the C library [libnghttp2](https://nghttp2.org/). Drop-in replacement for the default Indy transport — activate with one compiler define, keep your existing routes and middleware unchanged.

Companion to [`horse-provider-crosssocket`](https://github.com/freitasjca/horse-provider-crosssocket) (HTTP/1.1 async via Delphi-Cross-Socket) and [`horse-provider-mormot`](https://github.com/freitasjca/horse-provider-mormot) (mORMot2 stack, incl. `http.sys`).

---

## What it enables

- **HTTP/2 multiplexing** — clients send many concurrent streams over one TCP connection; no Head-of-Line blocking
- **HPACK header compression** — reduces per-request overhead on high-frequency routes
- **TLS with ALPN** — `h2` over HTTPS; OpenSSL 3.x / 1.1.x auto-detected at runtime, no recompile
- **mTLS** — client certificate verification for zero-trust service-to-service calls
- **gRPC v0.1** — unary RPCs, protobuf codec, two registration styles (`RegisterMethod` / `RegisterService<T>`)
- **Async worker pool** — handlers run off the connection thread; 22.3× throughput on blocking routes
- **Streaming & SSE** — `Res.SendStream` for Web Streams (NDJSON) and Server-Sent Events; no chunked framing needed on HTTP/2
- **Graceful shutdown** — two-stage GOAWAY per RFC 9113 §6.8; in-flight requests complete before the server closes
- **Event-loop I/O** — epoll (Linux) and IOCP (Windows) engines, opt-in via `UseEventLoop`
- **Cross-platform** — Windows/Delphi 12, Linux/FPC trunk 3.3.1, Linux/Delphi (PAServer)
- **Cross-product app shapes** — Console, VCL, Daemon, Windows Service, FPC Daemon, LCL, HTTPApplication

## Before you choose it

The server speaks **HTTP/2 only** — there is no HTTP/1.1 fallback. Your routes
and middleware port over unchanged, but the wire does not:

- HTTP/1.1-only clients are refused, not downgraded.
- Browsers need TLS + ALPN to reach it; cleartext h2c is for native clients.
- A reverse proxy must speak HTTP/2 on its **back leg**. nginx `grpc_pass` and
  Apache `mod_proxy_http2` do; `proxy_pass`, `mod_proxy_http` and IIS ARR do
  not. See [doc/deployment.md](doc/deployment.md).
- No WebSocket — RFC 8441 is out of scope for v1.

Best fit: gRPC, service-to-service APIs, and clients you control. For a public
HTTP/1.1 endpoint, use one of Horse's other transports.

---

## Quick start

### Requirements

- Delphi 10.4 Sydney or later / FPC trunk 3.3.1 (FPC 3.2.2 is a hard blocker)
- Horse ≥ 3.3.0 with NGHTTP2 hooks — copy `patches/horse/src/Horse.pas` over your checkout
- [Delphi-nghttp2](https://github.com/freitasjca/Delphi-nghttp2) ≥ 1.0.0
- libnghttp2 ≥ 1.59 — **required at run time**, dynamic-loaded (`nghttp2.dll` / `libnghttp2.so.14` / `libnghttp2.dylib`); see [getting-nghttp2-windows.md](https://github.com/freitasjca/Delphi-nghttp2/blob/main/doc/getting-nghttp2-windows.md) / [getting-nghttp2-linux.md](https://github.com/freitasjca/Delphi-nghttp2/blob/main/doc/getting-nghttp2-linux.md)
- OpenSSL 3.x or 1.1 for TLS only (auto-detected at runtime)

Full per-platform shipping list: [doc/deployment.md](doc/deployment.md#what-to-ship).

Install with Boss:

```
boss install github.com/freitasjca/horse-provider-nghttp2
```

### Activation

```pascal
{$DEFINE HORSE_PROVIDER_NGHTTP2}
```

Legacy alias `{$DEFINE HORSE_NGHTTP2}` also accepted. Mutually exclusive with all other `HORSE_PROVIDER_*` and `HORSE_HOST_*` defines — enforced at compile time by `FATAL` guards in `Horse.pas`.

### Minimal server

```pascal
program MyHttp2Server;
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}
uses Horse;

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

begin
  THorse.Get('/ping', GetPing);
  THorse.Listen(9200);
end.
```

```
curl --http2-prior-knowledge http://localhost:9200/ping
```

`--http2-prior-knowledge` tells curl to speak HTTP/2 immediately (no HTTP/1.1 upgrade round-trip). This is the connection mode used in h2c configuration.

### Minimal client

```pascal
program MyHttp2Client;
{$APPTYPE CONSOLE}
uses
  Nghttp2.Client, System.SysUtils;

var
  C: TNghttp2Client;
  R: TNghttp2Response;
begin
  C := TNghttp2Client.Create;
  try
    C.Connect('127.0.0.1', 9200);
    R := C.SubmitRequest('GET', '/ping', nil, nil);
    WriteLn('Status: ', R.Status);
    WriteLn(TEncoding.UTF8.GetString(R.Body));
  finally
    C.Free;
  end;
end.
```

`TNghttp2Client` is provided by [Delphi-nghttp2](https://github.com/freitasjca/Delphi-nghttp2). No Horse dependency on the client side — add `Delphi-nghttp2/src/` to the search path and link `nghttp2.dll` / `libnghttp2.so.14`.

For TLS, pass the cert paths before `Connect`:

```pascal
C.SSLEnabled  := True;
C.SSLCertFile := 'tls/cert.pem';   // mTLS only — omit for plain TLS
C.SSLKeyFile  := 'tls/key.pem';
C.Connect('127.0.0.1', 9443);
```

---

## Documentation

| Topic | Guide |
|---|---|
| Roadmap | [doc/roadmap.md](doc/roadmap.md) |
| Concurrency & worker pool | [doc/concurrency.md](doc/concurrency.md) |
| Deployment — proxies, app types, load balancers | [doc/deployment.md](doc/deployment.md) |
| Streaming & SSE | [doc/streaming.md](doc/streaming.md) |
| Graceful shutdown | [doc/graceful-shutdown.md](doc/graceful-shutdown.md) |
| TLS and mTLS | [doc/tls.md](doc/tls.md) |
| gRPC | [doc/grpc.md](doc/grpc.md) |
| Testing & benchmarking | [doc/testing.md](doc/testing.md) |
| Platform coverage | [doc/platform-coverage.md](doc/platform-coverage.md) |
| FPC / Lazarus | [doc/fpc-lazarus.md](doc/fpc-lazarus.md) |
| Architecture & contributing | [doc/architecture.md](doc/architecture.md) |
| Limitations | [doc/limitations.md](doc/limitations.md) |

---

## License

MIT. See `LICENSE`.
