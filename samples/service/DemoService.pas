unit DemoService;

// ============================================================================
//  Windows Service class for HorseNghttp2ServiceDemo.
//
//  Inherits from THorseNghttp2Service (Horse.Provider.Nghttp2.Daemon.pas),
//  which itself is a TService (Vcl.SvcMgr) with:
//    ServiceStart ? spawns worker thread that calls THorse.Listen(Port)
//    ServiceStop  ? THorse.StopListen + WaitFor(worker)
//
//  This unit adds route registration in ServiceCreate (fires before
//  ServiceStart). No custom lifecycle overrides needed � the base class
//  handles everything.
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
    procedure ServiceCreate(Sender: TObject);
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

implementation

{%CLASSGROUP 'Vcl.Controls.TControl'}

{$R *.dfm}

// Route handlers are unit-scope procedures (matching Horse.Callback shape).
// They can't reference the service instance's Self, so we capture the port
// in a unit-scope var set from ServiceCreate.
var
  GServicePort: Integer = 9200;   // updated by ServiceCreate; used in GetStatus

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
  inherited;   // base class: sets Port := 9200 + wires OnStart/OnStop
  // Application is initialized by now (CreateForm runs after Initialize),
  // so THorse's singleton is ready to accept routes. Registering here
  // sidesteps the .dfm OnCreate binding entirely — no way to accidentally
  // strip it in the designer.
  GServicePort := Self.Port;
  THorse.Get('/ping',   GetPing);
  THorse.Get('/status', GetStatus);
end;

procedure THorseDemoSvc.ServiceCreate(Sender: TObject);
begin
  // Legacy handler — kept in case the .dfm's OnCreate binding is restored
  // by the developer. If OnCreate is wired, routes get re-registered here
  // (Horse.Get is not idempotent — this would double-register), so this
  // handler is effectively a no-op in the normal path. Left in place so
  // the .pas keeps compiling regardless of DFM state.
  Self.Port    := 9200;
  GServicePort := Self.Port;
end;

end.
