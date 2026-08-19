# FPC / Lazarus

The provider compiles and runs on **FPC trunk 3.3.1** with full parity to the Delphi build.

**FPC 3.2.2 is a hard blocker** — `constref` generics regression affects both the HTTP/2 provider and gRPC. Use FPC trunk 3.3.1.

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
