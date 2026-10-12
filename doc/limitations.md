# Limitations

Provider **1.12.0**. The gRPC entries below depend on the *library* version Boss
resolves, not on the provider: `boss.json` declares floors of
`Delphi-nghttp2 >= 1.26.0` and `horse >= 3.3.12` (both since provider 1.11.0), and
Boss takes the newest satisfying them, so a fresh install gets everything marked
resolved here. Pinning an older library brings the corresponding limitation
back — the version that closed each one is named.

Every entry re-checked against the source on 2026-10-12. Until then this page
still said provider 1.9.3 and listed ZigZag/fixed-width scalars as unsupported,
four library releases after they shipped.

- **No HTTP/1.1 fallback** — the server speaks HTTP/2 exclusively. HTTP/1.1-only clients cannot connect. This also constrains what can reverse-proxy it: the proxy's **back leg** must be HTTP/2, which rules out `nginx proxy_pass`, Apache's `mod_proxy_http`, and IIS ARR entirely. Use nginx `grpc_pass`, Apache `mod_proxy_http2` with an `h2c://` backend, or expose directly. See [deployment.md](deployment.md).
- **No in-process hosting** — ISAPI, Apache module, CGI and FastCGI are mutually exclusive with every Horse provider (compile-time `{$MESSAGE FATAL}`). Under those models the web server owns the socket, so there is no HTTP/2 and no gRPC. See [deployment.md](deployment.md).
- **No server push** — deprecated by browsers; out of scope.
- **Streaming backpressure does not apply under inline dispatch** — with a worker pool (the default) `AWriter.Write` parks the producer at a 1 MB backlog and resumes at 256 KB. Under `WORKER_THREADS_INLINE` the handler *is* the connection thread that would drain the buffer, so waiting could never be satisfied and the buffer is unbounded by construction. See [streaming.md](streaming.md#backpressure).
- ~~**gRPC: ZigZag and fixed-width scalars are not selectable**~~ — **resolved in library 1.20.0** (WIRE-FORM-1). The wire type used to follow the Pascal type, so `sint32`/`sint64` went out as plain varints and `fixed*`/`sfixed*` as varints, and `protogen` refused all six types rather than generate code that would silently mis-encode. Now `[TProtoMember(N, pwfZigZag)]` and `[TProtoMember(N, pwfFixed)]` select the encoding, and `protogen` emits the right attribute for each type. Pinning a library below 1.20.0 brings the refusal back. Also supported: `map<K,V>` since library 1.13.0, repeated fields since M1c.2, and `uint32`/`uint64` above 2^31 since 1.10.0 (below that they were silently corrupted — FIX-PROTO-UINT32-1).
- ~~**gRPC: default-valued scalars are still emitted**~~ — **resolved in library 1.12.0** (CANONICAL-1). A field holding its default (`0`, `''`, `False`, empty `bytes`) is now omitted, so output is byte-for-byte canonical and comparable against other stacks. Explicit presence survives it: a proto3 `optional` field *set* to zero still goes on the wire, because the has-bit rather than the value decides. Kept here rather than deleted because it was a wire-format change — pinning a library below 1.12.0 restores the old, non-canonical (but still wire-legal) output. See [grpc.md](grpc.md#wire-behaviour).
- **gRPC on FPC requires libffi** for `RegisterService<T>` — `sudo apt install libffi-dev` + the libffi FPC package path on the compile line. Suppress with `NGHTTP2_GRPC_NO_FFI` when only using `RegisterMethod`.
- **gRPC requires FPC trunk 3.3.1** — 3.2.2's `Rtti` unit declares no `TCustomAttribute` and its compiler rejects `{$RTTI EXPLICIT}`, both required by the attribute-driven protobuf codec. Everything else — HTTP/2, TLS, mTLS, the epoll event loop, graceful shutdown, streaming and WebSocket — builds and passes on **3.2.2** with `-dHORSE_NGHTTP2_NO_GRPC`. Delphi is unaffected.
- **gRPC: a single message is capped at 4 MB** — on *both* the unary and streaming paths as of 2026-08-24. Previously the cap covered streaming only, so this is a **behaviour change for unary calls**: a message above 4 MB is now rejected where it used to be accepted. Raise `GRPC_MAX_MESSAGE_BYTES` in `Nghttp2.Grpc.StreamReader` if a deployment genuinely needs larger single messages. See [grpc.md](grpc.md#decoder-guards).
- **gRPC: submessage nesting is capped at 100 levels** — `Deserialize` recurses per nested submessage, so a self-referential message type (how protobuf expresses trees) would otherwise let a crafted payload exhaust the stack, which is not catchable. Matches the mainstream protobuf default; real messages do not approach it.
- **Password-protected private keys** — the `SSLKeyPassword` field wires `SSL_CTX_set_default_passwd_cb` but has never been exercised against an encrypted key: re-checked 2026-10-12, no test or fixture in either repository uses one. Treat as experimental.
- **Windows service: one service per process** — `THorseNghttp2Service` (`Horse.Provider.Nghttp2.Daemon`) implements `GetServiceController` for the service the process creates (since provider 1.12.0, SVC-CTRL-2), so an executable hosts one service. That matches Horse itself, which runs one listener per process.
- ~~**Graceful shutdown is untested on the event-loop engines**~~ — **resolved
  2026-09-10, on all three drivers.** Thread driver: `build-fpc.sh` stage 6 (8/8
  witnesses under h2load) and 6b (1 request, 4 on 4 connections, 8 streams on
  1). **epoll**: stage 6c, which asserts the driver actually resolved rather
  than falling back. **IOCP**: `samples/tests/run-tests.bat`, the Windows
  harness — IOCP is Windows-only, so no Linux run can reach it, and until that
  harness existed every Windows script built without running. Kept here rather
  than deleted because this entry carried a wrong figure for months: it reported
  `96/184` for epoll on a stage 6 that did not exist. Do not cite that number.
  See [doc/graceful-shutdown.md](graceful-shutdown.md).
