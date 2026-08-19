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
  {$IF DEFINED(UNIX)}
  cthreads,   { MUST be the first unit on FPC/Unix — installs the pthreads
                threading driver before any other unit's initialization can
                touch TThread. The nghttp2 provider spawns an accept thread
                plus one thread per connection, so without this the server
                dies at run time with "This binary has no threading support
                compiled in". }
  {$IFEND}
  SysUtils, Classes, DateUtils,
{$ELSE}
  System.SysUtils, System.Classes, System.DateUtils,
{$IFEND}
  Horse,
  Horse.Commons,
  Horse.Exception,
  Horse.Exception.Interrupted,
  Horse.Provider.Nghttp2,
  { Linking this is what makes `eventloop` do anything — Nghttp2.Server holds
    only a function pointer and never names the unit. Unconditional on
    purpose: on Windows and macOS it compiles to an empty unit, so it costs
    nothing and there is no platform branch to get wrong here. }
  Nghttp2.Engine.Epoll,
  { The two engines are mutually exclusive BY PLATFORM, not by configuration:
    each compiles to an empty unit off its own OS, so exactly one of them
    reaches its initialization and assigns Nghttp2EngineFactory. Linking both
    unconditionally is therefore safe and is what makes `eventloop` mean epoll
    on Linux and IOCP on Windows with no define anywhere. }
  Nghttp2.Engine.Iocp,
  Horse.Provider.Config;   { for THorseCrossSocketConfig with SSL* fields (TLS mode) }

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

// ─── Load-shedding counter (OBSERV-1) ──────────────────────────────────────
//  GET /metrics/shed — reports THorseProviderNghttp2.SheddedRequests.
//
//  Exists so the counter can be CHECKED rather than trusted. Adding a counter
//  and never reading it is how the thing it measures stays invisible: the
//  one-shot log line proves the code path executes, but only a reader proves
//  the number is right.
//
//  Validation: run a load that saturates the pool and compare this value with
//  h2load's "status codes: N 5xx". They should agree closely — exactly, if
//  nothing else in the process answers 503, which on this server is the case.
//
//  Note it is a per-PROCESS counter reset by Listen, not per-connection, so a
//  reader on any connection sees the whole server's total.
procedure GetShedMetrics(Req: THorseRequest; Res: THorseResponse);
begin
  // ContentType BEFORE Send, matching every other handler here. The reverse
  // order compiles, but sets the header after the body is composed — at best
  // inconsistent, at worst ignored.
  // Both counters, because they answer different questions. inlineFallbacks
  // rises FIRST — the queue filled and threads absorbed the overflow.
  // sheddedRequests rises only once MaxInlineFallback threads are already
  // blocked, i.e. the fallback ran out of room too. Seeing the first climb
  // with the second at zero is the pool saturating without anyone refused.
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"sheddedRequests":'
       + IntToStr(THorseProviderNghttp2.SheddedRequests)
       + ',"inlineFallbacks":'
       + IntToStr(THorseProviderNghttp2.InlineFallbacks) + '}');
end;

// ─── Deliberately slow route (benchmarking) ────────────────────────────────
//  GET /slow/:ms — sleeps, then replies. Exists so a load generator can
//  measure what the dispatch pool is actually for.
//
//  Every other route here returns instantly, which makes them all useless for
//  that: with nothing to overlap, a pool can only add handoff cost, so
//  benchmarking /ping measures overhead and reports it as though it were
//  throughput. Sleeping stands in for the real thing — a query, an upstream
//  call — where the thread is parked and the transport is free to run other
//  streams on the same connection.
//
//  Serial expectation: N concurrent requests against /slow/50 take
//  N x 50 ms with inline dispatch, and roughly (N / workers) x 50 ms with
//  the pool. That ratio is the measurement.
procedure GetSlow(Req: THorseRequest; Res: THorseResponse);
var
  LMs: Integer;
begin
  LMs := StrToIntDef(Req.Params['ms'], 50);
  // Clamp: a benchmark typo should not park a worker for an hour.
  if LMs < 0    then LMs := 0;
  if LMs > 5000 then LMs := 5000;
  Sleep(LMs);
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"sleptMs":%d}', [LMs]));
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
// Next is TNextProc, NOT TProc. On Delphi the two are the same type
// (Horse.Proc declares TNextProc = System.SysUtils.TProc), which hides the
// divergence entirely; on FPC TNextProc is `procedure of object`, TProc is
// not, and the procedure then fails to match THorseCallbackProc with an
// "Incompatible type for arg no. 1 ... expected Open Array Of THorseCallback".
// Always spell middleware signatures with TNextProc — correct on both.
//
// (Comment uses // per line: the compiler message this documents contains a
// brace, and Delphi/FPC { } comments do not nest — an inner } ends the
// comment early. See memory feedback_delphi_brace_comment_nesting.)
procedure CorsMiddleware(Req: THorseRequest; Res: THorseResponse; Next: TNextProc);
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

// ─── Graceful-shutdown harness (benchmark/CI) ──────────────────────────────
//  `shutdown-after=N` fires THorse.StopListenGraceful from a background
//  thread N ms after startup, so a load generator can have requests in flight
//  when it lands. Nothing else in the suite exercises shutdown at all — Ctrl-C
//  just kills the process — yet the drain path carries the most delicate
//  bookkeeping in the provider: the in-flight counter that brackets queue
//  time, the connection-thread wait for outstanding workers, and the worker
//  pool draining rather than dropping what it has queued. A hang or a leak
//  there is invisible to every request-level test.
//
//  Usage:
//    HorseNghttp2TestServer.exe shutdown-after=2000 shutdown-timeout=10000
//    h2load -n 200 -c 4 -m 25 http://<host>:9010/slow/500
//
//  Exit code: 0 = drained cleanly, 1 = deadline hit or requests stranded.

type
  { Reports which connection driver the transport actually resolved.

    Needed because the banner prints before Listen, and Listen blocks for the
    life of the server — so at banner time the answer does not exist yet.
    `eventloop` is a request that degrades silently when the platform or the
    linked units cannot honour it, and an unlabelled fallback is exactly how a
    measurement gets attributed to the wrong configuration. }
  TDriverProbe = class(TThread)
  private
    FRequested: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ARequested: Boolean);
  end;

  TShutdownTrigger = class(TThread)
  private
    FDelayMS:   Integer;
    FTimeoutMS: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ADelayMS, ATimeoutMS: Integer);
  end;

constructor TDriverProbe.Create(ARequested: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRequested      := ARequested;
end;

procedure TDriverProbe.Execute;
begin
  // Long enough for Start to have run and the engine, if any, to have
  // registered. Short enough to land before the first request in any suite.
  Sleep(400);
  if Terminated then Exit;

  // Ask the engine what it is. This used to print 'epoll event loop'
  // unconditionally, which on Windows named the wrong driver while every
  // harness gate — all of which match that literal text — passed.
  if THorseProviderNghttp2.EventLoopActive then
    WriteLn('[driver] RESOLVED: ' + THorseProviderNghttp2.EngineName)
  else if FRequested then
    WriteLn('[driver] RESOLVED: thread per connection ' +
            '— event loop was REQUESTED but is unavailable ' +
            '(no engine unit linked for this platform)')
  else
    WriteLn('[driver] RESOLVED: thread per connection');
end;

constructor TShutdownTrigger.Create(ADelayMS, ATimeoutMS: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDelayMS   := ADelayMS;
  FTimeoutMS := ATimeoutMS;
end;

procedure TShutdownTrigger.Execute;
var
  LBefore:  Integer;
  LStart:   TDateTime;
  LElapsed: Integer;
begin
  Sleep(FDelayMS);

  LBefore := THorse.ActiveRequests;
  WriteLn;
  WriteLn('[shutdown] firing StopListenGraceful(', FTimeoutMS, ' ms)');
  WriteLn('[shutdown]   in flight at trigger: ', LBefore);

  LStart := Now;
  // Framework facade, per horse/.agents/AGENTS.md — resolves to the provider
  // override through THorse = class(THorseProvider).
  THorse.StopListenGraceful(FTimeoutMS);
  LElapsed := MilliSecondsBetween(Now, LStart);

  WriteLn('[shutdown]   returned after: ', LElapsed, ' ms');
  WriteLn('[shutdown]   in flight after: ', THorse.ActiveRequests);
  // Expected False: the flag marks the shutdown window, and the provider
  // clears it on the way out to match THorseProviderAbstract's contract.
  WriteLn('[shutdown]   IsShuttingDown after return: ',
          BoolToStr(THorse.IsShuttingDown, True), ' (cleared by contract)');

  // Returning at (or past) the deadline means the drain never completed and
  // the hard cutoff did the work instead — in-flight requests were severed.
  if LElapsed >= FTimeoutMS then
  begin
    WriteLn('[shutdown] FAIL: hit the ', FTimeoutMS, ' ms deadline — drain did not complete');
    ExitCode := 1;
  end
  else if THorse.ActiveRequests <> 0 then
  begin
    WriteLn('[shutdown] FAIL: returned with ', THorse.ActiveRequests, ' request(s) still active');
    ExitCode := 1;
  end
  else
  begin
    WriteLn('[shutdown] PASS: server-side drain completed in ', LElapsed, ' ms');
    // Deliberately narrow. This proves the server believes it drained — the
    // counter reached zero and the deadline was not hit. It cannot prove the
    // replies were delivered, because that is only observable at the client.
    // Check the load generator: succeeded should account for everything it
    // started. A server-side PASS alongside a pile of client-side errors is
    // the signature of a drain that finished before the responses were on the
    // wire, which is exactly what AllConnectionsIdle now guards against.
    WriteLn('[shutdown]   verify delivery client-side — h2load "succeeded" should');
    WriteLn('[shutdown]   equal "started"; errors there mean replies were severed.');
  end;
end;

// ─── main ──────────────────────────────────────────────────────────────────

var
  LUseTls:   Boolean;
  LUseMTls:  Boolean;
  LInline:   Boolean;
  LEventLoop: Boolean;
  LLoops:     Integer;
  LWorkers:  Integer;
  LShutAfter:   Integer;
  LShutTimeout: Integer;
  LTrigger:     TShutdownTrigger;
  LProbe:       TDriverProbe;
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
    LInline      := False;
    LEventLoop   := False;
    LLoops       := 0;
    LWorkers     := 0;
    LShutAfter   := 0;      // 0 = never auto-shutdown
    LShutTimeout := 10000;
    LTrigger     := nil;
    LProbe       := nil;
    for I := 1 to ParamCount do
    begin
      if SameText(ParamStr(I), 'tls')  then LUseTls  := True;
      if SameText(ParamStr(I), 'mtls') then begin LUseTls := True; LUseMTls := True; end;
      // Benchmarking controls — the A/B for what the dispatch pool buys.
      // `inline` runs the pipeline on the connection thread (pre-pool
      // behaviour); `workers=N` pins the pool size instead of auto-sizing.
      if SameText(ParamStr(I), 'inline') then LInline := True;
      if SameText(Copy(ParamStr(I), 1, 8), 'workers=') then
        LWorkers := StrToIntDef(Copy(ParamStr(I), 9, MaxInt), 0);
      // `eventloop` swaps the thread-per-connection driver for the epoll
      // engine. Linux + h2c only; ignored anywhere else.
      if SameText(ParamStr(I), 'eventloop') then LEventLoop := True;
      // `loops=N` sizes the event-loop pool; 0/absent = one per core.
      if SameText(Copy(ParamStr(I), 1, 6), 'loops=') then
        LLoops := StrToIntDef(Copy(ParamStr(I), 7, MaxInt), 0);
      // Graceful-shutdown harness — see TShutdownTrigger above.
      if SameText(Copy(ParamStr(I), 1, 15), 'shutdown-after=') then
        LShutAfter := StrToIntDef(Copy(ParamStr(I), 16, MaxInt), 0);
      if SameText(Copy(ParamStr(I), 1, 17), 'shutdown-timeout=') then
        LShutTimeout := StrToIntDef(Copy(ParamStr(I), 18, MaxInt), 0);
    end;

    if LInline then
      THorseProviderNghttp2.WorkerThreads := WORKER_THREADS_INLINE
    else if LWorkers > 0 then
      THorseProviderNghttp2.WorkerThreads := LWorkers;

    THorseProviderNghttp2.UseEventLoop  := LEventLoop;
    THorseProviderNghttp2.EngineThreads := LLoops;

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

    // Print the dispatch mode, and always the resolved thread count rather
    // than just "auto": a benchmark that cannot tell which configuration it
    // measured is not a measurement, and a pool that came up with a single
    // thread reads identically to a healthy one in the logs while behaving
    // like inline dispatch.
    if LInline then
      WriteLn('Dispatch:      INLINE (no worker pool — pre-2026-08 behaviour)')
    else if LWorkers > 0 then
      WriteLn('Dispatch:      worker pool, ', LWorkers, ' threads (pinned)')
    else
      WriteLn('Dispatch:      worker pool, ', TThread.ProcessorCount,
              ' threads (auto: one per core)');
    { Same reason the dispatch line prints a resolved number: `eventloop` is a
      REQUEST, not a guarantee — on Windows, or without Nghttp2.Engine.Epoll
      linked, it degrades silently to the thread driver. A run that cannot be
      told apart from the default is worthless as a comparison, so say which
      was asked for and name the condition that decides it. }
    if LEventLoop then
    begin
      WriteLn('Driver:        EVENT LOOP requested — epoll on Linux, IOCP on Windows');
      if LLoops > 0 then
        WriteLn('               loops=', LLoops, ' (pinned)')
      else
        WriteLn('               loops=', TThread.ProcessorCount, ' (auto: one per core)');
    end
    else
      WriteLn('Driver:        thread per connection (default)');
    WriteLn('               resolved driver is printed below once listening');
    WriteLn('Bench route:   /slow/:ms   e.g. /slow/50');
    WriteLn('Dispatch stats: GET /metrics/shed   (sheddedRequests + inlineFallbacks)');
    WriteLn('Compare with:  HorseNghttp2TestServer.exe inline   (or workers=N)');
    WriteLn('Event loop:    HorseNghttp2TestServer eventloop [loops=N]');
    if LShutAfter > 0 then
      WriteLn('Shutdown test: StopListenGraceful(', LShutTimeout, ' ms) fires in ',
              LShutAfter, ' ms  — exit code reports the verdict')
    else
      WriteLn('Shutdown test: HorseNghttp2TestServer.exe shutdown-after=2000 [shutdown-timeout=10000]');
    WriteLn('Ctrl-C to stop.');
    WriteLn;

    // ─── Middleware ────────────────────────────────────────────────────────
    THorse.Use(CorsMiddleware);   // must run before route handlers

    // ─── Ping ──────────────────────────────────────────────────────────────
    THorse.Get   ('/ping',                       GetPing);
    THorse.Get   ('/slow/:ms',                   GetSlow);   // benchmarking — see GetSlow
    THorse.Get   ('/metrics/shed',               GetShedMetrics);  // OBSERV-1 counter

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

    // Started before Listen, which blocks the main thread for the lifetime of
    // a console server. StopListenGraceful is what releases it.
    if LShutAfter > 0 then
    begin
      LTrigger := TShutdownTrigger.Create(LShutAfter, LShutTimeout);
      LTrigger.Start;
    end;

    // Same reason as the trigger: the answer only exists after Listen has
    // started the transport, and Listen never returns until shutdown.
    LProbe := TDriverProbe.Create(LEventLoop);
    LProbe.Start;

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

    // Listen has returned, so the trigger has called StopListenGraceful — but
    // it may still be printing its verdict and setting ExitCode. Join before
    // exiting or the process can race past its own result.
    if LTrigger <> nil then
    begin
      LTrigger.WaitFor;
      LTrigger.Free;
    end;

    // Joined too — it only sleeps 400 ms, but a server stopped faster than
    // that would otherwise leak the thread and race its own WriteLn.
    if LProbe <> nil then
    begin
      LProbe.WaitFor;
      LProbe.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
