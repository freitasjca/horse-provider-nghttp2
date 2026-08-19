unit Horse.Provider.Nghttp2.FPC.Daemon;

(*
  Horse nghttp2 Provider — FPC Linux daemon composition
  =====================================================

  Selects the nghttp2 transport for an FPC console-shape binary that is
  supervised by systemd (or any other process supervisor that delivers
  SIGTERM on stop). The THorseProviderNghttp2FPCDaemon class is the
  THorseProvider alias resolved by Horse.pas when HORSE_PROVIDER_NGHTTP2
  + HORSE_APPTYPE_DAEMON are both defined on the FPC compiler.

  nghttp2's Listen blocks the calling thread on a console FPC binary
  (IsConsole = True). The supervisor sends SIGTERM to request shutdown;
  the binary catches it via the POSIX signal handler installed here, calls
  THorse.StopListen which returns Listen to the caller, and the process
  exits cleanly with code 0.

  THorseNghttp2FPCDaemonApp is an optional convenience helper class that
  pre-wires fpSignal(SIGTERM) and fpSignal(SIGINT) to THorse.StopListen.
  Users can call THorseNghttp2FPCDaemonApp.Run(@SetupRoutes, APort)
  instead of writing the signal-handling wiring by hand.

  Mirrors Horse.Provider.CrossSocket.FPC.Daemon line-for-line so the two
  providers are interchangeable from the developer-experience angle.

  FPC note: the .lpr program must list cthreads as the FIRST unit in its
  uses clause (guarded by the FPC+UNIX condition) — nghttp2 spawns accept
  and per-connection threads that require pthreads, which cthreads registers
  with the FPC RTL.
*)

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  Horse.Provider.Nghttp2;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_DAEMON are defined on FPC. }
  THorseProviderNghttp2FPCDaemon = class(THorseProviderNghttp2);

  { User-provided setup procedure: register routes, middleware, config. }
  THorseNghttp2DaemonSetupProc = procedure;

  { Optional convenience runner. Use:

      uses Horse, Horse.Provider.Nghttp2.FPC.Daemon;
      procedure SetupRoutes;
      begin
        THorse.Get('/ping', @GetPing);
      end;
      begin
        THorseNghttp2FPCDaemonApp.Run(@SetupRoutes, 9200);
      end.

    Run installs SIGTERM + SIGINT handlers that call THorse.StopListen,
    invokes ASetup to register routes, then calls THorse.Listen(APort)
    which blocks until a signal arrives. }
  THorseNghttp2FPCDaemonApp = class
  public
    class procedure Run(ASetup: THorseNghttp2DaemonSetupProc; APort: Integer);
  end;

implementation

uses
  Horse;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  // POSIX signal handlers must be reentrant-safe. THorse.StopListen sets
  // a manual-reset event and calls FServer.Stop — both safe to invoke
  // from a signal context on Linux glibc + FPC RTL.
  THorse.StopListen;
end;
{$ENDIF}

class procedure THorseNghttp2FPCDaemonApp.Run(
  ASetup: THorseNghttp2DaemonSetupProc; APort: Integer);
begin
  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  // SIGPIPE: ignore — nghttp2 handles client-side resets internally;
  // the default action (terminate) would crash the daemon on a peer drop.
  fpSignal(SIGPIPE, signalhandler(SIG_IGN));
  {$ENDIF}

  if Assigned(ASetup) then
    ASetup();

  THorse.Listen(APort);   // blocks until StopListen unblocks it
end;

end.
