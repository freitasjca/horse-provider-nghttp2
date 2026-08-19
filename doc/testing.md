# Testing & benchmarking

## HTTP/2 smoke suite (25 checks)

Quick loop on Windows:

```bat
cd samples\tests
boss install
dcc64 -B HorseNghttp2TestServer.dpr
HorseNghttp2TestServer.exe
```

From a second terminal (Linux / WSL / Git-for-Windows bash):

```bash
HOST=http://localhost:9010 bash samples/tests/run-smoke-tests.sh
# → 25 passed, 0 failed
```

The test server listens on **9010**, not the provider's default 9200.

Driving a Windows-hosted server from WSL needs the host IP rather than `localhost`, and the port opened through Windows Firewall (it *drops* unsolicited inbound instead of rejecting, so a blocked port looks like a hang):

```bash
HOST=http://$(ip route show default | awk '{print $3}'):9010 \
  bash samples/tests/run-smoke-tests.sh
```

Note: many Windows curl builds ship without HTTP/2 (`curl --version | grep HTTP2`), which is why this suite is driven from WSL.

TLS mode:

```bat
HorseNghttp2TestServer.exe tls
```
```bash
HOST=https://localhost:9443 bash samples/tests/run-smoke-tests.sh
```

## 94-check parity suite

`HorseNghttp2TestClient.dpr` is the full 94-check suite (mirrors `HorseCSTestClient`):

```bat
dcc64 -B samples\tests\HorseNghttp2TestClient.dpr
samples\tests\HorseNghttp2TestClient.exe
# → 94 passed, 0 failed in NNms
```

## gRPC demo + grpcurl

```bat
dcc64 -B samples\grpc\HorseNghttp2GrpcDemo.dpr
samples\grpc\HorseNghttp2GrpcDemo.exe

dcc64 -B samples\grpc\HorseNghttp2GrpcTestClient.dpr
samples\grpc\HorseNghttp2GrpcTestClient.exe
# → 16 passed, 0 failed
```

See [doc/grpc.md](grpc.md) for TLS/mTLS variants and grpcurl usage.

## FPC / Linux — build-fpc.sh (12 stages)

```bash
cd samples/tests
bash build-fpc.sh                  # all 12 stages
bash build-fpc.sh --compile-only   # stages 1–4 only
```

Stages narrow in scope so a failure names its own cause: socket alone → session + server → both programs → 94-check suite → graceful-shutdown delivery (nghttp witness) → connection-thread leak growth → two-stage GOAWAY frame trace → TLS → mTLS → gRPC. Requires `h2load` and `nghttp` (`apt install nghttp2-client`).

Stage 12 is the **only** stage that exercises the epoll engine — and it **fails** (not passes) when the engine is unavailable, because `eventloop` degrades silently and a fallback run would retest the thread driver that stage 5 already covered.

## Delphi Linux64 — compile check

```bat
cd samples\tests
build-linux64.bat
```

Compile-only; PAServer does not need to be running.

## Server arguments

`HorseNghttp2TestServer` accepts, in any combination:

| Argument | Effect |
|---|---|
| `tls` / `mtls` | h2 over TLS on 9443; `mtls` also requires a client cert |
| `inline` | No worker pool — pre-2026-08 behaviour, the A/B control |
| `workers=N` | Pin the pool to N threads instead of auto-sizing |
| `eventloop` | Use the epoll/IOCP engine (Linux/Windows respectively) |
| `shutdown-after=N` | Fire `StopListenGraceful` N ms after start |
| `shutdown-timeout=M` | Drain deadline, default 10 000 ms |

It prints its resolved dispatch mode and thread count at startup — a benchmark that cannot tell which configuration it measured is not a measurement.

## Benchmarking

Use `/slow/:ms`. Every other route returns instantly, so benchmarking them measures dispatch overhead and reports it as throughput:

```bash
h2load -n 200 -c 1 -m 50 http://HOST:9010/slow/50
```

Compare against the same run with `inline`. Verdicts for graceful shutdown are **client-side**: `nghttp` rc=0 with complete body is the criterion — not `h2load started == succeeded`, which measures the load generator's GOAWAY reaction. See [doc/graceful-shutdown.md](graceful-shutdown.md).

## Windows builds

Two Windows build approaches, for machines with large IDE Library Paths:

| Script | When to use |
|---|---|
| `scripts/build-dcc.bat` | Always works — bypasses MSBuild, calls `dcc64` directly with only the 4 required paths (~1 150 chars). **Preferred.** |
| `scripts/build-msbuild.bat` | Use only when the IDE Library Path is small (< ~20 000 chars). MSBuild emits the full path 4×; anything over ~32 000 chars causes MSB6003. |
| `scripts/diagnose-dcc-cmdline.{bat,ps1}` | Captures a diagnostic MSBuild log to report what fills an over-long DCC command line. |

```bat
cd samples\tests
scripts\build-dcc.bat tests
scripts\build-dcc.bat grpc
```
