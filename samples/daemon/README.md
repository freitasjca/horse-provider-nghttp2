# HorseNghttp2DaemonDemo

Runnable proof of the `HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_DAEMON` cross-product for **cross-platform Delphi daemon apps** (Linux focus; Windows falls back to plain Listen).

Exercises `THorseNghttp2LinuxDaemonApp.Run` from `Horse.Provider.Nghttp2.Daemon.pas`.

## What this validates

- Signal handlers install correctly (`SIGTERM` / `SIGINT` → `THorse.StopListen`; `SIGPIPE` → ignored)
- `Setup` callback fires and registers routes before `Listen`
- `THorse.Listen` blocks in the console-app path until a signal arrives
- Graceful shutdown: `StopListen` → SEC-30 active-request drain → clean exit
- Peer resets don't crash the daemon (SIGPIPE ignored)

## Build

### Windows (Delphi)

```
dcc32 -CC -B HorseNghttp2DaemonDemo.dpr
```

On Windows this compiles cleanly but the `THorseNghttp2LinuxDaemonApp` path is skipped via `{$IFNDEF MSWINDOWS}` — you get plain `THorse.Listen` with Ctrl-C for shutdown. The Windows equivalent (Windows Service) is in `../service/`.

### Linux (Delphi cross-compile)

1. Delphi IDE → Project → Add Platform → **64-bit Linux**
2. Ensure PAServer is running on the target Linux box (or configure a remote profile)
3. Project → Build (Release, 64-bit Linux target)
4. The `.deploy` artifacts land on the Linux machine at your configured path

Alternatively via command line:
```
dcclinux64 -CC -B HorseNghttp2DaemonDemo.dpr
scp HorseNghttp2DaemonDemo user@linux:/opt/horse-demo/
```

## Run

**Foreground (Ctrl-C to stop):**
```
./HorseNghttp2DaemonDemo
```

**Background (kill -TERM to stop gracefully):**
```
./HorseNghttp2DaemonDemo &
echo $! > daemon.pid
# ... later:
kill -TERM $(cat daemon.pid)
```

## Test

From another terminal (or via WSL to hit the Linux daemon on the LAN):

```
curl --http2-prior-knowledge http://127.0.0.1:9200/ping
# → pong

curl --http2-prior-knowledge http://127.0.0.1:9200/status
# → {"shape":"daemon","port":9200,"pid":<N>}
```

## Validation checklist

- [ ] `HorseNghttp2DaemonDemo` starts, prints banner, blocks
- [ ] `curl .../ping` returns `pong`
- [ ] `curl .../status` returns JSON with the correct pid
- [ ] `kill -TERM <pid>` triggers graceful shutdown, process exits cleanly
- [ ] Console prints "shut down cleanly" (proves the after-Listen path executed)
- [ ] `kill -PIPE <pid>` (or a peer resetting mid-request) does NOT crash the daemon

## Runtime requirements

- `libnghttp2.so.14` on the DLL search path (typically installed via `apt install libnghttp2-14`)
- No OpenSSL needed unless you enable TLS (see `HorseNghttp2TestServer.exe tls` in `../tests/` for the h2c → h2 upgrade pattern)

## Prereq

Requires the Horse framework with the `HORSE_PROVIDER_NGHTTP2` hooks applied (see `patches/horse/src/Horse.pas` snapshot in the workspace root).
