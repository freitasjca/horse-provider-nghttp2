# Limitations (v1.0.0)

- **No HTTP/1.1 fallback** — the server speaks HTTP/2 exclusively. HTTP/1.1-only clients cannot connect.
- **No server push** — deprecated by browsers; out of scope.
- **gRPC: no streaming RPCs** — unary only. Server-streaming, client-streaming, and bidi streaming are planned.
- **gRPC: no repeated fields in the codec** — `TArray<T>` properties are not yet serialized. Planned.
- **gRPC on FPC requires libffi** for `RegisterService<T>` — `sudo apt install libffi-dev` + the libffi FPC package path on the compile line. Suppress with `HORSE_GRPC_NO_FFI` when only using `RegisterMethod`.
- **FPC 3.2.2 is unsupported** — `constref` generics regression affects both the HTTP/2 provider and gRPC. Use FPC trunk 3.3.1.
- **Password-protected private keys** — the `SSLKeyPassword` field wires `SSL_CTX_set_default_passwd_cb` but has never been exercised against an encrypted key. Treat as experimental.
- **Event-loop graceful shutdown** — IOCP driver not yet re-validated with the correct nghttp witness gate; epoll driver reports 96/184 on stage 6. Thread driver is fully validated. See [doc/graceful-shutdown.md](graceful-shutdown.md).
