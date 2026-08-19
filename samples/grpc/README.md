# gRPC-over-HTTP/2 demo — horse-provider-nghttp2 (M4b + M5)

End-to-end demo of the gRPC service registry + dispatcher shipped in M4a.
A Horse server registers two methods; two clients validate the wire
format independently: a **Delphi-native test suite** (dogfoods the codec)
and **grpcurl** (external interop check). Runs on h2c, h2 over TLS, and
mTLS (h2 + client cert required).

## What's here

| File | Purpose |
|---|---|
| `HorseNghttp2GrpcDemo.dpr`         | Server — h2c 18020 / TLS 18443 / mTLS 18443 selected via CLI arg; uses M4c `RegisterService<IGreeter>` |
| `HorseNghttp2GrpcTestClient.dpr`   | Delphi-native client using `Nghttp2.Client` + `Nghttp2.Protobuf.Rtti` — accepts `http://` or `https://` URLs, plus `--client-cert`/`--client-key` for mTLS |
| `Sample.Greeter.Interfaces.pas`    | `IGreeter` — `IInvokable` service interface with `[TGrpcService('greeter.Greeter')]` |
| `Sample.Greeter.Messages.pas`      | `TGreetRequest` / `TGreetResponse` / `TEchoRequest` / `TEchoResponse` |
| `Sample.Greeter.Service.pas`       | `TGreeterService` (M4a procedural) + `TGreeterServiceImpl` (M4c `IGreeter` impl with ARC disabled) |
| `greeter.proto`                    | Companion schema for grpcurl (tags must match `[TProtoMember(N)]`) |
| `gen-tls-cert.sh`                  | Generates `tls/cert.pem`, `tls/key.pem`, `tls/ca.pem`, `tls/client-cert.pem`, `tls/client-key.pem` — run once before TLS/mTLS modes |

## Two registration styles (M4a procedural vs M4c IInvokable)

Both produce identical wire behaviour and are interchangeable.

**M4a — explicit per-method:**

```pascal
THorseGrpc.RegisterMethod('/greeter.Greeter/Greet',
  TGreetRequest, TGreetResponse, GreeterService.Greet);
THorseGrpc.RegisterMethod('/greeter.Greeter/Echo',
  TEchoRequest, TEchoResponse, GreeterService.Echo);
```

Handler signature: `procedure(const AReq, AResp: TObject) of object`. Dispatcher creates + frees both.

**M4c — one-line service registration:**

```pascal
THorseGrpc.RegisterService<IGreeter>(TGreeterServiceImpl.Create);
```

Requires `IGreeter` to derive from `IInvokable` and carry `[TGrpcService('greeter.Greeter')]`. Requires `TGreeterServiceImpl._AddRef` / `_Release` to return `-1` (see `horse-grpc` SKILL §2 — prevents ARC destroying the instance during RTTI dispatch). Method signature: `function <Name>(const ARequest: T): TResponse` — dispatcher extracts both classes via RTTI.

The demo uses M4c; the M4a call sequence is preserved in a comment.

## Wire contract

- **Path convention** — `/greeter.Greeter/Greet`, `/greeter.Greeter/Echo`
- **Request/response body** — `[1B compressed=0][4B BE length][protobuf payload]`
- **Response trailer** — `grpc-status: N` (+ `grpc-message: OK` on success)
- **Content-type** — server always emits `application/grpc`; client sends `application/grpc+proto`

## Build

Open both `.dpr` files in the Delphi IDE and build individually. Both
targets need:

- `libnghttp2` ≥ 1.40 available at runtime (`nghttp2.dll` on Windows, `libnghttp2.so.14` on Linux)
- Delphi search path pointing at `Delphi-nghttp2/src/` and (server only) `horse-provider-nghttp2/src/`

The server also needs the standard Horse + patched `Delphi-Cross-Socket` +
`Horse.Provider.Nghttp2.*` units on the search path (same setup as
`samples/tests/HorseNghttp2TestServer.dpr`).

## Run

Terminal 1:

```
HorseNghttp2GrpcDemo.exe
```

Terminal 2 — Delphi-native suite:

```
HorseNghttp2GrpcTestClient.exe
```

Expected tail:

```
16 passed, 0 failed  (total 16)
All tests PASSED.
```

Validated 2026-08-08 on Windows Delphi 12: 16/16 green + `grpcurl` returns `{"message":"Hello, World!"}` for the Greet interop check.

Terminal 2 — grpcurl interop (optional but nice to have):

```
grpcurl -plaintext -proto greeter.proto -d '{"name":"World"}' \
        localhost:18020 greeter.Greeter/Greet
# expected:  {"message":"Hello, World!"}

grpcurl -plaintext -proto greeter.proto \
        -d '{"i32":42,"i64":"9876543210","b":true,"s":"quick brown fox","f32":3.14,"f64":2.7182818284}' \
        localhost:18020 greeter.Greeter/Echo
# expected: the same values echoed back

grpcurl -plaintext -proto greeter.proto -d '{}' \
        localhost:18020 greeter.Greeter/DoesNotExist
# expected:  ERROR: Code: Unimplemented — proves grpc-status 12 trailer
```

**grpcurl install** — see the top-level `README.md` of horse-provider-nghttp2
or `.claude/skills/delphi-grpc/SKILL.md`; the direct-download route is fastest
on Windows because Chocolatey has no `grpcurl` package.

## Run — TLS (h2 over TLS)

One-time setup — generate self-signed certs:

```bash
./gen-tls-cert.sh
# produces tls/{cert.pem, key.pem, ca.pem, client-cert.pem, client-key.pem}
```

Terminal 1 — TLS server on port 18443:

```
HorseNghttp2GrpcDemo.exe tls
```

Terminal 2 — Delphi-native suite:

```
HorseNghttp2GrpcTestClient.exe https://127.0.0.1:18443
```

Expected tail: `16 passed, 0 failed`. Client uses `TTlsClientContext.SetInsecure`
+ `EnableHttp2Alpn` — skips cert verification (self-signed OK) and negotiates
`h2` via ALPN.

Terminal 2 — grpcurl:

```
grpcurl -insecure -proto greeter.proto -d '{"name":"World"}' localhost:18443 greeter.Greeter/Greet
# expected:  {"message":"Hello, World!"}
```

## Run — mTLS (server demands client cert)

Same setup (certs already generated).

Terminal 1 — mTLS server:

```
HorseNghttp2GrpcDemo.exe mtls
```

Terminal 2 — Delphi-native suite with client cert:

```
HorseNghttp2GrpcTestClient.exe https://127.0.0.1:18443 --client-cert tls/client-cert.pem --client-key tls/client-key.pem
```

Terminal 2 — grpcurl with client cert:

```
grpcurl -insecure -cert tls/client-cert.pem -key tls/client-key.pem \
        -proto greeter.proto -d '{"name":"World"}' \
        localhost:18443 greeter.Greeter/Greet
```

Both should return `{"message":"Hello, World!"}`. Omitting the client cert
against an `mtls` server produces a TLS handshake failure (server rejects
the connection before the HTTP/2 preface).

## Why two clients

- **`HorseNghttp2GrpcTestClient`** uses the same protobuf codec as the
  server. A green run doesn't prove wire-format correctness against the
  broader gRPC ecosystem — only that our two sides agree with themselves.
  It's fast, has zero external deps, and runs in CI.
- **`grpcurl`** talks to any gRPC server with a `.proto` file — it uses
  the Google reference codec. A round-trip via grpcurl proves our wire
  format matches everyone else's, which is what "gRPC compatibility"
  actually means.

Both should be kept green.

## Non-gRPC coexistence

The demo server also registers a plain HTTP `GET /` handler. Hitting it
with `curl --http2-prior-knowledge http://localhost:18020/` returns a
text greeting, which proves the dispatcher's content-type gate cleanly
falls through for non-`application/grpc` requests. Horse routing is
untouched.

## Related

- `plans/horse-grpc-nghttp2.md` — full milestone plan (M1 → M6)
- `patches/horse-provider-nghttp2/src/Horse.Provider.Nghttp2.Grpc.Registry.pas` — the `THorseGrpc` API surface
- `patches/horse-provider-nghttp2/src/Horse.Provider.Nghttp2.Grpc.Dispatcher.pas` — 5-byte framing + trailer emission
- `.claude/skills/delphi-grpc/SKILL.md` — Delphi/gRPC patterns
- `.claude/skills/delphi-http2/SKILL.md` §6 — HTTP/2 trailer plumbing
