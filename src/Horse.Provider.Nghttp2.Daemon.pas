unit Horse.Provider.Nghttp2.Daemon;

(*
  Horse nghttp2 Provider — Delphi cross-platform Daemon composition
  =================================================================

  Selects the nghttp2 transport for a Delphi binary running as a long-
  running OS-supervised process. The THorseProviderNghttp2Daemon class is
  the THorseProvider alias resolved by Horse.pas when HORSE_PROVIDER_NGHTTP2
  + HORSE_APPTYPE_DAEMON are both defined on the Delphi compiler —
  REGARDLESS of target platform.

  Two OS-specific paths in the same unit:

    {$IFDEF MSWINDOWS}   THorseNghttp2Service
                         A TService base class (Vcl.SvcMgr) that auto-wires
                         ServiceStart -> THorse.Listen on a worker thread,
                         ServiceStop  -> THorse.StopListen + drain.

    {$ELSE}              THorseNghttp2LinuxDaemonApp
                         A static helper. Run() installs POSIX signal
                         handlers (SIGTERM/SIGINT/SIGPIPE) and then calls
                         THorse.Listen which blocks until StopListen is
                         invoked from a handler.

  Mirrors horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Daemon.pas
  line-for-line — the developer experience is identical across providers.

  Mental model: HORSE_APPTYPE_DAEMON = "OS-supervised long-running process".
  Whether that process is a Windows Service or a Linux daemon is a function
  of the build target, not the define.
*)

interface

uses
{$IFDEF MSWINDOWS}
  Vcl.SvcMgr,
{$ENDIF}
{$IFDEF LINUX}
  Posix.Signal,
{$ENDIF}
{$IFDEF POSIX}
  Posix.Stdlib,
{$ENDIF}
  System.SysUtils,
  System.Classes,
  Horse.Provider.Nghttp2;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_NGHTTP2 + HORSE_APPTYPE_DAEMON are defined on Delphi
    (any target). Inherits all transport behaviour from THorseProviderNghttp2;
    only the lifecycle wrappers below differ by platform. }
  THorseProviderNghttp2Daemon = class(THorseProviderNghttp2);

{$IFDEF MSWINDOWS}
  { Optional convenience TService base class. Users may inherit:

      type TMyHorseService = class(THorseNghttp2Service)
        procedure ServiceCreate(Sender: TObject);   // register routes here
      end;

    or ignore this class entirely and write the ServiceStart / ServiceStop
    pair by hand. The class spawns a worker thread for THorse.Listen so
    the SCM ack is not blocked by transport-setup latency (though for
    nghttp2 that's typically well under 100 ms). }
  THorseNghttp2Service = class(TService)
  private
    FPort:           Integer;
    FListenerThread: TThread;
  protected
    procedure DoServiceStart(Sender: TService; var Started: Boolean);
    procedure DoServiceStop(Sender: TService; var Stopped: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    { Set this BEFORE the service starts (in ServiceCreate, typically) so
      the worker thread binds the intended port. Default 9200 matches
      THorseNghttp2Config.Default.Port. }
    property Port: Integer read FPort write FPort default 9200;
  end;
{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}
  { User-provided setup procedure: register routes, middleware, config. }
  THorseNghttp2DaemonSetupProc = procedure;

  { Optional convenience runner for Delphi binaries cross-compiled to
    Linux (or other POSIX targets).

      uses Horse, Horse.Provider.Nghttp2.Daemon;
      procedure SetupRoutes;
      begin
        THorse.Get('/ping', GetPing);
      end;
      begin
        THorseNghttp2LinuxDaemonApp.Run(SetupRoutes, 9200);
      end.

    Run installs SIGTERM + SIGINT handlers that call THorse.StopListen,
    ignores SIGPIPE (so peer drops don't crash the daemon), invokes
    ASetup to register routes, then calls THorse.Listen(APort) which
    blocks until a signal arrives. }
  THorseNghttp2LinuxDaemonApp = class
  public
    class procedure Run(ASetup: THorseNghttp2DaemonSetupProc; APort: Integer); static;
  end;
{$ENDIF MSWINDOWS}

implementation

uses
  Horse;

{$IFDEF MSWINDOWS}

{ THorseNghttp2Service }

constructor THorseNghttp2Service.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort := 9200;
  OnStart := DoServiceStart;
  OnStop  := DoServiceStop;
end;

destructor THorseNghttp2Service.Destroy;
begin
  if Assigned(FListenerThread) then
  begin
    THorse.StopListen;
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
  inherited;
end;

procedure THorseNghttp2Service.DoServiceStart(Sender: TService;
  var Started: Boolean);
var
  LPort: Integer;
begin
  LPort := FPort;
  { Run Listen on a dedicated worker thread so ServiceStart returns
    promptly to the SCM. nghttp2's Listen is non-blocking in a service app
    (IsConsole = False), so this thread mostly idles after the accept
    thread starts — its main job is to keep the call site stable for the
    matching WaitFor in DoServiceStop. }
  FListenerThread := TThread.CreateAnonymousThread(
    procedure begin THorse.Listen(LPort); end);
  FListenerThread.FreeOnTerminate := False;
  FListenerThread.Start;
  Started := True;
end;

procedure THorseNghttp2Service.DoServiceStop(Sender: TService;
  var Stopped: Boolean);
begin
  THorse.StopListen;                   // graceful drain via SEC-30
  if Assigned(FListenerThread) then
  begin
    FListenerThread.WaitFor;           // wait for Listen to actually return
    FreeAndNil(FListenerThread);
  end;
  Stopped := True;
end;

{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}

procedure HandleStopSignal(ASignal: Integer); cdecl;
begin
  { POSIX signal handler — minimal reentrant-safe work only.
    THorse.StopListen sets a manual-reset event and calls FServer.Stop;
    both are safe to invoke from a signal context on glibc + Delphi RTL. }
  THorse.StopListen;
end;

{ FIX-DAEMON-SHUTDOWN-2 (2026-08-06) — install signal handlers via sigaction()
  instead of signal().  Two reasons this is required on Delphi Linux:

  1. signal() has historically-nondeterministic behavior across libc
     versions — the POSIX spec says its "chaining vs replace" semantics
     are implementation-defined.  sigaction() is atomic and unambiguous.

  2. Delphi Linux's System.pas installs its own SIGINT handler during unit
     initialization to translate Ctrl-C into EControlC.  When our earlier
     signal(SIGINT, ...) call ran later, glibc's signal() may have chained
     rather than replaced — Delphi RTL's handler still fired, set
     CtrlBreakHit := True, and the next I/O call raised EControlC even
     after our handler had already called StopListen.  sigaction() with
     sa_mask cleared and sa_flags = SA_RESTART fully replaces the previous
     handler on all Linux libc implementations. }
procedure InstallStopSignal(ASignal: Integer);
var
  LAct: sigaction_t;
begin
  FillChar(LAct, SizeOf(LAct), 0);
  LAct._u.sa_handler := @HandleStopSignal;
  { SA_RESTART: restart interrupted syscalls after handler returns.  Prevents
    accept()/recv() from returning EINTR spuriously on unrelated signals. }
  LAct.sa_flags := SA_RESTART;
  { sigemptyset would be preferable but sigset_t is a packed bit-array we
    can zero-fill by hand (already done by FillChar above). }
  sigaction(ASignal, @LAct, nil);
end;

procedure InstallIgnoreSignal(ASignal: Integer);
var
  LAct: sigaction_t;
begin
  FillChar(LAct, SizeOf(LAct), 0);
  LAct._u.sa_handler := TSignalHandler(SIG_IGN);
  sigaction(ASignal, @LAct, nil);
end;

{ THorseNghttp2LinuxDaemonApp }

class procedure THorseNghttp2LinuxDaemonApp.Run(
  ASetup: THorseNghttp2DaemonSetupProc; APort: Integer);
begin
  {$IFDEF LINUX}
  InstallStopSignal(SIGTERM);
  InstallStopSignal(SIGINT);
  { SIGPIPE: ignore — nghttp2 handles client-side resets internally;
    the default action (terminate) would crash the daemon on a peer drop. }
  InstallIgnoreSignal(SIGPIPE);
  {$ENDIF}

  if Assigned(ASetup) then
    ASetup();

  { Even after FIX-DAEMON-SHUTDOWN-2, keep the EControlC guard as a defensive
    fallback — some Delphi Linux builds may still route Ctrl-C through their
    own RTL exception path regardless of sigaction ownership.  StopListen is
    idempotent, so this is cheap on the false-positive path. }
  try
    THorse.Listen(APort);              { blocks until StopListen unblocks it }
  except
    on EControlC do
      THorse.StopListen;
  end;
end;

{$ENDIF MSWINDOWS}

end.
