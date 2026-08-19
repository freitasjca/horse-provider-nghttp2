unit Sample.Greeter.Service;

// ============================================================================
//  Sample.Greeter.Service — gRPC handler implementations for the demo.
//
//  Two coexisting shapes:
//
//  1. **TGreeterService (M4a procedural)** — plain methods matching
//     `procedure(AReq, AResp: TObject) of object`. Used with
//     `THorseGrpc.RegisterMethod(...)`. Instance is created at unit init.
//     Kept intact for backward-compat testing and as a working alternative
//     if you want to skip interface RTTI ceremony.
//
//  2. **TGreeterServiceImpl (M4c IInvokable)** — implements IGreeter,
//     methods return NEW response instances. Used with
//     `THorseGrpc.RegisterService<IGreeter>(...)`.
//     `_AddRef`/`_Release` return -1 per horse-grpc SKILL §2 — prevents
//     ARC from destroying the instance during RTTI dispatch.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Sample.Greeter.Interfaces,
  Sample.Greeter.Messages;

type
  { M4a — procedural handlers (still supported by the registry). }
  TGreeterService = class
  public
    procedure Greet(const AReq: TObject; const AResp: TObject);
    procedure Echo (const AReq: TObject; const AResp: TObject);
  end;

  { M4c — IInvokable service. `TInterfacedObject`'s normal refcount keeps
    the impl alive as long as the registry holds an interface reference
    (via `TGrpcInvokableWrapper.FIntf`). The horse-grpc SKILL §2 pattern
    of `_AddRef`/`_Release` returning -1 is DEFENSIVE — not needed here
    because the registry lifetime is process-scope. Skipping it also
    avoids an FPC-trunk AV in `system.pp` when the interface param enters
    a generic method. }
  TGreeterServiceImpl = class(TInterfacedObject, IGreeter)
  public
    function Greet(const ARequest: TGreetRequest): TGreetResponse;
    function Echo (const ARequest: TEchoRequest):  TEchoResponse;
  end;

var
  GreeterService: TGreeterService;   { M4a global — unchanged for backward compat }

implementation

// ── TGreeterService (M4a procedural) ─────────────────────────────────────

procedure TGreeterService.Greet(const AReq: TObject; const AResp: TObject);
var
  LReq:  TGreetRequest;
  LResp: TGreetResponse;
begin
  LReq  := TGreetRequest(AReq);
  LResp := TGreetResponse(AResp);
  if LReq.name = '' then
    LResp.text := 'Hello, World!'
  else
    LResp.text := 'Hello, ' + LReq.name + '!';
end;

procedure TGreeterService.Echo(const AReq: TObject; const AResp: TObject);
var
  LReq:  TEchoRequest;
  LResp: TEchoResponse;
begin
  LReq  := TEchoRequest(AReq);
  LResp := TEchoResponse(AResp);
  LResp.i32 := LReq.i32;
  LResp.i64 := LReq.i64;
  LResp.b   := LReq.b;
  LResp.s   := LReq.s;
  LResp.f32 := LReq.f32;
  LResp.f64 := LReq.f64;
end;

// ── TGreeterServiceImpl (M4c IInvokable) ─────────────────────────────────

function TGreeterServiceImpl.Greet(const ARequest: TGreetRequest): TGreetResponse;
begin
  Result := TGreetResponse.Create;
  if ARequest.name = '' then
    Result.text := 'Hello, World!'
  else
    Result.text := 'Hello, ' + ARequest.name + '!';
end;

function TGreeterServiceImpl.Echo(const ARequest: TEchoRequest): TEchoResponse;
begin
  Result := TEchoResponse.Create;
  Result.i32 := ARequest.i32;
  Result.i64 := ARequest.i64;
  Result.b   := ARequest.b;
  Result.s   := ARequest.s;
  Result.f32 := ARequest.f32;
  Result.f64 := ARequest.f64;
end;

initialization
  GreeterService := TGreeterService.Create;

finalization
  FreeAndNil(GreeterService);

end.
