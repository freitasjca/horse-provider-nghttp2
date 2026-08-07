unit Sample.Greeter.Service;

// ============================================================================
//  Sample.Greeter.Service — gRPC handler implementations for the M4b demo.
//
//  Handlers use the M4a procedural registry API (THorseGrpc.RegisterMethod
//  with `procedure(const AReq, AResp: TObject) of object`). A single
//  TGreeterService instance is created at unit initialisation and its
//  instance methods are handed to the registry — no ARC concerns because
//  the class is a plain TObject, not TInterfacedObject.
//
//  Interface-driven IInvokable dispatch (horse-grpc SKILL §2) is M4c.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Sample.Greeter.Messages;

type
  TGreeterService = class
  public
    procedure Greet(const AReq: TObject; const AResp: TObject);
    procedure Echo (const AReq: TObject; const AResp: TObject);
  end;

var
  GreeterService: TGreeterService;

implementation

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

initialization
  GreeterService := TGreeterService.Create;

finalization
  FreeAndNil(GreeterService);

end.
