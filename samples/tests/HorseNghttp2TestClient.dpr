program HorseNghttp2TestClient;

{$APPTYPE CONSOLE}

// ============================================================================
//  Horse + nghttp2 Provider — Native HTTP/2 Integration Test Client
//  ================================================================
//  Destination: horse-provider-nghttp2/samples/tests/HorseNghttp2TestClient.dpr
//
//  Requires HorseNghttp2TestServer running on 127.0.0.1:9010 before execution.
//  Speaks HTTP/2 cleartext (h2c prior-knowledge) via Nghttp2.Client.
//
//  Parity mirror of HorseICSTestClient.dpr (96 checks / 36 numbered tests).
//  Adaptations from ICS/CrossSocket clients:
//
//    - Transport is HTTP/2 (not HTTP/1.1). All requests go over a persistent
//      TCP connection multiplexed with independent streams (odd IDs 1, 3, 5…).
//      libnghttp2 handles the framing; our client library wraps the C API.
//
//    - Set-Cookie: HTTP/2 headers are opaque bytes just like HTTP/1.1 —
//      multiple Set-Cookie headers arrive as separate entries in the
//      response headers array; the parser stays the same.
//
//    - Concurrency tests (18, 29, 36): our v0.1 client is single-stream per
//      instance. Concurrent tests spawn one TNghttp2Client per parallel
//      request — each opens its own TCP connection. Real HTTP/2 multiplexing
//      on a shared connection lands in v1.1.
//
//    - Multipart POST (test 12): built inline as a raw multipart/form-data
//      byte buffer (no library helper) — same 200-or-400 acceptance criterion.
//
//    - Streaming (33–37, STREAM-1): real Web Streams / SSE as of this build;
//      v1.0.0 answered 501 here. On HTTP/2 there is no chunked framing to
//      assert — DATA frames carry their own length — so the checks look at
//      the reassembled body and the content-type, not at wire framing. The
//      one thing they deliberately do NOT assert is chunk ARRIVAL TIMING:
//      TNghttp2Client returns a completed response, so a stream that was
//      correctly delivered in five frames is indistinguishable here from one
//      buffered whole. `curl -N` is what shows the difference; see the
//      /stream/sse note in the server.
//
//  Test matrix — identical intent to the ICS/CS suites:
//
//    01  GET    /ping                        → 200 "pong"
//    02  GET    /methods/get                 → 200 {"method":"GET"}
//    03  POST   /methods/post                → 200 body echo
//    04  PUT    /methods/put/42              → 200 {"id":"42"}
//    05  DELETE /methods/delete/99           → 200 {"id":"99"}
//    06  PATCH  /methods/patch/7             → 200 {"id":"7"}
//    07  HEAD   /methods/head                → 200 + X-Head-Ok, empty body
//    08  GET    /params/path/hello           → 200 {"id":"hello"}
//    09  GET    /params/query?...            → 200 query echo
//    10  GET    /cookies/set                 → 200 + two Set-Cookie
//    11  GET    /cookies/echo                → 200 cookies echoed
//    12  POST   /upload  (multipart)         → 200 or 400
//    13  GET    /download                    → 200 + Content-Disposition
//    14  GET    /headers/echo                → 200 custom header echoed
//    15  POST   /methods/post  empty body    → 200
//    16  POST   /echo/body  large (64 KB)    → 200 {"size":65536}
//    17  POST   /echo/body  sequential A→B   → no body leakage
//    18  POST   /echo/body  ×4 concurrent    → no cross-contamination
//    19  GET    /params/multi/:a/:b          → 200 both params echoed
//    20  GET    /does/not/exist              → 404
//    21  GET    /status/400                  → 400
//    22  GET    /status/500                  → 500
//    23  Content-Type of JSON response       → "application/json"
//    24  GET    /response/large              → 65536-byte body
//    25  GET    /raw/webrequest              → adapter surfaces intact
//    26  OPTIONS /raw/cors                   → 204 + CORS headers
//    27  GET    /raw/cors                    → 200 "cors-route:GET"
//    28  GET    /raw/webresponse             → X-Via-* headers set
//    29  POST   /pool/burst ×8 concurrent    → all 200, unique markers
//    30  POST   /pool/burst  rapid sequential → 5 back-to-back after burst
//    31  POST   /echo/body-twice             → "equal":true (PATCH-REQ-9)
//    32  GET    /compat/rawbody              → body = "shadow-wins"
//    33  GET    /stream/pull                 → 200, 5 NDJSON records in order
//    34  GET    /stream/content-type         → 200 + declared content-type
//    35  GET    /stream/empty                → 200 + empty body (headers sent)
//    36  GET    /stream/pull  ×2 concurrent  → both complete, both 5 records
//    37  GET    /stream/sse                  → 200 text/event-stream, 5 events
// ============================================================================

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

uses
{$IF DEFINED(FPC)}
  {$IF DEFINED(UNIX)}
  cthreads,   { MUST be first on FPC/Unix — the concurrency tests below spawn
                TConcurrentThread instances; without the pthreads driver the
                binary aborts on the first thread creation. }
  {$IFEND}
  SysUtils, Classes, SyncObjs, StrUtils,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Diagnostics,
  System.StrUtils,   { PosEx — OccurrenceCount, used by the streaming checks }
{$IFEND}
  Nghttp2.Client,
  Nghttp2.Tls;   { for TTlsClientContext when target URL is https:// }

const
  DEFAULT_TARGET_URL = 'http://127.0.0.1:9010';
  TIMEOUT_MS         = 30000;

  LARGE_BODY_SIZE     = 65536;
  LARGE_RESPONSE_SIZE = 65536;
  CONCURRENT_COUNT    = 4;
  BURST_COUNT         = 8;
  RAPID_SEQ_COUNT     = 5;

var
  // Populated from command-line arg by Main. Every DoRequest / TConcurrentThread
  // reads these globals so URL/scheme changes propagate to every request.
  GTargetHost: string  = '127.0.0.1';
  GTargetPort: Word    = 9010;
  GUseTls:     Boolean = False;
  GTls:        TTlsClientContext = nil;  // shared across all requests when GUseTls=True

  GPassCount:  Integer = 0;
  GFailCount:  Integer = 0;
  GStartTicks: Int64   = 0;
  GLastTicks:  Int64   = 0;

// ─── Timing helpers ──────────────────────────────────────────────────────

function NowMs: Int64;
begin
{$IF DEFINED(FPC)}
  Result := Round(Now * 86400.0 * 1000.0);
{$ELSE}
  Result := TStopwatch.GetTimeStamp * 1000 div TStopwatch.Frequency;
{$IFEND}
end;

procedure Section(const ATitle: string);
var
  LNow, LDelta: Int64;
begin
  LNow   := NowMs;
  LDelta := LNow - GLastTicks;
  Writeln;
  Writeln(Format('── %s   (+%d ms since previous test, %d ms total)',
    [ATitle, LDelta, LNow - GStartTicks]));
  GLastTicks := LNow;
end;

procedure Check(const AName: string; const APassed: Boolean;
  const ADetail: string = '');
begin
  if APassed then
  begin
    Writeln('  PASS  ', AName);
    Inc(GPassCount);
  end
  else
  begin
    if ADetail <> '' then
      Writeln(Format('  FAIL  %s  [%s]', [AName, ADetail]))
    else
      Writeln('  FAIL  ', AName);
    Inc(GFailCount);
  end;
end;

// ─── Request wrappers ────────────────────────────────────────────────────

type
  TReqResult = record
    Status:      Integer;
    Body:        string;
    Response:    TNghttp2Response;
    ElapsedMs:   Int64;
    Errored:     Boolean;
    Error:       string;
  end;

// One-shot request via a fresh client instance. Prints TIME line.
// A fresh client per request mirrors how the ICS test client behaves under
// its non-keepalive default and side-steps our v0.1 single-stream limit.
function DoRequest(
  const AMethod, APath: string;
  const AHeaders: TNghttp2Headers;
  const ABody: TBytes): TReqResult;
var
  LClient: TNghttp2Client;
  LStart:  Int64;
begin
  Result := Default(TReqResult);
  LStart := NowMs;

  LClient := TNghttp2Client.Create;
  try
    try
      // Assign the shared TLS context BEFORE Connect when we're in TLS mode.
      // GTls is created once in main and re-used across every request — the
      // TTlsClientContext is designed for pool-style sharing (a per-request
      // TTlsClientConnection is allocated by Connect).
      if GUseTls then
        LClient.TlsContext := GTls;
      LClient.Connect(GTargetHost, GTargetPort);
      Result.Response := LClient.SubmitRequest(AMethod, APath, AHeaders, ABody, TIMEOUT_MS);
      Result.Status   := Result.Response.Status;
      if Length(Result.Response.Body) > 0 then
        Result.Body := TEncoding.UTF8.GetString(Result.Response.Body);
    except
      on E: Exception do
      begin
        Result.Errored := True;
        Result.Error   := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    LClient.Free;
  end;

  Result.ElapsedMs := NowMs - LStart;

  if Result.Errored then
    Writeln(Format('  TIME  %s %s  ERROR after %d ms — %s',
      [AMethod, APath, Result.ElapsedMs, Result.Error]))
  else if GUseTls then
    Writeln(Format('  TIME  %s https://%s:%d%s  total: %d ms',
      [AMethod, GTargetHost, GTargetPort, APath, Result.ElapsedMs]))
  else
    Writeln(Format('  TIME  %s http://%s:%d%s  total: %d ms',
      [AMethod, GTargetHost, GTargetPort, APath, Result.ElapsedMs]));
end;

// Header helpers.
function MakeHdr(const AName, AValue: string): TNghttp2Header;
begin
  Result.Name  := AName;
  Result.Value := AValue;
end;

function HeaderValue(const AResp: TNghttp2Response; const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AResp.Headers) do
    if SameText(AResp.Headers[I].Name, AName) then
      Exit(AResp.Headers[I].Value);
end;

{ Non-overlapping occurrences of ASub in AStr. Used by the streaming checks
  (STREAM-1) to count records without splitting into a list — counting is the
  whole assertion, and a delimiter-split would additionally have to reason
  about whether a trailing delimiter yields an empty final element. }
function OccurrenceCount(const AStr, ASub: string): Integer;
var
  LPos: Integer;
begin
  Result := 0;
  if (AStr = '') or (ASub = '') then Exit;
  LPos := Pos(ASub, AStr);
  while LPos > 0 do
  begin
    Inc(Result);
    LPos := PosEx(ASub, AStr, LPos + Length(ASub));
  end;
end;

// Returns the first Set-Cookie value for the given cookie name (before ';').
function GetSetCookieValue(const AResp: TNghttp2Response; const AName: string): string;
var
  I, LEqPos, LSemiPos: Integer;
  LLine, LFirstPair, LKey: string;
begin
  Result := '';
  for I := 0 to High(AResp.Headers) do
  begin
    if not SameText(AResp.Headers[I].Name, 'set-cookie') then Continue;
    LLine := AResp.Headers[I].Value;
    LSemiPos := Pos(';', LLine);
    if LSemiPos > 0 then
      LFirstPair := Copy(LLine, 1, LSemiPos - 1)
    else
      LFirstPair := LLine;
    LEqPos := Pos('=', LFirstPair);
    if LEqPos <= 0 then Continue;
    LKey := Trim(Copy(LFirstPair, 1, LEqPos - 1));
    if SameText(LKey, AName) then
      Exit(Trim(Copy(LFirstPair, LEqPos + 1, MaxInt)));
  end;
end;

// Build a minimal RFC 7578 multipart/form-data body with a single file part.
function BuildMultipartBody(const AFieldName, AFileName: string;
  const AFileBytes: TBytes; out ABoundary: string): TBytes;
var
  LHeader, LFooter: RawByteString;
begin
  ABoundary := 'HorseNghttp2ClientBoundary';
  LHeader :=
    '--' + AnsiString(ABoundary) + #13#10 +
    'Content-Disposition: form-data; name="' + AnsiString(AFieldName) +
    '"; filename="' + AnsiString(AFileName) + '"' + #13#10 +
    'Content-Type: text/plain' + #13#10 + #13#10;
  LFooter := #13#10 + '--' + AnsiString(ABoundary) + '--' + #13#10;

  SetLength(Result, Length(LHeader) + Length(AFileBytes) + Length(LFooter));
  if Length(LHeader) > 0 then
    Move(PAnsiChar(LHeader)^, Result[0], Length(LHeader));
  if Length(AFileBytes) > 0 then
    Move(AFileBytes[0], Result[Length(LHeader)], Length(AFileBytes));
  if Length(LFooter) > 0 then
    Move(PAnsiChar(LFooter)^, Result[Length(LHeader) + Length(AFileBytes)],
         Length(LFooter));
end;

// ─── Concurrency test scaffolding ────────────────────────────────────────

type
  TConcurrentEntry = record
    Marker: string;
    Status: Integer;
    Body:   string;
    Event:  TEvent;
    Error:  string;
  end;

  PConcurrentEntry = ^TConcurrentEntry;

  TConcurrentThread = class(TThread)
  private
    FMethod, FPath: string;
    FBody:          TBytes;
    FEntry:         PConcurrentEntry;
  protected
    procedure Execute; override;
  public
    constructor Create(const AMethod, APath: string; const ABody: TBytes;
      AEntry: PConcurrentEntry);
  end;

constructor TConcurrentThread.Create(const AMethod, APath: string;
  const ABody: TBytes; AEntry: PConcurrentEntry);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FMethod := AMethod;
  FPath   := APath;
  FBody   := ABody;
  FEntry  := AEntry;
end;

procedure TConcurrentThread.Execute;
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
begin
  LClient := TNghttp2Client.Create;
  try
    try
      // Same TLS context sharing as DoRequest — safe because TTlsClientContext
      // (a wrapped SSL_CTX) is read-only after configuration and per-request
      // state lives on the TTlsClientConnection that Connect allocates.
      if GUseTls then
        LClient.TlsContext := GTls;
      LClient.Connect(GTargetHost, GTargetPort);
      LResp := LClient.SubmitRequest(FMethod, FPath, nil, FBody, TIMEOUT_MS);
      FEntry^.Status := LResp.Status;
      if Length(LResp.Body) > 0 then
        FEntry^.Body := TEncoding.UTF8.GetString(LResp.Body);
    except
      on E: Exception do
        FEntry^.Error := E.ClassName + ': ' + E.Message;
    end;
  finally
    LClient.Free;
    FEntry^.Event.SetEvent;
  end;
end;

// ─── The 36-test matrix ──────────────────────────────────────────────────

procedure RunTests;
var
  R: TReqResult;
  LHeaders: TNghttp2Headers;
  LSessionCookie, LUserCookie: string;
  LFileBytes, LMPBody: TBytes;
  LBoundary: string;
  I, LMatched: Integer;
  LBatch: array of TConcurrentEntry;
  LThreads: array of TConcurrentThread;
  LMarker: string;
begin
  // ─── 01 ────────────────────────────────────────────────────────────────
  Section('01  GET /ping');
  R := DoRequest('GET', '/ping', nil, nil);
  Check('status 200',    R.Status = 200, IntToStr(R.Status));
  Check('body = "pong"', R.Body = 'pong', R.Body);

  // ─── 02 ────────────────────────────────────────────────────────────────
  Section('02  GET /methods/get');
  R := DoRequest('GET', '/methods/get', nil, nil);
  Check('status 200',          R.Status = 200, IntToStr(R.Status));
  Check('body contains "GET"', Pos('"GET"', R.Body) > 0, R.Body);

  // ─── 03 ────────────────────────────────────────────────────────────────
  Section('03  POST /methods/post  (JSON body echo)');
  SetLength(LHeaders, 1);
  LHeaders[0] := MakeHdr('content-type', 'application/json; charset=utf-8');
  R := DoRequest('POST', '/methods/post', LHeaders,
    TEncoding.UTF8.GetBytes('{"hello":"world"}'));
  Check('status 200',                  R.Status = 200, IntToStr(R.Status));
  Check('body contains "POST"',        Pos('"POST"', R.Body) > 0, R.Body);
  Check('body echoes request payload', Pos('hello',  R.Body) > 0, R.Body);

  // ─── 04 ────────────────────────────────────────────────────────────────
  Section('04  PUT /methods/put/42');
  R := DoRequest('PUT', '/methods/put/42', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('id = "42"',  Pos('"42"', R.Body) > 0, R.Body);

  // ─── 05 ────────────────────────────────────────────────────────────────
  Section('05  DELETE /methods/delete/99');
  R := DoRequest('DELETE', '/methods/delete/99', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('id = "99"',  Pos('"99"', R.Body) > 0, R.Body);

  // ─── 06 ────────────────────────────────────────────────────────────────
  Section('06  PATCH /methods/patch/7');
  R := DoRequest('PATCH', '/methods/patch/7', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('id = "7"',   Pos('"7"', R.Body) > 0, R.Body);

  // ─── 07 ────────────────────────────────────────────────────────────────
  Section('07  HEAD /methods/head  (headers only, empty body)');
  R := DoRequest('HEAD', '/methods/head', nil, nil);
  Check('status 200',    R.Status = 200, IntToStr(R.Status));
  Check('body is empty', R.Body = '', R.Body);
  Check('X-Head-Ok header present',
    SameText(HeaderValue(R.Response, 'x-head-ok'), 'true'),
    HeaderValue(R.Response, 'x-head-ok'));

  // ─── 08 ────────────────────────────────────────────────────────────────
  Section('08  GET /params/path/hello');
  R := DoRequest('GET', '/params/path/hello', nil, nil);
  Check('status 200',   R.Status = 200, IntToStr(R.Status));
  Check('id = "hello"', Pos('"hello"', R.Body) > 0, R.Body);

  // ─── 09 ────────────────────────────────────────────────────────────────
  Section('09  GET /params/query?name=Horse&value=Nghttp2');
  R := DoRequest('GET', '/params/query?name=Horse&value=Nghttp2', nil, nil);
  Check('status 200',        R.Status = 200, IntToStr(R.Status));
  Check('name = "Horse"',    Pos('"Horse"',   R.Body) > 0, R.Body);
  Check('value = "Nghttp2"', Pos('"Nghttp2"', R.Body) > 0, R.Body);

  // ─── 10 ────────────────────────────────────────────────────────────────
  Section('10  GET /cookies/set  (FIX-HEADER-DUP: two Set-Cookie headers)');
  R := DoRequest('GET', '/cookies/set', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  LSessionCookie := GetSetCookieValue(R.Response, 'session');
  LUserCookie    := GetSetCookieValue(R.Response, 'user');
  Check('Set-Cookie session=abc123', LSessionCookie = 'abc123', LSessionCookie);
  Check('Set-Cookie user=tester',    LUserCookie    = 'tester', LUserCookie);

  // ─── 11 ────────────────────────────────────────────────────────────────
  Section('11  GET /cookies/echo  (send cookies, verify echo)');
  if LSessionCookie = '' then LSessionCookie := 'abc123';
  if LUserCookie    = '' then LUserCookie    := 'tester';
  SetLength(LHeaders, 1);
  LHeaders[0] := MakeHdr('cookie',
    Format('session=%s; user=%s', [LSessionCookie, LUserCookie]));
  R := DoRequest('GET', '/cookies/echo', LHeaders, nil);
  Check('status 200',                 R.Status = 200,              IntToStr(R.Status));
  Check('session echoed as "abc123"', Pos('"abc123"', R.Body) > 0, R.Body);
  Check('user echoed as "tester"',    Pos('"tester"', R.Body) > 0, R.Body);

  // ─── 12 ────────────────────────────────────────────────────────────────
  Section('12  POST /upload  (multipart — nghttp2 v1 may return 400)');
  LFileBytes := TEncoding.UTF8.GetBytes('This is the uploaded file content.');
  LMPBody := BuildMultipartBody('file', 'myupload.txt', LFileBytes, LBoundary);
  SetLength(LHeaders, 1);
  LHeaders[0] := MakeHdr('content-type', 'multipart/form-data; boundary=' + LBoundary);
  R := DoRequest('POST', '/upload', LHeaders, LMPBody);
  Check('status 200 or 400 (nghttp2 multipart limitation)',
    (R.Status = 200) or (R.Status = 400), IntToStr(R.Status));

  // ─── 13 ────────────────────────────────────────────────────────────────
  Section('13  GET /download  (Content-Disposition + body)');
  R := DoRequest('GET', '/download', nil, nil);
  Check('status 200',          R.Status = 200, IntToStr(R.Status));
  Check('body contains "Horse"', Pos('Horse', R.Body) > 0, R.Body);
  Check('Content-Disposition: attachment',
    Pos('attachment', LowerCase(HeaderValue(R.Response, 'content-disposition'))) > 0,
    HeaderValue(R.Response, 'content-disposition'));

  // ─── 14 ────────────────────────────────────────────────────────────────
  Section('14  GET /headers/echo  (X-Test-Header round-trip)');
  SetLength(LHeaders, 1);
  LHeaders[0] := MakeHdr('x-test-header', 'nghttp2-value-42');
  R := DoRequest('GET', '/headers/echo', LHeaders, nil);
  Check('status 200',                    R.Status = 200, IntToStr(R.Status));
  Check('X-Test-Header value echoed',
    Pos('nghttp2-value-42', R.Body) > 0, R.Body);

  // ─── 15 ────────────────────────────────────────────────────────────────
  Section('15  POST /methods/post  (empty body — nil-body path)');
  R := DoRequest('POST', '/methods/post', nil, nil);
  Check('status 200 or 400 (empty-body POST)',
    (R.Status = 200) or (R.Status = 400), IntToStr(R.Status));

  // ─── 16 ────────────────────────────────────────────────────────────────
  Section('16  POST /echo/body  (65536-byte body — large body read)');
  SetLength(LFileBytes, LARGE_BODY_SIZE);
  FillChar(LFileBytes[0], LARGE_BODY_SIZE, Ord('X'));
  R := DoRequest('POST', '/echo/body', nil, LFileBytes);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check(Format('"size":%d exact', [LARGE_BODY_SIZE]),
    Pos(Format('"size":%d', [LARGE_BODY_SIZE]), R.Body) > 0,
    Format('body len=%d', [Length(R.Body)]));

  // ─── 17 ────────────────────────────────────────────────────────────────
  Section('17  POST /echo/body  sequential A → ping → B  (pool reset)');
  R := DoRequest('POST', '/echo/body', nil,
    TEncoding.UTF8.GetBytes('SEQUENTIAL_BODY_ALPHA'));
  Check('step A: status 200',                    R.Status = 200, IntToStr(R.Status));
  Check('step A: body contains SEQUENTIAL_BODY_ALPHA',
    Pos('SEQUENTIAL_BODY_ALPHA', R.Body) > 0, R.Body);
  R := DoRequest('GET', '/ping', nil, nil);
  Check('step ping: status 200',                 R.Status = 200, IntToStr(R.Status));
  R := DoRequest('POST', '/echo/body', nil,
    TEncoding.UTF8.GetBytes('SEQUENTIAL_BODY_BETA'));
  Check('step B: status 200',                    R.Status = 200, IntToStr(R.Status));
  Check('step B: body contains SEQUENTIAL_BODY_BETA',
    Pos('SEQUENTIAL_BODY_BETA', R.Body) > 0, R.Body);
  Check('step B: body does NOT contain ALPHA  (no pool leakage)',
    Pos('SEQUENTIAL_BODY_ALPHA', R.Body) = 0, '');

  // ─── 18 ────────────────────────────────────────────────────────────────
  Section('18  POST /echo/body  ×4 concurrent  (pool context isolation)');
  SetLength(LBatch,   CONCURRENT_COUNT);
  SetLength(LThreads, CONCURRENT_COUNT);
  for I := 0 to CONCURRENT_COUNT - 1 do
  begin
    LBatch[I].Marker := Format('MARKER_%d_%s', [I,
      IntToStr(Random(1000000))]);
    LBatch[I].Event  := TEvent.Create(nil, True, False, '');
    LThreads[I]      := TConcurrentThread.Create('POST', '/echo/body',
      TEncoding.UTF8.GetBytes(LBatch[I].Marker), @LBatch[I]);
  end;
  for I := 0 to CONCURRENT_COUNT - 1 do LThreads[I].Start;
  for I := 0 to CONCURRENT_COUNT - 1 do LBatch[I].Event.WaitFor(TIMEOUT_MS);
  LMatched := 0;
  for I := 0 to CONCURRENT_COUNT - 1 do
    if (LBatch[I].Status = 200) and (Pos(LBatch[I].Marker, LBatch[I].Body) > 0) then
      Inc(LMatched);
  Check(Format('all %d responses: status 200 + own marker echoed', [CONCURRENT_COUNT]),
    LMatched = CONCURRENT_COUNT, Format('%d/%d matched', [LMatched, CONCURRENT_COUNT]));
  LMatched := 0;
  for I := 0 to CONCURRENT_COUNT - 1 do
    if Pos('MARKER_', LBatch[I].Body) > 0 then
    begin
      // If we see any marker that ISN'T our own → cross-contamination
      if Pos(LBatch[I].Marker, LBatch[I].Body) > 0 then
        Inc(LMatched);
    end;
  Check('no response contains another request''s marker  (no cross-contamination)',
    LMatched = CONCURRENT_COUNT, Format('%d/%d clean', [LMatched, CONCURRENT_COUNT]));
  for I := 0 to CONCURRENT_COUNT - 1 do begin LThreads[I].Free; LBatch[I].Event.Free; end;

  // ─── 19 ────────────────────────────────────────────────────────────────
  Section('19  GET /params/multi/alpha/beta  (two path params)');
  R := DoRequest('GET', '/params/multi/alpha/beta', nil, nil);
  Check('status 200',       R.Status = 200, IntToStr(R.Status));
  Check('a = "alpha"',      Pos('"alpha"', R.Body) > 0, R.Body);
  Check('b = "beta"',       Pos('"beta"',  R.Body) > 0, R.Body);
  Check('both params present',
    (Pos('"alpha"', R.Body) > 0) and (Pos('"beta"', R.Body) > 0), R.Body);

  // ─── 20 ────────────────────────────────────────────────────────────────
  Section('20  GET /does/not/exist  (expect 404)');
  R := DoRequest('GET', '/does/not/exist', nil, nil);
  Check('status 404', R.Status = 404, IntToStr(R.Status));

  // ─── 21 ────────────────────────────────────────────────────────────────
  Section('21  GET /status/400  (explicit 400 response)');
  R := DoRequest('GET', '/status/400', nil, nil);
  Check('status 400', R.Status = 400, IntToStr(R.Status));
  Check('body contains status code', Pos('400', R.Body) > 0, R.Body);

  // ─── 22 ────────────────────────────────────────────────────────────────
  Section('22  GET /status/500  (explicit 500 response)');
  R := DoRequest('GET', '/status/500', nil, nil);
  Check('status 500', R.Status = 500, IntToStr(R.Status));
  Check('body contains status code', Pos('500', R.Body) > 0, R.Body);

  // ─── 23 ────────────────────────────────────────────────────────────────
  Section('23  GET /methods/get  (verify Content-Type response header)');
  R := DoRequest('GET', '/methods/get', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('Content-Type contains "application/json"',
    Pos('application/json', LowerCase(HeaderValue(R.Response, 'content-type'))) > 0,
    HeaderValue(R.Response, 'content-type'));

  // ─── 24 ────────────────────────────────────────────────────────────────
  Section('24  GET /response/large  (expect 65536-byte body)');
  R := DoRequest('GET', '/response/large', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check(Format('body length = %d', [LARGE_RESPONSE_SIZE]),
    Length(R.Body) = LARGE_RESPONSE_SIZE,
    Format('%d bytes received', [Length(R.Body)]));
  Check('body consists of ''X'' characters only',
    (Length(R.Body) > 0) and (Pos('X', R.Body) = 1) and
    (Length(StringReplace(R.Body, 'X', '', [rfReplaceAll])) = 0),
    Format('non-X chars: %d', [Length(StringReplace(R.Body, 'X', '', [rfReplaceAll]))]));

  // ─── 25 ────────────────────────────────────────────────────────────────
  Section('25  GET /raw/webrequest  (RawWebRequest adapter surface)');
  // Server-side route reads Req.RawWebRequest.GetFieldByName('X-Custom-Test')
  // — must match. HTTP/2 header names are lowercase on the wire (RFC 7540 §8.1.2).
  SetLength(LHeaders, 1);
  LHeaders[0] := MakeHdr('x-custom-test', 'RawAdapterProbe');
  R := DoRequest('GET', '/raw/webrequest', LHeaders, nil);
  Check('status 200',      R.Status = 200, IntToStr(R.Status));
  Check('hasAdapter true', Pos('"hasAdapter":true', R.Body) > 0, R.Body);
  Check('method = GET',    Pos('"method":"GET"',    R.Body) > 0, R.Body);
  Check('host present',    Pos('"host":"',          R.Body) > 0, R.Body);
  Check('pathInfo = /raw/webrequest',
    Pos('"pathInfo":"/raw/webrequest"', R.Body) > 0, R.Body);
  Check('GetFieldByName echoed custom header',
    Pos('RawAdapterProbe', R.Body) > 0, R.Body);
  // Tests what its name says: the key is present and its value is not empty.
  // It used to require the value to start with "127." or "::", which made it
  // a loopback check wearing a non-empty check's name — so every cross-machine
  // run failed here while the server was behaving perfectly, reporting the
  // real peer address (a Windows client against a Linux server through the
  // WSL bridge reports e.g. 172.18.64.1). That produced a standing 93/94 that
  // had to be explained away each time, which is how a suite teaches people
  // to ignore its failures.
  Check('RemoteAddr non-empty',
    (Pos('"remoteAddr":"', R.Body) > 0) and (Pos('"remoteAddr":""', R.Body) = 0),
    R.Body);

  // ─── 26 ────────────────────────────────────────────────────────────────
  Section('26  OPTIONS /raw/cors  (Horse.CORS pre-flight shape)');
  R := DoRequest('OPTIONS', '/raw/cors', nil, nil);
  Check('status 204', R.Status = 204, IntToStr(R.Status));
  Check('Access-Control-Allow-Origin: *',
    HeaderValue(R.Response, 'access-control-allow-origin') = '*',
    HeaderValue(R.Response, 'access-control-allow-origin'));

  // ─── 27 ────────────────────────────────────────────────────────────────
  Section('27  GET /raw/cors  (non-preflight branch)');
  R := DoRequest('GET', '/raw/cors', nil, nil);
  Check('status 200',            R.Status = 200, IntToStr(R.Status));
  Check('body = "cors-route:GET"', R.Body = 'cors-route:GET', R.Body);

  // ─── 28 ────────────────────────────────────────────────────────────────
  Section('28  GET /raw/webresponse  (Res.RawWebResponse.SetCustomHeader)');
  R := DoRequest('GET', '/raw/webresponse', nil, nil);
  Check('status 200',      R.Status = 200, IntToStr(R.Status));
  Check('hasAdapter true', Pos('"hasAdapter":true', R.Body) > 0, R.Body);
  Check('X-Via-RawResponse header set',
    HeaderValue(R.Response, 'x-via-rawresponse') <> '',
    HeaderValue(R.Response, 'x-via-rawresponse'));
  Check('X-Via-AddHeader header set',
    HeaderValue(R.Response, 'x-via-addheader') <> '',
    HeaderValue(R.Response, 'x-via-addheader'));

  // ─── 29 ────────────────────────────────────────────────────────────────
  Section('29  POST /pool/burst  ×8 concurrent  (cascade wake stress)');
  SetLength(LBatch,   BURST_COUNT);
  SetLength(LThreads, BURST_COUNT);
  for I := 0 to BURST_COUNT - 1 do
  begin
    LBatch[I].Marker := Format('BURST_%d_%s', [I, IntToStr(Random(1000000))]);
    LBatch[I].Event  := TEvent.Create(nil, True, False, '');
    LThreads[I]      := TConcurrentThread.Create('POST', '/pool/burst',
      TEncoding.UTF8.GetBytes(LBatch[I].Marker), @LBatch[I]);
  end;
  for I := 0 to BURST_COUNT - 1 do LThreads[I].Start;
  for I := 0 to BURST_COUNT - 1 do LBatch[I].Event.WaitFor(TIMEOUT_MS);
  LMatched := 0;
  for I := 0 to BURST_COUNT - 1 do
    if (LBatch[I].Status = 200) and (Pos(LBatch[I].Marker, LBatch[I].Body) > 0) then
      Inc(LMatched);
  Check(Format('all %d responses: status 200 + own marker', [BURST_COUNT]),
    LMatched = BURST_COUNT, Format('%d/%d matched', [LMatched, BURST_COUNT]));
  Check('no cross-contamination between burst responses',
    LMatched = BURST_COUNT, Format('%d/%d clean', [LMatched, BURST_COUNT]));
  for I := 0 to BURST_COUNT - 1 do begin LThreads[I].Free; LBatch[I].Event.Free; end;

  // ─── 30 ────────────────────────────────────────────────────────────────
  Section('30  POST /pool/burst  ×5 rapid sequential (drain/refill)');
  LMatched := 0;
  for I := 0 to RAPID_SEQ_COUNT - 1 do
  begin
    LMarker := Format('RAPID_%d_%s', [I, IntToStr(Random(1000000))]);
    R := DoRequest('POST', '/pool/burst', nil, TEncoding.UTF8.GetBytes(LMarker));
    if (R.Status = 200) and (Pos(LMarker, R.Body) > 0) then Inc(LMatched);
  end;
  Check(Format('all %d rapid sequential requests: 200 + correct marker', [RAPID_SEQ_COUNT]),
    LMatched = RAPID_SEQ_COUNT, Format('%d/%d matched', [LMatched, RAPID_SEQ_COUNT]));

  // ─── 31 ────────────────────────────────────────────────────────────────
  Section('31  POST /echo/body-twice  (PATCH-REQ-9 double-read cache)');
  R := DoRequest('POST', '/echo/body-twice', nil,
    TEncoding.UTF8.GetBytes('doubleread-payload-xyz'));
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('"first" contains posted value',
    Pos('doubleread-payload-xyz', R.Body) > 0, R.Body);
  Check('"second" contains posted value  (2nd read from cache)',
    (Pos('doubleread-payload-xyz', Copy(R.Body,
      Pos('doubleread-payload-xyz', R.Body) + 22, MaxInt)) > 0), R.Body);
  Check('"equal":true — both reads returned the same string',
    Pos('"equal":true', LowerCase(R.Body)) > 0, R.Body);

  // ─── 32 ────────────────────────────────────────────────────────────────
  Section('32  GET /compat/rawbody  (COMPAT-1: shadow field wins)');
  R := DoRequest('GET', '/compat/rawbody', nil, nil);
  Check('status 200',            R.Status = 200, IntToStr(R.Status));
  Check('body = "shadow-wins"',  R.Body = 'shadow-wins', R.Body);
  Check('RawWebResponse stub value NOT present in body',
    Pos('raw-stub', R.Body) = 0, R.Body);

  // ─── 33 ────────────────────────────────────────────────────────────────
  //  Five records, and they must arrive IN ORDER and WHOLE. Order is the
  //  interesting half: the writer appends into a buffer a data provider on
  //  another thread drains, so a locking mistake shows up here as interleaved
  //  or truncated records rather than as a crash.
  Section('33  GET /stream/pull  (NDJSON Web Stream — STREAM-1)');
  R := DoRequest('GET', '/stream/pull', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('5 NDJSON records present',
    (Pos('{"id":1}', R.Body) > 0) and (Pos('{"id":2}', R.Body) > 0) and
    (Pos('{"id":3}', R.Body) > 0) and (Pos('{"id":4}', R.Body) > 0) and
    (Pos('{"id":5}', R.Body) > 0), R.Body);
  Check('records in order (1 before 5)',
    Pos('{"id":1}', R.Body) < Pos('{"id":5}', R.Body), R.Body);
  Check('newline-delimited (5 separators)',
    OccurrenceCount(R.Body, #10) = 5, IntToStr(OccurrenceCount(R.Body, #10)));
  { No chunk framing may appear in the body. If FUseChunked were ever wrongly
    left on for HTTP/2, hex length prefixes and a "0" terminator would be
    sitting in this string — and RFC 9113 §8.2.2 forbids them on the wire. }
  Check('no chunked framing leaked into the body',
    Pos('0'#13#10#13#10, R.Body) = 0, R.Body);
  R := DoRequest('GET', '/ping', nil, nil);
  Check('server healthy after streaming',
    (R.Status = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.Status, R.Body]));

  // ─── 34 ────────────────────────────────────────────────────────────────
  //  Proves the streamed path emits headers through the same response bridge
  //  a buffered reply uses — a content-type set before SendStream survives.
  Section('34  GET /stream/content-type  (declared type survives streaming)');
  R := DoRequest('GET', '/stream/content-type', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('content-type is application/json',
    Pos('application/json', LowerCase(HeaderValue(R.Response, 'content-type'))) > 0,
    HeaderValue(R.Response, 'content-type'));
  Check('body is the streamed record',
    Pos('content-type-check', R.Body) > 0, R.Body);
  { The security baseline is emitted by EmitHeaders, which both paths share.
    Checking one of them here is what proves the streaming path really does
    reuse the bridge rather than hand-rolling a header set. }
  Check('security baseline present on streamed response',
    SameText(HeaderValue(R.Response, 'x-content-type-options'), 'nosniff'),
    HeaderValue(R.Response, 'x-content-type-options'));

  // ─── 35 ────────────────────────────────────────────────────────────────
  //  A handler that writes nothing still owes the client a complete response.
  //  Before STREAM-1's Close emitted headers on the way out, this case sent a
  //  HEADERS frame that never arrived and the client saw a stream that opened
  //  and closed with nothing in it.
  Section('35  GET /stream/empty  (no writes — still a complete 200)');
  R := DoRequest('GET', '/stream/empty', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body empty', R.Body = '', R.Body);
  Check('content-type still declared',
    Pos('x-ndjson', LowerCase(HeaderValue(R.Response, 'content-type'))) > 0,
    HeaderValue(R.Response, 'content-type'));
  R := DoRequest('GET', '/ping', nil, nil);
  Check('server healthy after empty stream',
    (R.Status = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.Status, R.Body]));

  // ─── 36 ────────────────────────────────────────────────────────────────
  //  Two streams at once. Each has its own buffer, lock and deferred flag, so
  //  this is where a per-SESSION mistake — one shared resume flag, say —
  //  would surface as one stream stalling or stealing the other's bytes.
  Section('36  GET /stream/pull ×2 concurrent  (independent streams)');
  SetLength(LBatch,   2);
  SetLength(LThreads, 2);
  for I := 0 to 1 do
  begin
    LBatch[I].Event  := TEvent.Create(nil, True, False, '');
    LThreads[I]      := TConcurrentThread.Create('GET', '/stream/pull', nil, @LBatch[I]);
  end;
  for I := 0 to 1 do LThreads[I].Start;
  for I := 0 to 1 do LBatch[I].Event.WaitFor(TIMEOUT_MS);
  Check('both concurrent streams: status 200',
    (LBatch[0].Status = 200) and (LBatch[1].Status = 200),
    Format('%d, %d', [LBatch[0].Status, LBatch[1].Status]));
  Check('both concurrent streams delivered all 5 records',
    (OccurrenceCount(LBatch[0].Body, #10) = 5) and
    (OccurrenceCount(LBatch[1].Body, #10) = 5),
    Format('%d, %d', [OccurrenceCount(LBatch[0].Body, #10),
                      OccurrenceCount(LBatch[1].Body, #10)]));
  for I := 0 to 1 do begin LThreads[I].Free; LBatch[I].Event.Free; end;
  R := DoRequest('GET', '/ping', nil, nil);
  Check('server healthy after concurrent streams',
    (R.Status = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.Status, R.Body]));

  // ─── 37 ────────────────────────────────────────────────────────────────
  //  SSE. The server sleeps 60 ms between events, so this route also exercises
  //  the case the whole DEFERRED/resume mechanism exists for: the data
  //  provider runs dry between writes and must be re-armed. Without the resume
  //  path this test hangs rather than fails — the first event arrives and
  //  nothing follows.
  Section('37  GET /stream/sse  (Server-Sent Events, paced writes)');
  R := DoRequest('GET', '/stream/sse', nil, nil);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('content-type is text/event-stream',
    Pos('text/event-stream', LowerCase(HeaderValue(R.Response, 'content-type'))) > 0,
    HeaderValue(R.Response, 'content-type'));
  Check('5 SSE events delivered',
    OccurrenceCount(R.Body, 'event: message') = 5,
    IntToStr(OccurrenceCount(R.Body, 'event: message')));
  Check('SSE record separator (blank line) present',
    Pos(#10#10, R.Body) > 0, R.Body);
  Check('last event survived the resume path',
    Pos('{"id":5}', R.Body) > 0, R.Body);
  R := DoRequest('GET', '/ping', nil, nil);
  Check('server healthy after SSE',
    (R.Status = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.Status, R.Body]));
end;

// ─── URL parser ─────────────────────────────────────────────────────────
// Extracts scheme, host, port from a URL like:
//   http://127.0.0.1:9010   → http, 127.0.0.1, 9010
//   https://127.0.0.1:9443  → https, 127.0.0.1, 9443
//   https://localhost       → https, localhost, 443 (default)

procedure ParseTargetURL(const AURL: string;
  out AScheme, AHost: string; out APort: Word);
var
  LRest: string;
  LColonPos, LSlashPos, LSchemePos: Integer;
begin
  LSchemePos := Pos('://', AURL);
  if LSchemePos = 0 then
    raise Exception.CreateFmt('malformed target URL "%s" — expected http://host[:port] or https://host[:port]', [AURL]);

  AScheme := LowerCase(Copy(AURL, 1, LSchemePos - 1));
  if (AScheme <> 'http') and (AScheme <> 'https') then
    raise Exception.CreateFmt('unsupported scheme "%s" — only http and https are supported', [AScheme]);

  LRest := Copy(AURL, LSchemePos + 3, MaxInt);
  // Strip any trailing path — we're just extracting host+port here.
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

// ─── Main ────────────────────────────────────────────────────────────────

var
  LTargetURL:    string;
  LScheme:       string;
  LClientCert:   string;
  LClientKey:    string;
  LArgIdx:       Integer;

begin
  // Parse args:
  //   HorseNghttp2TestClient.exe                                             → h2c local
  //   HorseNghttp2TestClient.exe http://host:port                            → h2c against custom
  //   HorseNghttp2TestClient.exe https://127.0.0.1:9443                      → h2 over TLS
  //   HorseNghttp2TestClient.exe https://127.0.0.1:9443 --client-cert tls/client-cert.pem --client-key tls/client-key.pem
  //     → mTLS — present client cert during handshake (needed against `HorseNghttp2TestServer.exe mtls`)
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

  try
    ParseTargetURL(LTargetURL, LScheme, GTargetHost, GTargetPort);
    GUseTls := (LScheme = 'https');
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'FATAL: ', E.Message);
      ExitCode := 2;
      Exit;
    end;
  end;

  // Set up shared TLS context once (used across every request when GUseTls).
  // Insecure mode = skip server cert verification (self-signed test certs OK).
  // If --client-cert + --client-key supplied, load them for mTLS.
  if GUseTls then
  begin
    GTls := TTlsClientContext.Create;
    GTls.SetInsecure;
    GTls.EnableHttp2Alpn;
    if (LClientCert <> '') and (LClientKey <> '') then
      GTls.SetClientCertificate(LClientCert, LClientKey);
  end;

  Writeln('[HorseNghttp2Test] Native HTTP/2 client - target: ', LTargetURL);
  if GUseTls then
  begin
    if LClientCert <> '' then
      Writeln('[HorseNghttp2Test] Mode: HTTPS + mTLS (h2 over TLS, ALPN, client cert = ', LClientCert, ')')
    else
      Writeln('[HorseNghttp2Test] Mode: HTTPS (h2 over TLS, ALPN, insecure cert verification)');
  end
  else
    Writeln('[HorseNghttp2Test] Mode: HTTP (h2c prior knowledge)');
  Writeln('[HorseNghttp2Test] Ensure the corresponding server is running.');
  Writeln('[HorseNghttp2Test] Timing: each step prints total client latency (nghttp2 client is synchronous).');

  Randomize;
  GStartTicks := NowMs;
  GLastTicks  := GStartTicks;

  try
    try
      RunTests;
    except
      on E: Exception do
        Writeln(ErrOutput, 'FATAL: ', E.ClassName, ': ', E.Message);
    end;
  finally
    if GTls <> nil then
      FreeAndNil(GTls);
  end;

  Writeln;
  Writeln(Format('[HorseNghttp2Test] %d passed, %d failed  (total %d) in %d ms wall clock',
    [GPassCount, GFailCount, GPassCount + GFailCount, NowMs - GStartTicks]));
  if GFailCount > 0 then
  begin
    Writeln('[HorseNghttp2Test] Some tests FAILED — see details above.');
    ExitCode := 1;
  end
  else
    Writeln('[HorseNghttp2Test] All tests PASSED.');

  Writeln;
  Write('[HorseNghttp2Test] Press ENTER to exit...');
  ReadLn;
end.
