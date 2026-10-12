unit DemoService;

// ============================================================================
//  Windows Service class for HorseNghttp2ServiceDemo.
//
//  Inherits from THorseNghttp2Service (Horse.Provider.Nghttp2.Daemon.pas),
//  which itself is a TService (Vcl.SvcMgr) with:
//    ServiceStart ? spawns worker thread that calls THorse.Listen(Port)
//    ServiceStop  ? THorse.StopListen + WaitFor(worker)
//
//  The constructor registers the routes and swaps in MyStart/MyStop, which wrap
//  THorse.Listen/StopListen with a file log (service-diag.log next to the .exe)
//  so a failed start is diagnosable. GetServiceController comes from the base
//  (SVC-CTRL-2). The .dfm starts with 'inherited' and the .dpr lists the base
//  unit as {HorseNghttp2Service: TService} (SVC-DFM-1).
// ============================================================================

interface

uses
  Winapi.Windows,   { for GetCurrentProcessId }
  System.SysUtils,
  System.Classes,   { for TComponent used in the constructor override signature }
  Vcl.SvcMgr,
  Horse,
  Horse.Provider.Nghttp2.Daemon;

type
  THorseDemoSvc = class(THorseNghttp2Service)
  private
    procedure MyStart(Sender: TService; var Started: Boolean);
    procedure MyStop (Sender: TService; var Stopped: Boolean);
  public
    { Override the constructor to register routes ONCE, right after the
      base class wires OnStart/OnStop. Constructor fires from
      Vcl.SvcMgr.Application.CreateForm — well after Application.Initialize,
      so THorse's singleton is ready. This runs whether or not OnCreate is
      wired in the .dfm (Delphi's designer can strip it during edits). }
    constructor Create(AOwner: TComponent); override;
  end;

var
  HorseDemoSvc: THorseDemoSvc;


{ Public diagnostic logger — callable from the .dpr too so we can log events
  that happen outside the TService instance (Application.Initialize,
  Application.Run return, unhandled exceptions, etc.). Writes to
  service-diag.log next to the .exe; thread-safe. }
procedure WriteDiag(const S: string);

implementation

uses
  System.IOUtils, System.SyncObjs;

{%CLASSGROUP 'System.Classes.TPersistent'}

{$R *.dfm}

{ ── Diagnostic file log ─────────────────────────────────────────────────────
  Single-process critical section serialises writes from SCM / start /
  stop / pipeline threads. }
var
  GDiagLock: TCriticalSection;

procedure WriteDiag(const S: string);
var
  LFile: string;
begin
  LFile := ExtractFilePath(ParamStr(0)) + 'service-diag.log';
  GDiagLock.Acquire;
  try
    try
      TFile.AppendAllText(
        LFile,
        FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + S + sLineBreak);
    except
      // Diagnostic must never crash the service
    end;
  finally
    GDiagLock.Release;
  end;
end;


// Route handlers are unit-scope procedures (matching Horse.Callback shape).
// They can't reference the service instance's Self, so we capture the port
// in a unit-scope var set in the constructor.
var
  GServicePort: Integer = 9200;   // updated in the constructor; used in GetStatus

// --- Route handlers ---------------------------------------------------------

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

procedure GetStatus(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"shape":"windows-service","port":%d,"pid":%d}',
                  [GServicePort, GetCurrentProcessId]));
end;

// --- Service lifecycle ------------------------------------------------------

constructor THorseDemoSvc.Create(AOwner: TComponent);
begin
  // Exactly ONE inherited call: a second one would run the base constructor
  // again and re-wire OnStart/OnStop back to the base, undoing the swap below.
  inherited Create(AOwner);   // base: Port := 9200, OnStart/OnStop := base handlers
  // Replace the base handlers with the instrumented versions below.
  OnStart := MyStart;
  OnStop  := MyStop;
  // Application is initialized by now (CreateForm runs after Initialize),
  // so THorse's singleton is ready to accept routes. Registering here
  // sidesteps the .dfm OnCreate binding entirely — no way to accidentally
  // strip it in the designer.
  GServicePort := Self.Port;
  THorse.Get('/ping',   GetPing);
  THorse.Get('/status', GetStatus);
end;

procedure THorseDemoSvc.MyStart(Sender: TService; var Started: Boolean);
{$IFDEF DEBUG_WAIT_FOR_IDE}
var I: Integer;
{$ENDIF}
begin
  WriteDiag('MyStart entered');

  {$IFDEF DEBUG_WAIT_FOR_IDE}
  // Window for "Run → Attach to Process" from the Delphi IDE.
  // Enable by defining DEBUG_WAIT_FOR_IDE in Project → Options → Building →
  // Delphi Compiler → Conditional defines.
  WriteDiag('DEBUG_WAIT_FOR_IDE — sleeping 30 s for IDE attach');
  for I := 1 to 30 do
  begin
    Sleep(1000);
    ServiceThread.ProcessRequests(False);   // keep SCM happy during the wait
  end;
  WriteDiag('Wait window elapsed, proceeding');
  {$ENDIF}

  try
    WriteDiag(Format('Calling THorse.Listen(%d) synchronously', [Port]));
    // IsConsole=False inside a service, so InternalListen returns immediately
    // after THttpServer.WaitStarted — no anonymous thread needed.
    THorse.Listen(Port);
    WriteDiag('THorse.Listen returned');
    Started := True;
    WriteDiag('Started := True');
  except
    on E: Exception do
    begin
      WriteDiag(Format('MyStart EXCEPTION %s: %s',
        [E.ClassName, E.Message]));
      // Also surface to Event Viewer so "sc start" / Services.msc shows it
      LogMessage(Format('Horse start failed: %s: %s',
        [E.ClassName, E.Message]), EVENTLOG_ERROR_TYPE);
      Started := False;
    end;
  end;
end;

procedure THorseDemoSvc.MyStop(Sender: TService; var Stopped: Boolean);
begin
  WriteDiag('MyStop entered');
  try
    THorse.StopListen;
    WriteDiag('THorse.StopListen returned');
    Stopped := True;
  except
    on E: Exception do
    begin
      WriteDiag(Format('MyStop EXCEPTION %s: %s',
        [E.ClassName, E.Message]));
      LogMessage(Format('Horse stop failed: %s: %s',
        [E.ClassName, E.Message]), EVENTLOG_ERROR_TYPE);
      Stopped := True;  // tell SCM we stopped anyway — process is going away
    end;
  end;
end;

initialization
  GDiagLock := TCriticalSection.Create;

finalization
  GDiagLock.Free;

end.

