program HorseNghttp2TestServer;

// =============================================================================
//  Smoke-test server for horse-provider-nghttp2 (h2c cleartext HTTP/2).
//
//  Route set matches HorseICSTestClient.exe's expectations (96 checks across
//  36 numbered tests) so the same client binary can validate parity between
//  the ICS and nghttp2 providers.
//
//  Build (Windows, Delphi):
//    boss install
//    dcc32 -CC -B HorseNghttp2TestServer.dpr
//    (or open the .dproj in Delphi IDE and press F9)
//
//  Prerequisites:
//    - libnghttp2 v1.40+ (nghttp2.dll / libnghttp2.so.14 / libnghttp2.dylib)
//    - HashLoad/horse >= 3.3.0 with NGHTTP2 hooks applied to Horse.pas
//      (see patches/horse/src/HOOKS-FOR-NGHTTP2.md)
//
//  Run:
//    ./HorseNghttp2TestServer               (starts on 9010, blocks)
//
//  Test:
//    HorseICSTestClient.exe                 (full 96-check suite)
//    ./run-smoke-tests.sh                   (bash+curl subset)
// =============================================================================

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

uses
  {$IF DEFINED(FPC)}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  {$IFEND }
  Horse,
  Horse.Commons,
  Horse.Exception,
  Horse.Exception.Interrupted,
  Horse.Provider.Nghttp2,
  Horse.Provider.Config,
  Nghttp2.Native in '..\..\..\Delphi-nghttp2\src\Nghttp2.Native.pas',
  Nghttp2.OpenSSL in '..\..\..\Delphi-nghttp2\src\Nghttp2.OpenSSL.pas',
  Nghttp2.Server in '..\..\..\Delphi-nghttp2\src\Nghttp2.Server.pas',
  Nghttp2.Session in '..\..\..\Delphi-nghttp2\src\Nghttp2.Session.pas',
  Nghttp2.Socket in '..\..\..\Delphi-nghttp2\src\Nghttp2.Socket.pas',
  Nghttp2.Tls in '..\..\..\Delphi-nghttp2\src\Nghttp2.Tls.pas',
  Nghttp2.Types in '..\..\..\Delphi-nghttp2\src\Nghttp2.Types.pas',
  Nghttp2.Protobuf.Rtti in '..\..\..\Delphi-nghttp2\src\Nghttp2.Protobuf.Rtti.pas',
  Nghttp2.Protobuf in '..\..\..\Delphi-nghttp2\src\Nghttp2.Protobuf.pas';

{ for THorseCrossSocketConfig with SSL* fields (TLS mode) }

const
  TEST_PORT_H2C = 9010;    // cleartext HTTP/2 (h2c prior knowledge)
  TEST_PORT_H2  = 9443;    // HTTP/2 over TLS (h2 with ALPN)
  CERT_REL_PATH = 'tls' + PathDelim + 'cert.pem';
  KEY_REL_PATH  = 'tls' + PathDelim + 'key.pem';
  CA_REL_PATH   = 'tls' + PathDelim + 'ca.pem';      // mTLS mode only

// ─── Helpers ───────────────────────────────────────────────────────────────

function JsonEsc(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

// ─── Basic ping ────────────────────────────────────────────────────────────

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

// ─── Methods (GET/POST/PUT/DELETE/PATCH/HEAD) ──────────────────────────────

procedure MethodsGet(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"method":"GET"}');
end;

procedure MethodsPost(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"method":"POST","body":"' + JsonEsc(Req.Body) + '"}');
end;

procedure MethodsPutId(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"method":"PUT","id":"' + JsonEsc(Req.Params['id']) + '"}');
end;

procedure MethodsDeleteId(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"method":"DELETE","id":"' + JsonEsc(Req.Params['id']) + '"}');
end;

procedure MethodsPatchId(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"method":"PATCH","id":"' + JsonEsc(Req.Params['id']) + '"}');
end;

procedure MethodsHead(Req: THorseRequest; Res: THorseResponse);
begin
  Res.AddHeader('X-Head-Ok', 'true');
  Res.Send('');
end;

// ─── Params (path / query / multi) ─────────────────────────────────────────

procedure ParamsPathId(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"id":"' + JsonEsc(Req.Params['id']) + '"}');
end;

procedure ParamsQuery(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"name":"' + JsonEsc(Req.Query['name']) + '","value":"' +
           JsonEsc(Req.Query['value']) + '"}');
end;

procedure ParamsMulti(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"a":"' + JsonEsc(Req.Params['a']) + '","b":"' +
           JsonEsc(Req.Params['b']) + '"}');
end;

// ─── Cookies ───────────────────────────────────────────────────────────────

procedure CookiesSet(Req: THorseRequest; Res: THorseResponse);
begin
  // Two Set-Cookie headers — FIX-HEADER-DUP: multi-value header semantics.
  // Our response bridge's idempotent SetHeader on the stream would overwrite,
  // so we use AddHeader which stores in CustomHeaders as separate entries.
  Res.AddHeader('Set-Cookie', 'session=abc123; Path=/; HttpOnly');
  Res.AddHeader('Set-Cookie', 'user=tester; Path=/');
  Res.Send('cookies-set');
end;

procedure CookiesEcho(Req: THorseRequest; Res: THorseResponse);
var
  LCookieHeader: string;
  LParts: TArray<string>;
  LPart, LKey, LVal: string;
  LEqPos: Integer;
  LSB: TStringBuilder;
  LFirst: Boolean;
begin
  // Parse the Cookie header into individual JSON fields — the test expects
  // {"session":"abc123","user":"tester"}, not {"cookies":"session=abc123; ..."}
  LCookieHeader := Req.Headers['cookie'];
  LSB := TStringBuilder.Create;
  try
    LSB.Append('{');
    LFirst := True;
    LParts := LCookieHeader.Split([';']);
    for LPart in LParts do
    begin
      LEqPos := Pos('=', LPart);
      if LEqPos > 0 then
      begin
        LKey := Trim(Copy(LPart, 1, LEqPos - 1));
        LVal := Trim(Copy(LPart, LEqPos + 1, MaxInt));
        if LKey = '' then Continue;
        if not LFirst then LSB.Append(',');
        LSB.Append('"').Append(JsonEsc(LKey)).Append('":"').Append(JsonEsc(LVal)).Append('"');
        LFirst := False;
      end;
    end;
    LSB.Append('}');
    Res.ContentType('application/json; charset=utf-8').Send(LSB.ToString);
  finally
    LSB.Free;
  end;
end;

// ─── Upload / Download ─────────────────────────────────────────────────────

procedure Upload(Req: THorseRequest; Res: THorseResponse);
var
  LFilename: string;
  LBody: string;
  LStart: Integer;
begin
  // Multipart parsing isn't native to Horse+nghttp2. Best-effort: extract the
  // first filename="..." substring from the body if present, otherwise report
  // a placeholder. Test accepts 200 OR 400 for this endpoint but checks for
  // filename echo in the response body.
  LBody := Req.Body;
  LFilename := 'unknown';
  LStart := Pos('filename="', LBody);
  if LStart > 0 then
  begin
    Inc(LStart, Length('filename="'));
    LFilename := Copy(LBody, LStart, MaxInt);
    LFilename := Copy(LFilename, 1, Pos('"', LFilename) - 1);
  end;

  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"filename":"%s","size":%d}', [JsonEsc(LFilename), Length(LBody)]));
end;

procedure Download(Req: THorseRequest; Res: THorseResponse);
begin
  Res.AddHeader('Content-Disposition', 'attachment; filename="horse.txt"');
  Res.ContentType('text/plain; charset=utf-8')
     .Send('Horse — the fastest Delphi web framework');
end;

// ─── Headers echo ──────────────────────────────────────────────────────────

procedure HeadersEcho(Req: THorseRequest; Res: THorseResponse);
var
  LValue: string;
begin
  // Test checks both the response header AND the body for the round-tripped
  // value — echo in both.
  LValue := Req.Headers['X-Test-Header'];
  Res.AddHeader('X-Test-Header', LValue);
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"X-Test-Header":"%s"}', [JsonEsc(LValue)]));
end;

// ─── Body echo (size + verbatim) ───────────────────────────────────────────

procedure EchoBody(Req: THorseRequest; Res: THorseResponse);
var
  LBody: string;
begin
  LBody := Req.Body;
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"size":%d,"body":"%s"}', [Length(LBody), JsonEsc(LBody)]));
end;

procedure EchoBodyTwice(Req: THorseRequest; Res: THorseResponse);
var
  LFirst, LSecond: string;
begin
  LFirst  := Req.Body;
  LSecond := Req.Body;
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"first":"%s","second":"%s","equal":%s}',
       [JsonEsc(LFirst), JsonEsc(LSecond),
        BoolToStr(LFirst = LSecond, True).ToLower]));
end;

// ─── Status codes ──────────────────────────────────────────────────────────

procedure Status400(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Status(400)
     .ContentType('application/json; charset=utf-8')
     .Send('{"status":400}');
end;

procedure Status500(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Status(500)
     .ContentType('application/json; charset=utf-8')
     .Send('{"status":500}');
end;

// ─── Large response (65536 bytes of 'X') ───────────────────────────────────

procedure ResponseLarge(Req: THorseRequest; Res: THorseResponse);
var
  LBuf: string;
begin
  LBuf := StringOfChar('X', 65536);
  Res.ContentType('text/plain; charset=utf-8').Send(LBuf);
end;

// ─── RawWebRequest / RawWebResponse (adapter surfaces) ─────────────────────

procedure RawWebRequestRoute(Req: THorseRequest; Res: THorseResponse);
var
  LHasAdapter: Boolean;
  LMethod, LHost, LPath, LCustom, LRemote: string;
begin
  // Assigned() requires an lvalue; property getters return an rvalue.
  // Use <> nil for property-based nil checks throughout.
  LHasAdapter := Req.RawWebRequest <> nil;
  if LHasAdapter then
  begin
    LMethod := Req.RawWebRequest.Method;
    LHost   := Req.RawWebRequest.Host;
    LPath   := Req.RawWebRequest.PathInfo;
    LCustom := Req.RawWebRequest.GetFieldByName('X-Custom-Test');
    LRemote := Req.RawWebRequest.RemoteAddr;
  end;
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format(
       '{"hasAdapter":%s,"method":"%s","host":"%s","pathInfo":"%s","customHeader":"%s","remoteAddr":"%s"}',
       [BoolToStr(LHasAdapter, True).ToLower,
        JsonEsc(LMethod), JsonEsc(LHost), JsonEsc(LPath),
        JsonEsc(LCustom), JsonEsc(LRemote)]));
end;

procedure RawWebResponseRoute(Req: THorseRequest; Res: THorseResponse);
var
  LHasAdapter: Boolean;
begin
  LHasAdapter := Res.RawWebResponse <> nil;
  if LHasAdapter then
    Res.RawWebResponse.SetCustomHeader('X-Via-RawResponse', 'via-raw');
  Res.AddHeader('X-Via-AddHeader', 'via-add');
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"hasAdapter":%s}', [BoolToStr(LHasAdapter, True).ToLower]));
end;

// ─── CORS route (GET + OPTIONS preflight) ──────────────────────────────────

// Middleware that runs first for /raw/cors — sets ACAO on both GET and OPTIONS,
// short-circuits with 204 for OPTIONS (Horse.CORS convention).
procedure CorsMiddleware(Req: THorseRequest; Res: THorseResponse; Next: TProc);
begin
  if Pos('/raw/cors', Req.RawWebRequest.PathInfo) = 1 then
  begin
    Res.AddHeader('Access-Control-Allow-Origin', '*');
    if SameText(Req.RawWebRequest.Method, 'OPTIONS') then
    begin
      Res.Status(204).Send('');
      raise EHorseCallbackInterrupted.Create;
    end;
  end;
  Next;
end;

procedure GetCors(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('cors-route:GET');
end;

// ─── Pool burst (concurrent load, marker-echo) ─────────────────────────────

procedure PoolBurst(Req: THorseRequest; Res: THorseResponse);
begin
  // Echo body verbatim so each concurrent request sees only its own marker.
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"marker":"' + JsonEsc(Req.Body) + '"}');
end;

// ─── COMPAT-1: shadow field wins over RawWebResponse.Content ───────────────

procedure CompatRawBody(Req: THorseRequest; Res: THorseResponse);
begin
  // Write a stub into RawWebResponse.Content, then call Res.Send — shadow
  // field (FCSBody / BodyText) MUST win at flush time. If it doesn't, the
  // response body will contain the stub value.
  if Res.RawWebResponse <> nil then
    Res.RawWebResponse.Content := 'rawwebresponse-stub-should-NOT-appear';
  Res.Send('shadow-wins');
end;

// ─── Streaming (not supported in nghttp2 v1 — return 501) ──────────────────

procedure StreamNotImplemented(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Status(501)
     .ContentType('application/json; charset=utf-8')
     .Send('{"error":"streaming not implemented in horse-provider-nghttp2 v1"}');
end;

// ─── M2b: HTTP/2 trailers demo ─────────────────────────────────────────────
//   Emits HEADERS + DATA "hello" + trailer HEADERS (grpc-status: 0,
//   grpc-message: OK) + END_STREAM. Verify with:
//     nghttp -v http://127.0.0.1:9010/grpc-status-zero
//   Look for the second HEADERS frame after DATA — that's the trailer.
//   Or with curl (newer versions show trailers):
//     curl --http2-prior-knowledge -v http://127.0.0.1:9010/grpc-status-zero

procedure GrpcStatusZero(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/grpc')
     .AddHeader('x-nghttp2-trailer-grpc-status',  '0')
     .AddHeader('x-nghttp2-trailer-grpc-message', 'OK')
     .Send('hello');
end;

// ─── main ──────────────────────────────────────────────────────────────────

var
  LUseTls:   Boolean;
  LUseMTls:  Boolean;
  LPort:     Word;
  LCfg:      THorseCrossSocketConfig;
  LExeDir:   string;
  LCertPath: string;
  LKeyPath:  string;
  LCaPath:   string;
  I:         Integer;

begin
  try
    // Parse args. `tls` = plain TLS (server cert only); `mtls` = mTLS
    // (server cert + client cert required, signed by ca.pem). mtls implies tls.
    LUseTls  := False;
    LUseMTls := False;
    for I := 1 to ParamCount do
    begin
      if SameText(ParamStr(I), 'tls')  then LUseTls  := True;
      if SameText(ParamStr(I), 'mtls') then begin LUseTls := True; LUseMTls := True; end;
    end;

    if LUseTls then
      LPort := TEST_PORT_H2
    else
      LPort := TEST_PORT_H2C;

    if LUseTls then
    begin
      LExeDir   := ExtractFilePath(ParamStr(0));
      LCertPath := LExeDir + CERT_REL_PATH;
      LKeyPath  := LExeDir + KEY_REL_PATH;
      LCaPath   := LExeDir + CA_REL_PATH;

      if not FileExists(LCertPath) then
      begin
        WriteLn(ErrOutput, 'ERROR: cert file not found: ', LCertPath);
        WriteLn(ErrOutput, 'Run ./gen-tls-cert.sh first (see samples/tests/).');
        ExitCode := 2;
        Exit;
      end;
      if not FileExists(LKeyPath) then
      begin
        WriteLn(ErrOutput, 'ERROR: key file not found: ', LKeyPath);
        ExitCode := 2;
        Exit;
      end;
      if LUseMTls and not FileExists(LCaPath) then
      begin
        WriteLn(ErrOutput, 'ERROR: CA file not found (required for mTLS): ', LCaPath);
        WriteLn(ErrOutput, 'Rerun ./gen-tls-cert.sh — the current version generates ca.pem too.');
        ExitCode := 2;
        Exit;
      end;

      if LUseMTls then
      begin
        WriteLn('HorseNghttp2TestServer — h2 over TLS with mTLS on port ', LPort);
        WriteLn('Server cert: ', LCertPath);
        WriteLn('Server key:  ', LKeyPath);
        WriteLn('CA cert:     ', LCaPath);
        WriteLn('Client cert REQUIRED. Test with:');
        WriteLn('  curl --http2 --insecure --cert tls/client-cert.pem --key tls/client-key.pem https://127.0.0.1:', LPort, '/ping');
      end
      else
      begin
        WriteLn('HorseNghttp2TestServer — h2 over TLS on port ', LPort);
        WriteLn('Cert: ', LCertPath);
        WriteLn('Key:  ', LKeyPath);
        WriteLn('Connect with:  curl --http2 --insecure https://localhost:', LPort, '/ping');
        WriteLn('Native suite:  HorseNghttp2TestClient.exe https://127.0.0.1:', LPort);
        WriteLn('mTLS mode:     HorseNghttp2TestServer.exe mtls   (needs tls/ca.pem too)');
      end;
    end
    else
    begin
      WriteLn('HorseNghttp2TestServer — h2c on port ', LPort);
      WriteLn('Connect with:  curl --http2-prior-knowledge http://localhost:', LPort, '/ping');
      WriteLn('Native suite:  HorseNghttp2TestClient.exe');
      WriteLn('TLS mode:      HorseNghttp2TestServer.exe tls    (needs tls/cert.pem + tls/key.pem)');
      WriteLn('mTLS mode:     HorseNghttp2TestServer.exe mtls   (needs tls/ca.pem too)');
    end;
    WriteLn('curl suite:    ./run-smoke-tests.sh');
    WriteLn('Ctrl-C to stop.');
    WriteLn;

    // ─── Middleware ────────────────────────────────────────────────────────
    THorse.Use(CorsMiddleware);   // must run before route handlers

    // ─── Ping ──────────────────────────────────────────────────────────────
    THorse.Get   ('/ping',                       GetPing);

    // ─── Methods ───────────────────────────────────────────────────────────
    THorse.Get   ('/methods/get',                MethodsGet);
    THorse.Post  ('/methods/post',               MethodsPost);
    THorse.Put   ('/methods/put/:id',            MethodsPutId);
    THorse.Delete('/methods/delete/:id',         MethodsDeleteId);
    THorse.Patch ('/methods/patch/:id',          MethodsPatchId);
    // HEAD: register as GET too — HTTP semantics say HEAD returns same headers
    // as GET minus body. Horse's router will match on mtGet for HEAD requests
    // that lack a distinct mtHead handler, and the client checks the header.
    THorse.Get   ('/methods/head',               MethodsHead);

    // ─── Params ────────────────────────────────────────────────────────────
    THorse.Get   ('/params/path/:id',            ParamsPathId);
    THorse.Get   ('/params/query',               ParamsQuery);
    THorse.Get   ('/params/multi/:a/:b',         ParamsMulti);

    // ─── Cookies ───────────────────────────────────────────────────────────
    THorse.Get   ('/cookies/set',                CookiesSet);
    THorse.Get   ('/cookies/echo',               CookiesEcho);

    // ─── Upload / Download ─────────────────────────────────────────────────
    THorse.Post  ('/upload',                     Upload);
    THorse.Get   ('/download',                   Download);

    // ─── Headers ───────────────────────────────────────────────────────────
    THorse.Get   ('/headers/echo',               HeadersEcho);

    // ─── Body echo ─────────────────────────────────────────────────────────
    THorse.Post  ('/echo/body',                  EchoBody);
    THorse.Post  ('/echo/body-twice',            EchoBodyTwice);

    // ─── Status codes ──────────────────────────────────────────────────────
    THorse.Get   ('/status/400',                 Status400);
    THorse.Get   ('/status/500',                 Status500);

    // ─── Large response ────────────────────────────────────────────────────
    THorse.Get   ('/response/large',             ResponseLarge);

    // ─── Adapter surfaces (Raw*) ───────────────────────────────────────────
    THorse.Get   ('/raw/webrequest',             RawWebRequestRoute);
    THorse.Get   ('/raw/webresponse',            RawWebResponseRoute);
    THorse.Get   ('/raw/cors',                   GetCors);   // OPTIONS handled by middleware

    // ─── Pool burst ────────────────────────────────────────────────────────
    THorse.Post  ('/pool/burst',                 PoolBurst);

    // ─── COMPAT-1 ──────────────────────────────────────────────────────────
    THorse.Get   ('/compat/rawbody',             CompatRawBody);

    // ─── Streaming (501 — not implemented in v1) ───────────────────────────
    THorse.Get   ('/stream/pull',                StreamNotImplemented);
    THorse.Get   ('/stream/content-type',        StreamNotImplemented);
    THorse.Get   ('/stream/empty',               StreamNotImplemented);

    // ─── M2b: HTTP/2 trailer demo (gRPC-style grpc-status trailer) ─────────
    THorse.Get   ('/grpc-status-zero',           GrpcStatusZero);

    if LUseTls then
    begin
      // TLS mode: pass cert+key via the shared cross-provider config record.
      // THorseProviderNghttp2.ListenWithConfig reads SSLEnabled/SSLCertFile/
      // SSLKeyFile, builds a TTlsServerContext, attaches to the nghttp2 server.
      LCfg             := THorseCrossSocketConfig.Default;
      LCfg.SSLEnabled  := True;
      LCfg.SSLCertFile := LCertPath;
      LCfg.SSLKeyFile  := LKeyPath;
      if LUseMTls then
      begin
        // mTLS — server demands a client cert signed by the CA in ca.pem.
        // Both SSLCACertFile AND SSLVerifyPeer must be set together per
        // the provider's semantics (either alone is meaningless).
        LCfg.SSLCACertFile := LCaPath;
        LCfg.SSLVerifyPeer := True;
      end;
      THorse.ListenWithConfig(LPort, LCfg);
    end
    else
      THorse.Listen(LPort);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
