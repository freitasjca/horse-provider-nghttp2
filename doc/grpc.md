# gRPC

The provider ships a full gRPC v0.1 stack: protobuf codec (all scalar types + nested messages), service registry, and dispatcher. Both registration styles produce identical wire behaviour.

## Registration styles

**Procedural — explicit per-method (`RegisterMethod`):**

```pascal
THorseGrpc.RegisterMethod('/users.UserService/GetUser',
  TGetUserRequest, TGetUserResponse, UserService.GetUser);
```

**IInvokable — one-line service registration (`RegisterService<T>`):**

```pascal
THorseGrpc.RegisterService<IUserService>(TUserServiceImpl.Create);
```

`RegisterService<T>` uses RTTI to walk the interface and register each method automatically. On FPC this requires **libffi** (`sudo apt install libffi-dev` + the libffi FPC package path on the compile line). Suppress with `HORSE_GRPC_NO_FFI` if only using `RegisterMethod`.

## Demo

See `samples/grpc/` for a complete working example:

- `HorseNghttp2GrpcDemo.dpr` — server with `IGreeter` service
- `HorseNghttp2GrpcTestClient.dpr` — native Delphi/FPC client (16 checks)
- `greeter.proto` — for grpcurl interop

Run:

```bat
dcc64 -B samples\grpc\HorseNghttp2GrpcDemo.dpr
samples\grpc\HorseNghttp2GrpcDemo.exe
```

```bat
dcc64 -B samples\grpc\HorseNghttp2GrpcTestClient.dpr
samples\grpc\HorseNghttp2GrpcTestClient.exe
# → 16 passed, 0 failed
```

Add `tls` / `mtls` to the demo and point the client at `https://127.0.0.1:18443` (with `--client-cert tls/client-cert.pem --client-key tls/client-key.pem` for mTLS) to cover the other two transports.

## grpcurl

[grpcurl](https://github.com/fullstorydev/grpcurl) is the standard gRPC command-line client. On Windows, download the binary from the [releases page](https://github.com/fullstorydev/grpcurl/releases) — there is no Chocolatey package.

```
grpcurl -plaintext \
  -import-path samples\grpc \
  -proto greeter.proto \
  -d '{"name":"World"}' \
  localhost:18020 greeter.Greeter/Greet
# → {"message": "Hello, World!"}
```

Always pass `-import-path <dir>` when the `.proto` path is not in the current directory.

## Validation

| Configuration | Result |
|---|---|
| h2c — Windows/Delphi 12 | 16/16 ✅ + grpcurl ✓ |
| h2c — Ubuntu/FPC trunk 3.3.1 | 16/16 ✅ + grpcurl ✓ |
| h2c — Linux64/Delphi | 16/16 ✅ |
| TLS + mTLS — Windows/Delphi 12 | 16/16 ✅ |
| TLS + mTLS — Ubuntu/FPC trunk 3.3.1 | 16/16 ✅ |

## Limitations (v1.0.0)

- **No repeated fields** — `TArray<T>` properties are not yet serialized. Planned.
- **No streaming RPCs** — unary only. Server-streaming, client-streaming, and bidi are planned.
- **FPC requires libffi** for `RegisterService<T>`. Use `RegisterMethod` + `HORSE_GRPC_NO_FFI` to avoid the dependency.
