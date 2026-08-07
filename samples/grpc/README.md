# gRPC-over-HTTP/2 demo — horse-provider-nghttp2 (M4b)

End-to-end demo of the gRPC service registry + dispatcher shipped in M4a.
A Horse server registers two methods, and two clients validate the wire
format independently: a **Delphi-native test suite** (dogfoods the codec)
and **grpcurl** (external interop check).

## What's here

| File | Purpose |
|---|---|
| `HorseNghttp2GrpcDemo.dpr`         | Server — h2c on port 18020 |
| `HorseNghttp2GrpcTestClient.dpr`   | Delphi-native client using `Nghttp2.Client` + `Nghttp2.Protobuf.Rtti` |
| `Sample.Greeter.Messages.pas`      | `TGreetRequest` / `TGreetResponse` / `TEchoRequest` / `TEchoResponse` |
| `Sample.Greeter.Service.pas`       | `TGreeterService.Greet` / `.Echo` handler methods |
| `greeter.proto`                    | Companion schema for grpcurl (tags must match `[TProtoMember(N)]`) |

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
9 passed, 0 failed  (total 9)
All tests PASSED.
```

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
