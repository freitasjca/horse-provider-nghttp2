program HorseNghttp2GrpcTestClient;

// =============================================================================
//  HorseNghttp2GrpcTestClient — Delphi-native gRPC round-trip validator (M4b).
//
//  Speaks h2c cleartext HTTP/2 via Nghttp2.Client and dogfoods the same
//  protobuf codec used by the server (Nghttp2.Protobuf.Rtti), so a green
//  run proves BOTH sides encode+decode identically for every scalar type.
//
//  Covers:
//   01  Greet happy path                — protobuf → gRPC frame → wire → 5B strip → decode
//   02  Echo all scalar types           — i32 / i64 / bool / string / f32 / f64 round-trip
//   03  Unregistered method             — expects grpc-status 12 UNIMPLEMENTED trailer
//
//  Trailer verification: nghttp2 delivers trailer HEADERS through the same
//  on-header callback as initial headers, so TNghttp2Response.Headers ends
//  up containing BOTH sets. FindHeader('grpc-status', ...) works on both.
//
//  Prereqs — the demo server must be running: HorseNghttp2GrpcDemo.exe
// =============================================================================

{$APPTYPE CONSOLE}

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, Math,
{$ELSE}
  System.SysUtils, System.Classes, System.Math,
{$IFEND}
  Nghttp2.Client,
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Sample.Greeter.Messages;

const
  HOST = '127.0.0.1';
  PORT = 18020;   { avoid the 9000-9100 OEM squat range on Windows — see demo .dpr header }

var
  GTotal:  Integer = 0;
  GPassed: Integer = 0;
  GFailed: Integer = 0;

// ── Helpers ──────────────────────────────────────────────────────────────

procedure Check(ACondition: Boolean; const ADesc: string);
begin
  Inc(GTotal);
  if ACondition then
  begin
    Inc(GPassed);
    WriteLn('  PASS  ', ADesc);
  end
  else
  begin
    Inc(GFailed);
    WriteLn('  FAIL  ', ADesc);
  end;
end;

function FindHeader(const AResp: TNghttp2Response; const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AResp.Headers) do
    if SameText(AResp.Headers[I].Name, AName) then
      Exit(AResp.Headers[I].Value);
end;

function GrpcWrap(const AProto: TBytes): TBytes;
var
  LLen: UInt32;
begin
  LLen := UInt32(Length(AProto));
  SetLength(Result, 5 + Integer(LLen));
  Result[0] := 0;                             // compressed = 0
  Result[1] := Byte((LLen shr 24) and $FF);   // big-endian length
  Result[2] := Byte((LLen shr 16) and $FF);
  Result[3] := Byte((LLen shr 8)  and $FF);
  Result[4] := Byte( LLen         and $FF);
  if LLen > 0 then
    Move(AProto[0], Result[5], LLen);
end;

function GrpcStrip(const AData: TBytes; out AProto: TBytes): Boolean;
var
  LLen: UInt32;
begin
  Result := False;
  SetLength(AProto, 0);
  if Length(AData) < 5 then Exit;
  if AData[0] <> 0 then Exit;                 // compressed payload — not supported here
  LLen := (UInt32(AData[1]) shl 24) or
          (UInt32(AData[2]) shl 16) or
          (UInt32(AData[3]) shl 8)  or
           UInt32(AData[4]);
  if Length(AData) < 5 + Integer(LLen) then Exit;
  SetLength(AProto, LLen);
  if LLen > 0 then
    Move(AData[5], AProto[0], LLen);
  Result := True;
end;

function GrpcSubmit(
  const AClient: TNghttp2Client;
  const APath:   string;
  const AReq:    TObject): TNghttp2Response;
var
  LProto:   TBytes;
  LFramed:  TBytes;
  LHeaders: TNghttp2Headers;
begin
  LProto  := TProtoSerializer.Serialize(AReq);
  LFramed := GrpcWrap(LProto);

  SetLength(LHeaders, 3);
  LHeaders[0].Name  := 'content-type';
  LHeaders[0].Value := 'application/grpc+proto';
  LHeaders[1].Name  := 'te';
  LHeaders[1].Value := 'trailers';
  LHeaders[2].Name  := 'grpc-encoding';
  LHeaders[2].Value := 'identity';

  Result := AClient.SubmitRequest('POST', APath, LHeaders, LFramed);
end;

// ── Test cases ───────────────────────────────────────────────────────────

procedure TestGreet(const AClient: TNghttp2Client);
var
  LReq:   TGreetRequest;
  LResp:  TGreetResponse;
  LRs:    TNghttp2Response;
  LProto: TBytes;
  LStat:  string;
begin
  WriteLn;
  WriteLn('── 01  Greet  (happy path)');
  LReq := TGreetRequest.Create;
  try
    LReq.name := 'World';
    LRs := GrpcSubmit(AClient, '/greeter.Greeter/Greet', LReq);
  finally
    LReq.Free;
  end;

  Check(LRs.Status = 200,
        Format('HTTP :status = 200 (got %d)', [LRs.Status]));
  Check(SameText(FindHeader(LRs, 'content-type'), 'application/grpc'),
        'content-type = application/grpc');
  LStat := FindHeader(LRs, 'grpc-status');
  Check(LStat = '0',
        Format('grpc-status trailer = 0 (got "%s")', [LStat]));

  Check(GrpcStrip(LRs.Body, LProto), 'response body has valid 5-byte gRPC frame');
  if Length(LProto) > 0 then
  begin
    LResp := TGreetResponse.Create;
    try
      TProtoSerializer.Deserialize(LProto, LResp);
      Check(Pos('World', LResp.text) > 0,
            Format('response.text contains "World" (got "%s")', [LResp.text]));
    finally
      LResp.Free;
    end;
  end
  else
    Check(False, 'response body has non-empty proto payload');
end;

procedure TestEcho(const AClient: TNghttp2Client);
const
  EXPECT_I32: Integer = 42;
  EXPECT_I64: Int64   = 9876543210;
  EXPECT_S:   string  = 'quick brown fox';
var
  LReq:   TEchoRequest;
  LResp:  TEchoResponse;
  LRs:    TNghttp2Response;
  LProto: TBytes;
begin
  WriteLn;
  WriteLn('── 02  Echo  (all scalar types round-trip)');
  LReq := TEchoRequest.Create;
  try
    LReq.i32 := EXPECT_I32;
    LReq.i64 := EXPECT_I64;
    LReq.b   := True;
    LReq.s   := EXPECT_S;
    LReq.f32 := 3.14;
    LReq.f64 := 2.7182818284;
    LRs := GrpcSubmit(AClient, '/greeter.Greeter/Echo', LReq);
  finally
    LReq.Free;
  end;

  Check(LRs.Status = 200, 'HTTP :status = 200');
  Check(FindHeader(LRs, 'grpc-status') = '0', 'grpc-status trailer = 0');
  Check(GrpcStrip(LRs.Body, LProto), 'body has valid 5-byte gRPC frame');
  if Length(LProto) = 0 then
  begin
    Check(False, 'echo response body is non-empty');
    Exit;
  end;

  LResp := TEchoResponse.Create;
  try
    TProtoSerializer.Deserialize(LProto, LResp);
    Check(LResp.i32 = EXPECT_I32,               Format('i32 = %d', [LResp.i32]));
    Check(LResp.i64 = EXPECT_I64,               Format('i64 = %d', [LResp.i64]));
    Check(LResp.b = True,                       'b = True');
    Check(LResp.s = EXPECT_S,                   Format('s = "%s"', [LResp.s]));
    Check(Abs(LResp.f32 - 3.14) < 0.0001,       Format('f32 ≈ 3.14 (got %.6f)', [LResp.f32]));
    Check(Abs(LResp.f64 - 2.7182818284) < 1e-9, Format('f64 ≈ 2.71828... (got %.10f)', [LResp.f64]));
  finally
    LResp.Free;
  end;
end;

procedure TestUnimplemented(const AClient: TNghttp2Client);
var
  LReq:  TGreetRequest;
  LRs:   TNghttp2Response;
  LStat: string;
begin
  WriteLn;
  WriteLn('── 03  Unregistered method  (expect grpc-status 12 UNIMPLEMENTED)');
  LReq := TGreetRequest.Create;
  try
    LReq.name := 'ignored';
    LRs := GrpcSubmit(AClient, '/greeter.Greeter/DoesNotExist', LReq);
  finally
    LReq.Free;
  end;

  Check(LRs.Status = 200, 'HTTP :status = 200 (gRPC always transports as 200)');
  LStat := FindHeader(LRs, 'grpc-status');
  Check(LStat = '12',
        Format('grpc-status trailer = 12 (got "%s")', [LStat]));
end;

// ── Main ─────────────────────────────────────────────────────────────────

var
  LClient: TNghttp2Client;

begin
  try
    WriteLn('HorseNghttp2GrpcTestClient — target http://', HOST, ':', PORT);
    WriteLn('Prereq: HorseNghttp2GrpcDemo.exe must be running.');

    LClient := TNghttp2Client.Create;
    try
      LClient.Connect(HOST, PORT);
      TestGreet(LClient);
      TestEcho(LClient);
      TestUnimplemented(LClient);
    finally
      LClient.Free;
    end;

    WriteLn;
    WriteLn(Format('%d passed, %d failed  (total %d)', [GPassed, GFailed, GTotal]));
    if GFailed > 0 then
    begin
      WriteLn('FAILURES present.');
      ExitCode := 1;
    end
    else
      WriteLn('All tests PASSED.');
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput);
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  WriteLn;
  WriteLn('Press ENTER to exit...');
  ReadLn;
end.
