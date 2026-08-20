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
  Sample.Greeter.Messages,
  Horse.Provider.Nghttp2.Grpc.Registry;   { IGrpcStreamWriter — M6a }

type
  { M4a — procedural handlers (still supported by the registry). }
  TGreeterService = class
  public
    procedure Greet(const AReq: TObject; const AResp: TObject);
    procedure Echo (const AReq: TObject; const AResp: TObject);

    { M6a — server-streaming. One request in, N responses out.

      Note what the signature does NOT have: a response object. The handler
      decides how many messages there are, so it is handed a writer instead.
      Each Send takes ownership of the object passed to it — allocate inside
      the loop and do not free. }
    procedure ListGreetings(const AReq: TObject; const AWriter: IGrpcStreamWriter);

    { M6b — client-streaming. Many requests in, ONE response out. AResponse is
      dispatcher-owned, exactly as in the unary procedural path. }
    procedure JoinNames(const AReader: IGrpcStreamReader; const AResponse: TObject);

    { M6b — bidirectional. Reads and writes concurrently on one stream; here
      it echoes each request back as it arrives. }
    procedure ChatGreetings(const AReader: IGrpcStreamReader;
      const AWriter: IGrpcStreamWriter);
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

// M6a — server-streaming implementation lives at the end of this section.

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

{ M6a — server-streaming. Emits five greetings for the one name supplied.

  IsConnected is checked before each Send rather than once up front: on
  HTTP/2 a departed peer arrives as RST_STREAM or GOAWAY, not as a write
  error, so a producing loop that ignores it runs to completion with nowhere
  to send. Sleep(40) paces the messages so `grpcurl` and the native client
  can be seen receiving them separately rather than as one buffered block —
  the only thing that distinguishes a stream from a slow single response. }
procedure TGreeterService.ListGreetings(const AReq: TObject;
  const AWriter: IGrpcStreamWriter);
var
  LReq:  TGreetRequest;
  LResp: TGreetResponse;
  I:     Integer;
begin
  LReq := TGreetRequest(AReq);
  for I := 1 to 5 do
  begin
    if not AWriter.IsConnected then Break;

    LResp := TGreetResponse.Create;
    LResp.text := Format('Hello, %s! (%d of 5)', [LReq.name, I]);
    AWriter.Send(LResp);   { takes ownership — do not free }

    Sleep(40);
  end;
end;

{ M6b — client-streaming. Drains every request message, then answers once.

  The loop shape is the contract: Next blocks until a message arrives and
  returns False only when the peer half-closes, so `while Next do` is the
  whole protocol. LReq is reader-owned and valid only until the next call —
  hence copying the name out rather than retaining the object. }
procedure TGreeterService.JoinNames(const AReader: IGrpcStreamReader;
  const AResponse: TObject);
var
  LMsg:   TObject;
  LReq:   TGreetRequest;
  LResp:  TGreetResponse;
  LNames: string;
begin
  LResp  := TGreetResponse(AResponse);
  LNames := '';

  while AReader.Next(LMsg) do
  begin
    LReq := TGreetRequest(LMsg);
    if LNames <> '' then
      LNames := LNames + ', ';
    LNames := LNames + LReq.name;
  end;

  LResp.text := Format('Hello, %s! (%d received)', [LNames, AReader.Count]);
end;

{ M6b — bidirectional. One response per request, emitted as each arrives
  rather than after the loop, which is what makes it bidirectional rather than
  client-streaming with a batched reply. }
procedure TGreeterService.ChatGreetings(const AReader: IGrpcStreamReader;
  const AWriter: IGrpcStreamWriter);
var
  LMsg:  TObject;
  LReq:  TGreetRequest;
  LResp: TGreetResponse;
begin
  while AReader.Next(LMsg) do
  begin
    if not AWriter.IsConnected then Break;

    LReq  := TGreetRequest(LMsg);
    LResp := TGreetResponse.Create;

    { The server's own clock, read the moment this message came out of the
      reader, and carried in the reply.

      Client-side timing cannot answer whether the handler consumed messages
      as they arrived: a shell that collects the whole output before printing
      stamps every line at drain time, which looks identical to a server that
      buffered the request. Stamping here removes the client from the
      question entirely — three replies whose SERVER timestamps are spread
      across the send interval can only have been produced incrementally. }
    LResp.text := Format('Hi %s (#%d) @ %s',
      [LReq.name, AReader.Count, FormatDateTime('hh:nn:ss.zzz', Now)]);

    AWriter.Send(LResp);   { takes ownership }
  end;
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
