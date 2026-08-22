# FPC / Lazarus

The provider compiles and runs on **FPC trunk 3.3.1** with full parity to the Delphi build, and on **FPC 3.2.2** with everything except gRPC.

**FPC 3.2.2 — supported, minus gRPC.** Build with `-dHORSE_NGHTTP2_NO_GRPC`;
`build-fpc.sh` selects it automatically from `fpc -iV`. Verified 2026-08-22:
24 stages pass, 1 explicit skip. HTTP/2 (h2c, TLS, mTLS), the epoll event loop,
graceful shutdown, streaming, backpressure and WebSocket RFC 8441 all pass —
106/106 on six suite configurations.

**gRPC needs trunk 3.3.1.** 3.2.2's `Rtti` unit declares no `TCustomAttribute`
and the compiler rejects `{$RTTI EXPLICIT}`; the protobuf codec and
`RegisterService<T>` depend on both.

*Earlier revisions of this file called 3.2.2 a hard blocker and blamed a
`constref` generics regression. That was wrong: `constref` appears nowhere in
either source tree. The real 3.2.2 gaps were `TCustomAttribute` (gRPC only) and
two runtime defects — `TThread.ProcessorCount` returning 1, and a stream-writer
factory registration order bug in Horse core.*

> **The 3.2.2 results above assume a patched Horse.** The stream-writer factory
> fix lives in Horse core and is still an open pull request
> ([#552](https://github.com/HashLoad/horse/pull/552)). On stock Horse + FPC
> 3.2.2, streaming and SSE return total silence — no headers, no body, no
> error — because `FStreamWriterFactory` is a last-writer-wins class var whose
> winner depends on unit initialization order, and 3.2.2 orders it differently
> from trunk. See [Horse core requirements](../README.md#horse-core-requirements).

## gRPC on FPC

`RegisterService<T>` additionally requires **libffi**:

```bash
sudo apt install libffi-dev
```

Add the libffi FPC package path (`-Fu<fpc-trunk>/lib/.../libffi`) to the compile line. Define `HORSE_GRPC_NO_FFI` to suppress this dependency when only the procedural `RegisterMethod` API is used.

## .lpr requirements

`.lpr` files must list `cthreads` as the **first** unit in the `uses` clause, guarded by `{$IF DEFINED(FPC) AND DEFINED(UNIX)}`:

```pascal
uses
  {$IF DEFINED(FPC) AND DEFINED(UNIX)}
  cthreads,
  {$ENDIF}
  Horse, ...
```

The nghttp2 accept loop spawns threads; without the pthreads driver, the binary aborts at the first thread creation.

## FPC app-type shape units

Mirror the Delphi cross-product units for FPC/Lazarus binary shapes:

| Unit | Selected by | Lifecycle |
|---|---|---|
| `Horse.Provider.Nghttp2.FPC.Daemon` | `HORSE_PROVIDER_NGHTTP2` + `HORSE_APPTYPE_DAEMON` | `THorseNghttp2FPCDaemonApp.Run(@Setup, Port)` — `fpSignal(SIGTERM/SIGINT)` + blocking `Listen` |
| `Horse.Provider.Nghttp2.FPC.HTTPApplication` | `HORSE_PROVIDER_NGHTTP2` (no APPTYPE) | Same as Daemon via delegation |
| `Horse.Provider.Nghttp2.FPC.LCL` | `HORSE_PROVIDER_NGHTTP2` + `HORSE_APPTYPE_LCL` | `TfrmHorseNghttp2LCLHost` base form — auto-`Listen` on `FormCreate` |

See `samples/fpc-shapes/` for compile + runtime smoke tests for all three shapes, and `run-fpc-shape-tests.sh` to run them automatically.

## FPC compile — one command

```bash
cd samples/tests
bash build-fpc.sh          # 12 stages: compile → 94 checks → TLS → mTLS → gRPC → drain → leak → GOAWAY
bash build-fpc.sh --compile-only   # stages 1-4 only
```

Requires `h2load` and `nghttp` on the PATH (`apt install nghttp2-client`).

## Delphi Linux64 — compile check

```bat
cd samples\tests
build-linux64.bat
```

Runs `dcclinux64` over the Linux64 code paths. Compile-only — PAServer does not need to be running.
