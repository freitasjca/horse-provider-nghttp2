unit Horse.Provider.Nghttp2.FPC.HTTPApplication;

{
  Horse nghttp2 Provider — FPC HTTPApplication composition
  ========================================================

  Provides a convenience alias and runner for users who structure their
  FPC project as an HTTPApplication but want nghttp2 as the transport.

  Functionally, this is the same shape as Horse.Provider.Nghttp2.FPC.Daemon:
  both are console-shape FPC binaries where nghttp2 owns the main loop
  (Listen blocks; signal handlers unblock). The HTTPApplication name is
  retained for users whose projects are organised around the fphttpapp
  vocabulary — but Application.Run from fphttpapp is NOT called, because
  nghttp2 owns the loop, not fphttpapp.

  Two competing event loops in one process is the failure mode that
  PATCH-HORSE-1 explicitly prevents at compile time. Do not call
  Application.Run when this unit is in scope.

  THorseNghttp2FPCHTTPApp.Run delegates to the same Daemon-style helper
  as Horse.Provider.Nghttp2.FPC.Daemon.

  Mirrors Horse.Provider.CrossSocket.FPC.HTTPApplication line-for-line so
  the two providers are interchangeable from the developer-experience angle.
}

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  Horse.Provider.Nghttp2,
  Horse.Provider.Nghttp2.FPC.Daemon;

type
  { Marker subclass — present so users explicitly referencing this unit
    get a class name that matches their project's vocabulary. Functionally
    identical to THorseProviderNghttp2FPCDaemon. }
  THorseProviderNghttp2FPCHTTPApplication = class(THorseProviderNghttp2);

  { Convenience alias of the Daemon-style setup procedure. }
  THorseNghttp2HTTPAppSetupProc = THorseNghttp2DaemonSetupProc;

  { Optional convenience runner — delegates to THorseNghttp2FPCDaemonApp
    because the FPC HTTPApplication shape uses the same signal-handler
    + blocking-Listen pattern. Provided as a separate symbol so users
    whose project is organised around HTTPApplication vocabulary can use
    the matching name. }
  THorseNghttp2FPCHTTPApp = class
  public
    class procedure Run(ASetup: THorseNghttp2HTTPAppSetupProc; APort: Integer);
  end;

implementation

class procedure THorseNghttp2FPCHTTPApp.Run(
  ASetup: THorseNghttp2HTTPAppSetupProc; APort: Integer);
begin
  // Same lifecycle as the FPC Daemon helper — signal handlers + blocking
  // Listen. Don't call fphttpapp.Application.Run; nghttp2 owns the loop.
  THorseNghttp2FPCDaemonApp.Run(ASetup, APort);
end;

end.
