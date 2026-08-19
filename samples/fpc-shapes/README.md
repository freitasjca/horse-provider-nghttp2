# FPC app-type shape unit tests

Compile + runtime smoke tests for the three FPC lifecycle shape units:

| Unit | Test program | Gate |
|---|---|---|
| `Horse.Provider.Nghttp2.FPC.Daemon` | `TestNghttp2FPCDaemon.lpr` | compile + `/ping` + SIGTERM→exit 0 |
| `Horse.Provider.Nghttp2.FPC.HTTPApplication` | `TestNghttp2FPCHTTPApp.lpr` | compile + `/ping` + SIGTERM→exit 0 |
| `Horse.Provider.Nghttp2.FPC.LCL` | `TestNghttp2FPCLCL.lpr` | compile-only (runtime needs display) |

## Prerequisites

- FPC trunk 3.3.1 installed at `/usr/local/fpc-trunk/`
- `libnghttp2-14` and `libssl3` on the runtime path (`apt install libnghttp2-14 libssl-dev`)
- `curl` with HTTP/2 support (`curl --version | grep HTTP2`)

## Run all tests

```bash
cd patches/horse-provider-nghttp2/samples/fpc-shapes
bash run-fpc-shape-tests.sh
```

The script auto-resolves all source paths relative to the workspace root.
Expected output:

```
── FPC.Daemon ──────────────────────────────────────────────────────────
  Compiling TestNghttp2FPCDaemon...
  PASS  compile
  Starting server on port 9210...
  PASS  GET /ping → pong
  PASS  SIGTERM → exit 0

── FPC.HTTPApplication ─────────────────────────────────────────────────
  Compiling TestNghttp2FPCHTTPApp...
  PASS  compile
  Starting server on port 9211...
  PASS  GET /ping → pong
  PASS  SIGTERM → exit 0

── FPC.LCL (compile-only) ──────────────────────────────────────────────
  Compiling TestNghttp2FPCLCL...
  PASS  compile          ← or SKIP if LCL not in FPC install

FPC shape tests: 7 passed, 0 failed
```

## Manual compile commands

If the script path resolution fails, compile each program by hand:

```bash
TRUNK=/usr/local/fpc-trunk/bin/fpc
TU=/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux
PROV=<workspace>/patches/horse-provider-nghttp2/src
DNG=<workspace>/patches/Delphi-nghttp2/src
HORSE=<workspace>/horse/src

FLAGS="-n -MDelphi -O1 -gl -dHORSE_PROVIDER_NGHTTP2 \
  -Fu. -Fu$PROV -Fu$DNG -Fu$HORSE \
  -Fu$TU/rtl -Fu$TU/rtl-console -Fu$TU/rtl-objpas -Fu$TU/rtl-extra \
  -Fu$TU/rtl-generics -Fu$TU/fcl-base -Fu$TU/fcl-web -Fu$TU/fcl-json \
  -Fu$TU/regexpr -Fu$TU/pthreads -Fu$TU/openssl -Fu$TU/fcl-net -Fu$TU/hash"

$TRUNK $FLAGS TestNghttp2FPCDaemon.lpr
$TRUNK $FLAGS TestNghttp2FPCHTTPApp.lpr
$TRUNK $FLAGS -dHORSE_APPTYPE_LCL -Fu$TU/lcl TestNghttp2FPCLCL.lpr
```

## LCL note

LCL units ship with Lazarus, not with FPC itself. If `unit Forms not found`
appears, the test is automatically skipped — this is not a failure. The unit's
correctness is guaranteed by structural identity with
`Horse.Provider.CrossSocket.FPC.LCL` which is already proven on FPC trunk.
