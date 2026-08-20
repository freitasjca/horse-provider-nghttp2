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
//   04  ListGreetings server-stream     — N frames on one stream, in order, then grpc-status
//   05  JoinNames client-stream         — N messages in one body, server reassembles
//   06  ChatGreetings bidirectional     — N in / N out, each echoing its own request
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
  Nghttp2.Tls,          { TTlsClientContext — used when target is https:// }
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Sample.Greeter.Messages;

const
  DEFAULT_TARGET_URL = 'http://127.0.0.1:18020';   { port 18020 avoids the 9000-9100 OEM squat range on Windows }

var
  GTargetHost: string = '127.0.0.1';
  GTargetPort: Word   = 18020;
  GUseTls:     Boolean = False;
  GTls:        TTlsClientContext = nil;   { shared across all requests when GUseTls; freed at end }

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

{ Splits a server-streaming body into its constituent gRPC messages.

  GrpcStrip reads only the FIRST frame, which is all a unary response has. A
  streamed body is N frames concatenated, so a test using GrpcStrip on it would
  validate message 1 and silently ignore the rest — passing just as well
  against a server that sent only one. Counting is most of the assertion here,
  which is why this returns the whole set. }
function GrpcSplit(const AData: TBytes; out AMsgs: TArray<TBytes>): Boolean;
var
  LPos:  Integer;
  LLen:  UInt32;
  LBody: TBytes;
  LCount: Integer;
begin
  Result := False;
  SetLength(AMsgs, 0);
  LCount := 0;
  LPos   := 0;

  while LPos + 5 <= Length(AData) do
  begin
    if AData[LPos] <> 0 then Exit;            // compressed — not supported here
    LLen := (UInt32(AData[LPos + 1]) shl 24) or
            (UInt32(AData[LPos + 2]) shl 16) or
            (UInt32(AData[LPos + 3]) shl 8)  or
             UInt32(AData[LPos + 4]);
    if LPos + 5 + Integer(LLen) > Length(AData) then Exit;   // truncated frame

    SetLength(LBody, LLen);
    if LLen > 0 then
      Move(AData[LPos + 5], LBody[0], LLen);

    Inc(LCount);
    SetLength(AMsgs, LCount);
    AMsgs[LCount - 1] := LBody;

    Inc(LPos, 5 + Integer(LLen));
  end;

  { Trailing bytes that do not form a complete frame mean the body is
    malformed, not merely short — report it rather than returning a partial
    set that looks like a clean parse. }
  Result := LPos = Length(AData);
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

{ Builds a request body of N concatenated gRPC messages — the wire shape of a
  client-streaming call.

  TNghttp2Client sends one body per request, so this cannot pace the messages
  the way a real streaming client would. What it DOES exercise is the server
  reader's reassembly: several messages land in one DATA burst, which is
  exactly the case a decoder that assumes one message per frame gets wrong.
  Incremental arrival is grpcurl's job — see doc/grpc.md. }
function GrpcWrapMany(const AReqs: array of TObject): TBytes;
var
  I:      Integer;
  LOne:   TBytes;
  LTotal: Integer;
begin
  SetLength(Result, 0);
  LTotal := 0;
  for I := 0 to High(AReqs) do
  begin
    LOne := GrpcWrap(TProtoSerializer.Serialize(AReqs[I]));
    SetLength(Result, LTotal + Length(LOne));
    Move(LOne[0], Result[LTotal], Length(LOne));
    Inc(LTotal, Length(LOne));
  end;
end;

function GrpcSubmitRaw(
  const AClient: TNghttp2Client;
  const APath:   string;
  const ABody:   TBytes): TNghttp2Response;
var
  LHeaders: TNghttp2Headers;
begin
  SetLength(LHeaders, 3);
  LHeaders[0].Name  := 'content-type';
  LHeaders[0].Value := 'application/grpc+proto';
  LHeaders[1].Name  := 'te';
  LHeaders[1].Value := 'trailers';
  LHeaders[2].Name  := 'grpc-encoding';
  LHeaders[2].Value := 'identity';
  Result := AClient.SubmitRequest('POST', APath, LHeaders, ABody);
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

// Factory — build a client with TLS applied if the target URL is https://.
// Shared context (GTls) is safe: TTlsClientContext is designed for pool-style
// reuse across multiple TNghttp2Client instances. Non-owning assignment.
function NewClient: TNghttp2Client;
begin
  Result := TNghttp2Client.Create;
  if GUseTls and (GTls <> nil) then
    Result.TlsContext := GTls;
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

{ M6a — server-streaming.

  Three things are asserted that a unary test cannot reach: that MANY frames
  arrive on one stream, that they arrive in order, and that grpc-status still
  lands in the trailer after the last of them. The status check is the one
  most easily forgotten — a streaming client that stops reading when messages
  stop will never see it, and a failed stream is indistinguishable from a
  short one without it. }
procedure TestServerStream(const AClient: TNghttp2Client);
var
  LReq:   TGreetRequest;
  LResp:  TGreetResponse;
  LRs:    TNghttp2Response;
  LMsgs:  TArray<TBytes>;
  LStat:  string;
  I:      Integer;
  LOk:    Boolean;
  LTexts: TArray<string>;
begin
  WriteLn;
  WriteLn('── 04  ListGreetings  (server-streaming, 5 messages)');
  LReq := TGreetRequest.Create;
  try
    LReq.name := 'World';
    LRs := GrpcSubmit(AClient, '/greeter.Greeter/ListGreetings', LReq);
  finally
    LReq.Free;
  end;

  Check(LRs.Status = 200,
        Format('HTTP :status = 200 (got %d)', [LRs.Status]));
  Check(SameText(FindHeader(LRs, 'content-type'), 'application/grpc'),
        'content-type = application/grpc');

  Check(GrpcSplit(LRs.Body, LMsgs),
        'response body is a clean sequence of 5-byte-prefixed frames');
  Check(Length(LMsgs) = 5,
        Format('5 streamed messages (got %d)', [Length(LMsgs)]));

  SetLength(LTexts, Length(LMsgs));
  LOk := True;
  for I := 0 to High(LMsgs) do
  begin
    LResp := TGreetResponse.Create;
    try
      try
        TProtoSerializer.Deserialize(LMsgs[I], LResp);
        LTexts[I] := LResp.text;
      except
        LOk := False;
      end;
    finally
      LResp.Free;
    end;
  end;
  Check(LOk, 'every streamed message decodes as TGreetResponse');

  if Length(LTexts) = 5 then
  begin
    Check(Pos('World', LTexts[0]) > 0,
          Format('message 1 carries the request name (got "%s")', [LTexts[0]]));
    { Ordering matters: the writer appends into a buffer the data provider
      drains on another thread, so a locking mistake shows up here as
      out-of-order or interleaved messages rather than as a crash. }
    LOk := True;
    for I := 0 to 4 do
      LOk := LOk and (Pos(Format('(%d of 5)', [I + 1]), LTexts[I]) > 0);
    Check(LOk, 'messages arrive in order 1..5');
  end;

  LStat := FindHeader(LRs, 'grpc-status');
  Check(LStat = '0',
        Format('grpc-status trailer = 0 AFTER the last message (got "%s")', [LStat]));
end;


{ M6b — client-streaming. Three names in, one joined greeting out.

  The reassembly assertion is the point: all three messages arrive in a single
  DATA burst, so a reader that decoded per frame would see one message and
  report a count of 1. Checking the echoed count catches that directly. }
procedure TestClientStream(const AClient: TNghttp2Client);
var
  LReqs:  array[0..2] of TObject;
  LRs:    TNghttp2Response;
  LProto: TBytes;
  LResp:  TGreetResponse;
  LStat:  string;
  I:      Integer;
begin
  WriteLn;
  WriteLn('── 05  JoinNames  (client-streaming, 3 messages in)');

  for I := 0 to 2 do
  begin
    LReqs[I] := TGreetRequest.Create;
    TGreetRequest(LReqs[I]).name := Format('Name%d', [I + 1]);
  end;
  try
    LRs := GrpcSubmitRaw(AClient, '/greeter.Greeter/JoinNames',
                         GrpcWrapMany(LReqs));
  finally
    for I := 0 to 2 do LReqs[I].Free;
  end;

  Check(LRs.Status = 200, Format('HTTP :status = 200 (got %d)', [LRs.Status]));
  LStat := FindHeader(LRs, 'grpc-status');
  Check(LStat = '0', Format('grpc-status trailer = 0 (got "%s")', [LStat]));

  Check(GrpcStrip(LRs.Body, LProto), 'single response frame');
  if Length(LProto) > 0 then
  begin
    LResp := TGreetResponse.Create;
    try
      TProtoSerializer.Deserialize(LProto, LResp);
      Check(Pos('Name1', LResp.text) > 0, 'first name present');
      Check(Pos('Name3', LResp.text) > 0, 'last name present');
      Check(Pos('(3 received)', LResp.text) > 0,
        Format('server read all 3 messages — reassembly (got "%s")', [LResp.text]));
    finally
      LResp.Free;
    end;
  end
  else
    Check(False, 'response has non-empty payload');
end;

{ M6b — bidirectional. N in, N out on one stream. }
procedure TestBidiStream(const AClient: TNghttp2Client);
var
  LReqs:  array[0..2] of TObject;
  LRs:    TNghttp2Response;
  LMsgs:  TArray<TBytes>;
  LResp:  TGreetResponse;
  LStat:  string;
  I:      Integer;
  LOk:    Boolean;
begin
  WriteLn;
  WriteLn('── 06  ChatGreetings  (bidirectional, 3 in / 3 out)');

  for I := 0 to 2 do
  begin
    LReqs[I] := TGreetRequest.Create;
    TGreetRequest(LReqs[I]).name := Format('Peer%d', [I + 1]);
  end;
  try
    LRs := GrpcSubmitRaw(AClient, '/greeter.Greeter/ChatGreetings',
                         GrpcWrapMany(LReqs));
  finally
    for I := 0 to 2 do LReqs[I].Free;
  end;

  Check(LRs.Status = 200, Format('HTTP :status = 200 (got %d)', [LRs.Status]));
  Check(GrpcSplit(LRs.Body, LMsgs), 'response is a clean frame sequence');
  Check(Length(LMsgs) = 3,
    Format('one response per request — 3 (got %d)', [Length(LMsgs)]));

  LOk := Length(LMsgs) = 3;
  if LOk then
    for I := 0 to High(LMsgs) do
    begin
      LResp := TGreetResponse.Create;
      try
        TProtoSerializer.Deserialize(LMsgs[I], LResp);
        LOk := LOk and (Pos(Format('Peer%d', [I + 1]), LResp.text) > 0);
      finally
        LResp.Free;
      end;
    end;
  Check(LOk, 'each response echoes its own request, in order');

  LStat := FindHeader(LRs, 'grpc-status');
  Check(LStat = '0', Format('grpc-status trailer = 0 (got "%s")', [LStat]));
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

// ── URL parser (mirrors HorseNghttp2TestClient.ParseTargetURL) ──────────

procedure ParseTargetURL(const AURL: string; out AScheme, AHost: string; out APort: Word);
var
  LRest: string;
  LColonPos, LSlashPos, LSchemePos: Integer;
begin
  LSchemePos := Pos('://', AURL);
  if LSchemePos = 0 then
    raise Exception.CreateFmt(
      'malformed target URL "%s" — expected http://host[:port] or https://host[:port]', [AURL]);
  AScheme := LowerCase(Copy(AURL, 1, LSchemePos - 1));
  if (AScheme <> 'http') and (AScheme <> 'https') then
    raise Exception.CreateFmt(
      'unsupported scheme "%s" — only http and https are supported', [AScheme]);

  LRest := Copy(AURL, LSchemePos + 3, MaxInt);
  LSlashPos := Pos('/', LRest);
  if LSlashPos > 0 then
    SetLength(LRest, LSlashPos - 1);

  LColonPos := Pos(':', LRest);
  if LColonPos > 0 then
  begin
    AHost := Copy(LRest, 1, LColonPos - 1);
    APort := StrToIntDef(Copy(LRest, LColonPos + 1, MaxInt), 0);
    if APort = 0 then
      raise Exception.CreateFmt('malformed port in target URL "%s"', [AURL]);
  end
  else
  begin
    AHost := LRest;
    if AScheme = 'https' then APort := 443 else APort := 80;
  end;
end;

// ── Main ─────────────────────────────────────────────────────────────────

var
  LTargetURL:  string;
  LScheme:     string;
  LClientCert: string;
  LClientKey:  string;
  LArgIdx:     Integer;
  LClient:     TNghttp2Client;

begin
  try
    { CLI:
        HorseNghttp2GrpcTestClient.exe                                    — h2c local (127.0.0.1:18020)
        HorseNghttp2GrpcTestClient.exe http://172.18.64.1:18020           — h2c cross-machine
        HorseNghttp2GrpcTestClient.exe https://127.0.0.1:18443            — h2 over TLS
        HorseNghttp2GrpcTestClient.exe https://127.0.0.1:18443            \
            --client-cert tls/client-cert.pem --client-key tls/client-key.pem
                                                                          — mTLS (server needs `mtls` mode) }
    LTargetURL  := DEFAULT_TARGET_URL;
    LClientCert := '';
    LClientKey  := '';

    LArgIdx := 1;
    while LArgIdx <= ParamCount do
    begin
      if SameText(ParamStr(LArgIdx), '--client-cert') and (LArgIdx < ParamCount) then
      begin
        LClientCert := ParamStr(LArgIdx + 1);
        Inc(LArgIdx, 2);
      end
      else if SameText(ParamStr(LArgIdx), '--client-key') and (LArgIdx < ParamCount) then
      begin
        LClientKey := ParamStr(LArgIdx + 1);
        Inc(LArgIdx, 2);
      end
      else
      begin
        LTargetURL := ParamStr(LArgIdx);
        Inc(LArgIdx);
      end;
    end;

    ParseTargetURL(LTargetURL, LScheme, GTargetHost, GTargetPort);
    GUseTls := (LScheme = 'https');

    // Shared TLS context (insecure = skip cert verification, self-signed OK).
    // ALPN enabled so nghttp2 negotiates 'h2' during the handshake.
    if GUseTls then
    begin
      GTls := TTlsClientContext.Create;
      GTls.SetInsecure;
      GTls.EnableHttp2Alpn;
      if (LClientCert <> '') and (LClientKey <> '') then
        GTls.SetClientCertificate(LClientCert, LClientKey);
    end;

    WriteLn('HorseNghttp2GrpcTestClient — target ', LTargetURL);
    if GUseTls then
    begin
      if LClientCert <> '' then
        WriteLn('  mode: HTTPS + mTLS (h2 over TLS, ALPN, client cert = ', LClientCert, ')')
      else
        WriteLn('  mode: HTTPS (h2 over TLS, ALPN, insecure cert verification)');
    end
    else
      WriteLn('  mode: HTTP (h2c prior knowledge)');
    WriteLn('Prereq: HorseNghttp2GrpcDemo.exe must be running at that endpoint.');

    LClient := NewClient;
    try
      LClient.Connect(GTargetHost, GTargetPort);
      TestGreet(LClient);
      TestEcho(LClient);
      TestUnimplemented(LClient);
      TestServerStream(LClient);   { M6a }
      TestClientStream(LClient);   { M6b }
      TestBidiStream(LClient);     { M6b }
    finally
      LClient.Free;
      if GTls <> nil then
        FreeAndNil(GTls);
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
