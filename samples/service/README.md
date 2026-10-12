# HorseNghttp2ServiceDemo

Runnable Windows Service demo for `HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_DAEMON` on Delphi/Windows.

Inherits `THorseNghttp2Service` (`Vcl.SvcMgr.TService` subclass) from `Horse.Provider.Nghttp2.Daemon.pas`.

## What this validates

- Route registration in `ServiceCreate` fires before `ServiceStart`
- `ServiceStart` returns promptly to the SCM (worker thread does the blocking `Listen`)
- `ServiceStop` calls `THorse.StopListen` → SEC-30 active-request drain → `WaitFor` worker thread → clean stop
- Service can be installed, started, hit with curl, stopped, and uninstalled cleanly
- No handle / thread leaks across install / start / stop / uninstall cycles

## Prerequisites

- Windows (any modern version — 7 SP1+, Server 2008 R2+)
- Admin CMD or PowerShell (service install/uninstall requires admin)
- `nghttp2.dll` on the DLL search path (next to the .exe is easiest)
- Delphi 10.4+ (or FPC/Lazarus with an equivalent service framework — not covered here)

## Build

Open `HorseNghttp2ServiceDemo.dpr` in Delphi IDE. Delphi should auto-create the `.dproj`. Add:

- Search path to `..\..\..\Delphi-nghttp2\src` (so `Nghttp2.*` resolve)
- Search path to `..\..\src` (so `Horse.Provider.Nghttp2.*` resolve)
- Ensure your Horse checkout has the `HORSE_PROVIDER_NGHTTP2` hooks applied

Then Project → Build → produces `HorseNghttp2ServiceDemo.exe`.

### Keeping the IDE designing the service as a service (SVC-DFM-1, provider 1.12.0+)

- `THorseNghttp2Service` has its own `.dfm`. The `.dpr` lists its unit as
  `Horse.Provider.Nghttp2.Daemon in '..\..\src\Horse.Provider.Nghttp2.Daemon.pas' {HorseNghttp2Service: TService}`,
  and `DemoService` as `{HorseDemoSvc: TService}`.
- In the `.dproj`, both entries need `<Form>` and `<DesignClass>TService</DesignClass>`.
  The IDE's *Add to Project* drops the `: TService`, so check after adding a unit.
- `DemoService.dfm` starts with `inherited` and holds only what differs (`DisplayName`).
- If the IDE says "Property DisplayName does not exist", it is designing the service
  as a form. Answer **Cancel**: *Ignore* saves a form `.dfm`, and the exe then dies
  at start with `EReadError ... Margins.Left`.
- Keep `HorseNghttp2Service` out of *Project Options > Forms > Auto-create*.

## Install (admin CMD)

```
cd C:\path\to\HorseNghttp2ServiceDemo.exe
HorseNghttp2ServiceDemo.exe /install
```

Output: `Service installed successfully.` — the service is registered as `HorseDemoSvc` (the `Name` in `DemoService.dfm`; display name "Horse Nghttp2 Demo"), StartType = Manual.

## Start

```
sc start HorseDemoSvc
```

Output should show `STATE: 4 RUNNING` within a second (worker thread started, SCM ack returned).

## Test (from another terminal)

```
curl --http2-prior-knowledge http://127.0.0.1:9200/ping
# → pong

curl --http2-prior-knowledge http://127.0.0.1:9200/status
# → {"shape":"windows-service","port":9200,"pid":<N>}
```

## Verify the service is healthy

```
sc query HorseDemoSvc
# STATE: 4  RUNNING
#   (STOPPABLE, NOT_PAUSABLE, ACCEPTS_SHUTDOWN)
```

## Stop

```
sc stop HorseDemoSvc
```

Should transition from RUNNING → STOP_PENDING → STOPPED within a second (unless an in-flight request is still draining — SEC-30 waits for it). Output: `STATE: 1 STOPPED`.

## Uninstall

```
HorseNghttp2ServiceDemo.exe /uninstall
```

Output: `Service uninstalled successfully.`

## Validation checklist

- [ ] Install succeeds; `sc query HorseDemoSvc` shows STOPPED
- [ ] Start succeeds within <1s; SCM state = RUNNING
- [ ] `curl .../ping` returns `pong`
- [ ] `curl .../status` returns JSON with `"shape":"windows-service"` and the correct PID (visible in Task Manager)
- [ ] Stop succeeds within <1s in the no-load case; longer only if a request is in flight
- [ ] Uninstall succeeds; `sc query HorseDemoSvc` returns `The specified service does not exist`
- [ ] Multiple start/stop cycles work without needing a service reinstall
- [ ] Task Manager confirms no orphaned `HorseNghttp2ServiceDemo.exe` process after stop

## Runtime requirements

- `nghttp2.dll` next to `HorseNghttp2ServiceDemo.exe`, OR on Windows PATH
- Match architecture: Win32 exe → 32-bit `nghttp2.dll`; Win64 → 64-bit
- No OpenSSL needed unless TLS is enabled (add cert config via `HorseNghttp2ServiceDemo.dpr` — see `HorseNghttp2TestServer.exe tls` in `../tests/` for the pattern)

## Troubleshooting

- **`sc start` fails with error 1053** ("did not respond to the start... in a timely fashion"): probably `nghttp2.dll` isn't findable — the process fails during unit initialization before it can call `SetServiceStatus(SERVICE_START_PENDING)`. Fix: copy `nghttp2.dll` next to the .exe.
- **Service starts but curl `Connection refused`**: check port 9200 isn't blocked by Windows Firewall. Add rule: `netsh advfirewall firewall add rule name="HorseNghttp2Demo" dir=in action=allow protocol=TCP localport=9200`
- **`sc start` fails with 1067**: read `service-diag.log` next to the .exe (written by `MyStart`/`MyStop`), then the Application event log (`wevtutil qe Application /q:"*[System[Provider[@Name='Application Error']]]" /c:3 /rd:true /f:text`). Exception `0x0EEDFADE` with a log ending at "Calling Application.Run" means a missing `GetServiceController`; the base class implements it since 1.12.0.
- **Service starts, curl works, but `sc stop` hangs**: likely an in-flight request never completing. Force-stop via `taskkill /F /IM HorseNghttp2ServiceDemo.exe` and investigate the route handler.

## Prereq

Requires the Horse framework with `HORSE_PROVIDER_NGHTTP2` hooks in `Horse.pas`.
