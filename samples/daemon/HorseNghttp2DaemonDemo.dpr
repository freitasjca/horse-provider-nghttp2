program HorseNghttp2DaemonDemo;

// ============================================================================
//  Cross-platform Delphi daemon demo for horse-provider-nghttp2.
//
//  On MSWINDOWS this compiles as a console app (SC-hostable via a wrapper);
//  the real value is on Linux where THorseNghttp2LinuxDaemonApp installs
//  SIGTERM / SIGINT handlers that call THorse.StopListen.
//
//  Build (Windows):
//    dcc32 -CC -B HorseNghttp2DaemonDemo.dpr
//
//  Build (Delphi Linux cross-compile):
//    Project → Add Platform → 64-bit Linux
//    Project → Build
//
//  Run:
//    Windows: HorseNghttp2DaemonDemo.exe   (blocks; Ctrl-C to stop)
//    Linux:   ./HorseNghttp2DaemonDemo &   (backgrounded; kill -TERM <pid> to stop)
//
//  Test (from another terminal):
//    curl --http2-prior-knowledge http://127.0.0.1:9200/ping    → "pong"
//    curl --http2-prior-knowledge http://127.0.0.1:9200/status  → JSON status
//
//  Graceful shutdown:
//    Linux: kill -TERM <pid>   → HandleStopSignal → StopListen → SEC-30 drain
//    Linux: kill -INT <pid>    → same path (Ctrl-C in foreground)
//    (kill -9 <pid> would be ungraceful — bypasses signal handler)
// ============================================================================

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}
{$DEFINE HORSE_APPTYPE_DAEMON}

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

uses
  {$IF DEFINED(FPC)}
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF }
  {$ELSE}
  System.SysUtils,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF }
  {$IFDEF POSIX}
  Posix.Unistd,
  {$ENDIF }
  {$IFEND }
  Horse,
  Horse.Provider.Nghttp2.Daemon,
  Nghttp2.Types in '..\..\..\Delphi-nghttp2\src\Nghttp2.Types.pas',
  Nghttp2.Tls in '..\..\..\Delphi-nghttp2\src\Nghttp2.Tls.pas',
  Nghttp2.Socket in '..\..\..\Delphi-nghttp2\src\Nghttp2.Socket.pas',
  Nghttp2.Session in '..\..\..\Delphi-nghttp2\src\Nghttp2.Session.pas',
  Nghttp2.Server in '..\..\..\Delphi-nghttp2\src\Nghttp2.Server.pas',
  Nghttp2.OpenSSL in '..\..\..\Delphi-nghttp2\src\Nghttp2.OpenSSL.pas',
  Nghttp2.Native in '..\..\..\Delphi-nghttp2\src\Nghttp2.Native.pas';

const
  DAEMON_PORT = 9200;

// ─── Route handlers ─────────────────────────────────────────────────────────

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

function CurrentPid: Integer;
begin
{$IF DEFINED(FPC) AND DEFINED(UNIX)}
  Result := FpGetPid;
{$ELSEIF DEFINED(POSIX)}
  Result := getpid;      // Posix.Unistd on Delphi/Linux + Delphi/macOS
{$ELSE}
  Result := GetCurrentProcessId;   // Winapi.Windows
{$IFEND}
end;

procedure GetStatus(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"shape":"daemon","port":%d,"pid":%d}',
                  [DAEMON_PORT, CurrentPid]));
end;

// ─── Route registration (called from THorseNghttp2LinuxDaemonApp.Run) ──────

procedure Setup;
begin
  THorse.Get('/ping',   GetPing);
  THorse.Get('/status', GetStatus);
end;

// ─── Main ──────────────────────────────────────────────────────────────────

begin
  WriteLn('HorseNghttp2DaemonDemo — nghttp2 daemon on port ', DAEMON_PORT);
  WriteLn('Signal handlers installed for SIGTERM + SIGINT + SIGPIPE (Linux only).');
  WriteLn('Test:  curl --http2-prior-knowledge http://127.0.0.1:', DAEMON_PORT, '/ping');
  WriteLn('Stop:  Ctrl-C (foreground) or kill -TERM <pid> (background)');
  WriteLn;

  // THorseNghttp2LinuxDaemonApp.Run:
  //  1. Installs signal handlers for SIGTERM/SIGINT (both → THorse.StopListen),
  //     and SIG_IGN for SIGPIPE (so peer resets don't crash the process).
  //  2. Invokes Setup to register routes.
  //  3. Calls THorse.Listen(Port) which blocks in the console app path
  //     until StopListen unblocks it.
  //
  // On Windows this class doesn't exist ({$IFNDEF MSWINDOWS} in the unit) —
  // fall back to a plain THorse.Listen so this demo compiles cross-platform.
{$IFNDEF MSWINDOWS}
  THorseNghttp2LinuxDaemonApp.Run(Setup, DAEMON_PORT);
{$ELSE}
  Setup;
  THorse.Listen(DAEMON_PORT);   // Ctrl-C exits via console handler
{$ENDIF}

  WriteLn('HorseNghttp2DaemonDemo — shut down cleanly.');
end.
