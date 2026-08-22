unit Horse.Provider.Nghttp2;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2
//  THorseProviderNghttp2 — Console-shape provider entry point. Wires the
//  TCP accept loop + nghttp2 session runtime into Horse's Listen/Stop/
//  ListenWithConfig/StopListenGraceful class-method surface.
//
//  Framework contracts from horse/.agents/AGENTS.md (all mandatory for a
//  socket-owning provider — see the "Framework contracts every provider must
//  satisfy" section in patches/horse-provider-crosssocket/doc/
//  building-a-new-provider.md):
//    (1) GetActivePort override                     — line 219 below
//    (2) TriggerBeforeListen at top of Listen        — line 234
//    (3) TriggerBeforeStop  at top of StopListen     — line 269, 290
//    (4) StopListenGraceful with ActiveRequests drain — line 289
//
//  Selected via {$DEFINE HORSE_PROVIDER_NGHTTP2} (canonical) or the legacy
//  alias {$DEFINE HORSE_NGHTTP2} (Task 5 wires this into Horse.pas).
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, DateUtils,
  Horse.Proc,   // FPC-only: TProc = procedure (matches Horse.Provider.Abstract's signature)
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.DateUtils,
{$IFEND}
  Horse.Exception,
  Horse.Provider.Abstract,
  Horse.Provider.Config,
  Nghttp2.Server,
  Nghttp2.Types,
  Nghttp2.Tls,    { for TTlsServerContext — used in the FTls class var declaration below }
  Horse.Provider.Nghttp2.WorkerPool;   { THorseNghttp2WorkerPool — FWorkerPool class var }

type
  THorseProviderNghttp2 = class(THorseProviderAbstract)
  private
    class var FPort:       Integer;
    class var FServer:     TNghttp2Server;
    class var FStopEvent:  TEvent;
    class var FRunning:    Boolean;
    // TLS context — owned by the provider. Built lazily from
    // THorseCrossSocketConfig.SSLEnabled/SSLCertFile/SSLKeyFile inside
    // ListenWithConfig, freed on StopListen. nil = cleartext h2c.
    class var FTls:        TTlsServerContext;
    // Runs the Horse pipeline off the connection pump thread so that streams
    // multiplexed on one HTTP/2 connection execute concurrently instead of
    // single-file. nil = inline dispatch (the historical behaviour).
    class var FWorkerPool: THorseNghttp2WorkerPool;

    // Dispatch-pool size override. See the WorkerThreads class property.
    class var FWorkerThreads: Integer;
    class var FUseEventLoop: Boolean;
    { WS-8441 — see the EnableWebSocket class property. }
    class var FEnableWebSocket: Boolean;
    class var FEngineThreads: Integer;

    { OBSERV-1 (2026-08-17). Load shedding used to leave no trace on the
      server: the client got a correct 503 + Retry-After, but nothing here
      counted it, so an operator had no way to know it was happening.

      It cost a multi-round investigation to establish that a benchmark
      "failure" rate of ~20% was this path firing — h2load reports non-2xx as
      "failed", which reads like lost requests when every one had in fact been
      answered. A counter would have made it a one-line question.

      Integer, not Int64, and TInterlocked, matching TNghttp2Server's
      FActiveRequests exactly: TInterlocked's Int64 overloads are not uniformly
      available across the FPC versions this must build on, and a diagnostic
      counter that wraps after 2^31 sheds is not worth a compiler branch. }
    class var FSheddedRequests: Integer;
    class var FSheddedLogged:   Integer;   // 0/1 via TInterlocked — one-shot log

    { FALLBACK-1 (2026-08-18). When the dispatch queue is full, run the
      pipeline on THIS thread rather than answering 503 — but only while few
      enough threads are already doing so.

      Why a cap is required, and why it is a GLOBAL one rather than per-thread:
      a thread executing a handler inline cannot be asked for another request
      until it returns, so per-thread concurrency is already 1 and needs no
      enforcement. The danger is different — every loop falling back at once.
      Then all 28 loops sit in handlers, nobody reads sockets, and the engine
      stalls completely. Shedding at least keeps the server answering.

      So the cap bounds how many threads may be blocked simultaneously,
      leaving the rest to keep draining sockets. Past it, shed as before. }
    class var FInlineFallbacks: Integer;   // rescued from the queue-full path
    class var FInlineActive:    Integer;   // threads currently running inline
    class var FMaxInlineFallback: Integer;

    class function GetSheddedRequests: Integer; static;
    class function GetInlineFallbacks: Integer; static;
    class function ResolveInlineCap: Integer; static;
    class function TryClaimInlineSlot: Boolean; static;
    class procedure ReleaseInlineSlot; static;

    class function  GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;

    // The nghttp2 Server calls this on its connection worker thread once
    // a stream reaches END_STREAM.
    class procedure ExecutePipeline(const AStream: INghttp2Stream); static;

    // Bypasses the pool — for validation failures caught before the pipeline
    // is entered (SEC-29).
    class procedure SendError(const AStream: INghttp2Stream;
      AStatus: Integer; const AMessage: string); static;

    class procedure InternalListen(APort: Integer;
      const AConfig: THorseNghttp2Config); static;

  public
    // Framework contract (1): Multi-Instance resolver needs the physical port.
    // `override` (not `virtual`) — THorseProviderAbstract declares it virtual;
    // we replace the implementation, not introduce a new vtable slot.
    class function GetActivePort: Integer; override;

    class procedure Listen; overload; override;
    // Full Listen contract — required by Horse.Instance.pas:1462. AHost is
    // accepted for API compatibility with the other providers but is ignored
    // in v1: nghttp2 always binds INADDR_ANY (0.0.0.0). The three trailing
    // defaults also satisfy the common Listen(APort) call shape used by the
    // sample .dpr files — no separate 1-arg overload needed (that produced
    // E2251 ambiguous-overload when both signatures matched Listen(9010)).
    class procedure Listen(const APort: Integer; const AHost: string = '0.0.0.0';
      const ACallbackListen: TProc = nil; const ACallbackStopListen: TProc = nil);
      reintroduce; overload;
    class procedure ListenWithConfig(const APort: Integer;
      const AConfig: THorseCrossSocketConfig); override;

    class procedure StopListen; override;
    // Framework contract (4): coordinated drain within the timeout.
    // Base signature: `class procedure StopListenGraceful(const ATimeoutMS: Integer = 5000); virtual;`
    // — must match (default parameter value optional in override, but the
    // presence of `= 5000` on the base means callers can omit the arg).
    class procedure StopListenGraceful(const ATimeoutMS: Integer = 5000); override;

    class property Port: Integer read GetPort write SetPort;

    { Size of the pool that runs the Horse pipeline, set before Listen.

        0  (default) — auto: THorseCrossSocketConfig.IoThreads if set,
                       otherwise one worker per core.
        N  > 0       — exactly N workers.
        WORKER_THREADS_INLINE — no pool at all: the pipeline runs inline on
                       the connection thread, the pre-2026-08 behaviour.

      Inline dispatch is the escape hatch, and the control case for measuring
      what the pool is worth. It removes two thread handoffs per request, so
      it can genuinely win for handlers that never block — but one slow route
      then stalls every other stream multiplexed on that connection, which is
      the whole reason the pool exists. }
    class property WorkerThreads: Integer read FWorkerThreads write FWorkerThreads;

    { WS-8441. Set True before Listen to accept WebSocket-over-HTTP/2
      (RFC 8441 extended CONNECT). Off by default, and deliberately so.

      Turning it on advertises SETTINGS_ENABLE_CONNECT_PROTOCOL, which invites
      conforming clients to attempt the upgrade. That is only a good trade if
      your clients can use it: browsers implement RFC 8441, most non-browser
      WebSocket libraries do not, and this provider has no HTTP/1.1 to fall
      back to — for those clients it is "cannot connect", not "slower path".

      Requires a worker pool (the default). The WebSocket read loop blocks for
      the life of the connection, so one occupies one worker throughout. }
    class property EnableWebSocket: Boolean read FEnableWebSocket write FEnableWebSocket;

    { How many requests this process has answered with 503 because the
      dispatch queue was full. Reset by Listen.

      Nothing is LOST when this rises — every shed request receives a proper
      503 + Retry-After and the client is free to retry. It is a capacity
      signal, not an error count: a non-zero and growing value means the
      worker pool cannot keep up with offered load, and the levers are
      WorkerThreads (more workers) or WORKER_THREADS_INLINE (no pool, which
      is faster on non-blocking handlers and only risks head-of-line blocking
      on routes that actually block).

      Measured shape, for calibration: on a 28-core box at c=10 000 against a
      trivial route, the default pool shed ~19-21% while inline shed nothing
      at identical throughput. On a route that blocks, the pool is worth
      18.3x and inline is the wrong answer. Read this counter before choosing.

      Poll it from a /metrics route, or sample it either side of a window for
      a rate. It is deliberately a plain counter rather than an AddOnTelemetry
      hook: shedding happens BEFORE the pipeline is entered, so no per-request
      telemetry callback runs for a shed request — a hook would report zero
      exactly when the number matters. }
    class property SheddedRequests: Integer read GetSheddedRequests;

    { How many requests were rescued by running inline because the dispatch
      queue was full. Reset by Listen. Rising here is the EARLY warning that
      SheddedRequests is the late one: fallbacks happen first, and 503s only
      begin once MaxInlineFallback threads are already blocked. }
    class property InlineFallbacks: Integer read GetInlineFallbacks;

    { How many threads may run a handler inline at once when the queue is
      full, set before Listen.

        0  (default) — auto: one quarter of the cores, minimum 1.
        N  > 0       — exactly N.
        INLINE_FALLBACK_DISABLED — never fall back; always answer 503, which
                       is the pre-2026-08-18 behaviour.

      The quarter is deliberate and the reasoning is worth keeping: inline
      execution buys back a refused request at the cost of TAIL LATENCY, and
      measurement is unambiguous about the size of that cost. On a blocking
      route via the epoll engine, pool and inline deliver identical throughput
      and identical mean latency — but inline's max was 1.14s against 410ms at
      c=200, and 4.64s against 1.85s at c=1000, with up to 4.6x the standard
      deviation. A stalled loop thread holds its share of connections; the
      mean hides it because the aggregate is bounded by the worker count
      either way.

      So this is not free, and the cap is what keeps it proportionate: a
      minority of threads may block to avoid refusing work, while the majority
      keep draining sockets. Set it to the loop count and a saturated server
      stops reading entirely; set it to 0 and you are back to shedding. }
    class property MaxInlineFallback: Integer
      read FMaxInlineFallback write FMaxInlineFallback;

    { Drive connections from an epoll event loop instead of one thread each,
      set before Listen. Linux only, h2c only, and it takes effect only when
      Nghttp2.Engine.Epoll is linked into the binary — otherwise it is
      silently ignored and the thread driver runs, which is the behaviour
      every shipped suite validates.

      Off by default, and staying that way until the engine has a validation
      round of its own. The thread driver is what is proven. }
    class property UseEventLoop: Boolean read FUseEventLoop write FUseEventLoop;

    { What the transport ACTUALLY got, valid only once listening. Distinct
      from UseEventLoop, which is only the request — reading the request back
      would confirm nothing. }
    class function EventLoopActive: Boolean; static;
    { Which engine is actually running — '' when it is the thread driver.
      Read this instead of assuming; see INghttp2Engine.DriverName. }
    class function EngineName: string; static;

    { Event-loop threads, when UseEventLoop is on. 0 = one per core.

      Each loop binds its own SO_REUSEPORT listener and the kernel spreads
      accepts across them. With a single loop the thread saturated at ~106%
      CPU at every connection count measured, capping the engine at one core;
      see plans/horse-nghttp2-high-concurrency.md. }
    class property EngineThreads: Integer read FEngineThreads write FEngineThreads;
  end;

const
  // Assign to THorseProviderNghttp2.WorkerThreads to disable the pool.
  // Negative rather than 0 because 0 already means "auto" here, matching
  // IoThreads' documented "0 = library picks" semantics.
  WORKER_THREADS_INLINE = -1;

  { Assign to THorseProviderNghttp2.MaxInlineFallback to switch inline
    fallback off and answer 503 on a full queue, as before FALLBACK-1. }
  INLINE_FALLBACK_DISABLED = -1;

implementation

uses
  Horse,
  Horse.Commons,
  Horse.Core,   { THorseCore.SetIsShuttingDown — see StopListenGraceful }
  Horse.Exception.Interrupted,
  Horse.Provider.Nghttp2.Pool,
  Horse.Provider.Nghttp2.Request,
  Horse.Provider.Nghttp2.Response,
  Horse.Provider.Nghttp2.WebResponseAdapter,
  Horse.Provider.Nghttp2.StreamWriter,      { STREAM-1: registers the Res.SendStream writer in its initialization }
  Horse.Provider.Nghttp2.Grpc.Dispatcher,   { M4a: intercept application/grpc* before Horse routing }
  Horse.Provider.Nghttp2.Grpc.Registry,     { M6b: THorseGrpc.IsInboundStreaming — see ShouldStreamInboundTrampoline }
  Horse.Core.WebSocket,                     { WS-8441: THorseWebSocketUpgrader service key }
  Horse.Provider.Nghttp2.WebSocket,         { WS-8441: TNghttp2WebSocketUpgrader }
{$IF DEFINED(FPC)}
  StrUtils,          { StartsText }
{$ELSE}
  System.StrUtils,   { StartsText }
{$IFEND}
  Nghttp2.Native;    { NghttpLoad + diagnostics — see InternalListen }
  { Nghttp2.Tls already in interface uses — TTlsServerContext is a class field }

// ─── Helpers ──────────────────────────────────────────────────────────────

function JsonEscape(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

// Unit-scope trampoline. Delphi treats `class procedure` and `procedure of
// object` as distinct method-pointer types (implicit Self is TClass vs
// TObject respectively), so a class method can't be assigned directly to
// TNghttp2OnRequestProc. This trampoline is a plain procedure that matches
// the type and forwards to the class method.
procedure ExecutePipelineTrampoline(const AStream: INghttp2Stream); forward;
function  ShouldStreamInboundTrampoline(const AStream: INghttp2Stream): Boolean; forward;

// ============================================================================
// THorseProviderNghttp2
// ============================================================================

class function THorseProviderNghttp2.GetInlineFallbacks: Integer;
begin
  Result := TInterlocked.CompareExchange(FInlineFallbacks, 0, 0);
end;

class function THorseProviderNghttp2.ResolveInlineCap: Integer;
begin
  Result := FMaxInlineFallback;
  if Result <> 0 then Exit;          // explicit value, or DISABLED (-1)
  // Auto: a quarter of the cores, so most threads keep draining sockets
  // while a minority absorb handlers. See MaxInlineFallback for the latency
  // measurement this ratio comes from.
  Result := TThread.ProcessorCount div 4;
  if Result < 1 then Result := 1;
end;

class function THorseProviderNghttp2.TryClaimInlineSlot: Boolean;
var
  LCap: Integer;
begin
  LCap := ResolveInlineCap;
  if LCap <= 0 then Exit(False);     // INLINE_FALLBACK_DISABLED
  // Increment-then-test, not test-then-increment: two threads testing a
  // counter below the cap would both pass and both proceed. Claiming first
  // and standing down on overshoot is the only version that is actually
  // atomic without a lock.
  if TInterlocked.Increment(FInlineActive) <= LCap then
    Exit(True);
  TInterlocked.Decrement(FInlineActive);
  Result := False;
end;

class procedure THorseProviderNghttp2.ReleaseInlineSlot;
begin
  TInterlocked.Decrement(FInlineActive);
end;

class function THorseProviderNghttp2.GetSheddedRequests: Integer;
begin
  // CompareExchange(x, 0, 0) is the read half of the same idiom
  // TNghttp2Server uses for FStopping/FIdle: a plain read of a value another
  // thread is incrementing is not guaranteed to be seen, and this is read
  // from a route handler while workers are shedding.
  Result := TInterlocked.CompareExchange(FSheddedRequests, 0, 0);
end;

class function THorseProviderNghttp2.GetPort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProviderNghttp2.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;

// ─── Framework contract (1) ─────────────────────────────────────────────
class function THorseProviderNghttp2.GetActivePort: Integer;
begin
  Result := FPort;
end;

// ─── Pipeline dispatch (called on connection worker threads) ─────────────

class procedure THorseProviderNghttp2.SendError(const AStream: INghttp2Stream;
  AStatus: Integer; const AMessage: string);
var
  LBuf: TBytes;
begin
  AStream.StatusCode := AStatus;
  AStream.Header['content-type']           := 'application/json; charset=utf-8';
  AStream.Header['x-content-type-options'] := 'nosniff';
  AStream.Header['x-frame-options']        := 'DENY';
  AStream.Header['server']                 := 'unknown';
  AStream.Header['cache-control']          := 'no-store';

  LBuf := TEncoding.UTF8.GetBytes(Format('{"error":"%s"}', [JsonEscape(AMessage)]));
  AStream.Send(LBuf);
end;

class procedure THorseProviderNghttp2.ExecutePipeline(const AStream: INghttp2Stream);
var
  LCtx:          THorseContext;
  LValResult:    TRequestValidationResult;
  LRejectReason: string;
begin
  // SEC-29: probe-only validation before touching the pool. If invalid,
  // send an error directly and skip the pool entirely — no context allocated
  // for a request that was never going to run.
  LValResult := TNghttp2RequestBridge.Populate(AStream, nil, LRejectReason);
  if LValResult <> rvOK then
  begin
    case LValResult of
      rvMethodNotAllowed: SendError(AStream, 405, 'Method Not Allowed');
    else
      SendError(AStream, 400, 'Bad Request: ' + LRejectReason);
    end;
    Exit;
  end;

  // SEC-30 note: the in-flight counter is not taken here. It brackets the
  // whole dispatch — including time spent queued for a worker — and so lives
  // in ExecutePipelineTrampoline at the bottom of this unit. Counting only
  // from here would let StopListenGraceful see zero in-flight work while
  // requests were still sitting in the pool queue, and then force-close the
  // connections they were about to answer on.

  // M4a: gRPC dispatch — intercept `application/grpc*` content-type BEFORE
  // the Horse pipeline. Bypasses THorseContextPool + THorse.Execute entirely
  // for zero-overhead protobuf dispatch. Returns True when the request was
  // handled; False → fall through to normal Horse routing.
  if THorseGrpcDispatcher.TryDispatch(AStream) then
    Exit;

  LCtx := THorseContextPool.Instance.Acquire;
  try
    // Full population (writes shadow fields + RawWebRequest adapter)
    TNghttp2RequestBridge.Populate(AStream, LCtx.Request, LRejectReason);

    // RawWebResponse — required by Horse.CORS + horse-security-headers +
    // any middleware that calls Res.RawWebResponse.SetCustomHeader.
    LCtx.Response.SetCSRawWebResponse(TNghttp2WebResponse.Create(AStream));

    { WS-8441. Res.UpgradeToWebSocket resolves its upgrader out of
      Req.Services, so it must be registered before the route runs — the same
      contract the Indy and socket providers satisfy.

      Registered only for a stream that actually arrived as extended CONNECT.
      Offering it on ordinary requests would let a route call
      UpgradeToWebSocket on a stream the client never asked to upgrade, which
      cannot work and would fail deep inside the read loop rather than at the
      call. Without the upgrader present, Horse's own fail-fast answers 501,
      which is the correct reply to "upgrade me" on a plain GET. }
    if FEnableWebSocket
       and SameText(AStream.Header[':method'], 'CONNECT')
       and SameText(AStream.Header[':protocol'], 'websocket') then
      LCtx.Request.Services.Add(THorseWebSocketUpgrader,
        TNghttp2WebSocketUpgrader.Create(AStream), True);

    // ── Horse middleware/route pipeline ────────────────────────────────
    try
      THorse.Execute(LCtx.Request, LCtx.Response);
    except
      on EHorseCallbackInterrupted do
        ;   // BUG-2: normal pipeline completion signal — silence

      on E: EHorseException do
      begin
        LCtx.Response.Status(E.Status);
        LCtx.Response.ContentType('application/json; charset=utf-8');
        LCtx.Response.Send(Format('{"error":"%s"}', [JsonEscape(E.Message)]));
      end;

      on E: Exception do
      begin
        // SEC-31: never leak stack traces to clients.
        if IsConsole then
          WriteLn(ErrOutput, Format('[Nghttp2] %s: %s', [E.ClassName, E.Message]));
        LCtx.Response.Status(500);
        LCtx.Response.ContentType('application/json; charset=utf-8');
        LCtx.Response.Send('{"error":"Internal Server Error"}');
      end;
    end;

    // ── Flush to the transport ─────────────────────────────────────────
    TNghttp2ResponseBridge.Flush(LCtx.Response, AStream, '');
  finally
    THorseContextPool.Instance.Release(LCtx);
  end;
end;

// ─── Listen / ListenWithConfig ───────────────────────────────────────────

class procedure THorseProviderNghttp2.InternalListen(APort: Integer;
  const AConfig: THorseNghttp2Config);
var
  LConfig:  THorseNghttp2Config;
  LThreads: Integer;
begin
  // Dynamic-load libnghttp2 at first Listen.  Was a link-time dependency
  // (external LIBNGHTTP2) — refactored 2026-08-06 to mirror the OpenSSL
  // loader.  Serial startup here means no thread-safety concern for the
  // load itself.  Idempotent — repeated calls return cached True.
  if not NghttpLoad then
    raise Exception.CreateFmt(
      'libnghttp2 could not be loaded — %s.  Install nghttp2 runtime ' +
      '(Windows: place nghttp2.dll next to the .exe; ' +
      'Linux: apt install libnghttp2-14 / dnf install libnghttp2; ' +
      'macOS: brew install nghttp2).',
      [NghttpLoadError]);

  // Framework contract (2)
  TriggerBeforeListen;

  // SEC-32: double-start guard
  if FServer <> nil then
    StopListen;

  LConfig := AConfig;

  // ── Dispatch pool ──────────────────────────────────────────────────────
  // Without it, THorse.Execute runs on the connection pump thread, so the
  // 100 streams an HTTP/2 client may multiplex over one connection execute
  // strictly one at a time and any slow route blocks the rest.
  LThreads := LConfig.WorkerThreads;
  if LThreads > 0 then
  begin
    FWorkerPool := THorseNghttp2WorkerPool.Create(LThreads);
    LConfig.AsyncDispatch := True;
    // OBSERV-1: per-run counters. Listen may be called again after StopListen
    // (SEC-32 double-start), and a counter carried across restarts would
    // describe a server that no longer exists.
    TInterlocked.Exchange(FSheddedRequests, 0);
    TInterlocked.Exchange(FSheddedLogged, 0);
    TInterlocked.Exchange(FInlineFallbacks, 0);
    TInterlocked.Exchange(FInlineActive, 0);
  end
  else
    LConfig.AsyncDispatch := False;

  // Warm the context pool before the listener opens. Its lazy singleton
  // accessor is not thread-safe, and once connections arrive several worker
  // threads can reach it at once.
  THorseContextPool.Instance;

  FServer := TNghttp2Server.Create;
  FServer.OnRequest := ExecutePipelineTrampoline;
  { INBOUND-1 / M6b. Asked once per request on HEADERS. Returning True routes
    the body to the inbound queue AND moves dispatch to HEADERS, which is what
    a client-streaming or bidi gRPC handler needs — it must run while the peer
    is still sending. Every other path answers False and behaves as before. }
  FServer.OnShouldStreamInbound := ShouldStreamInboundTrampoline;
  FServer.EnableConnectProtocol := FEnableWebSocket;   { WS-8441 }
  // Hand the TLS context to the server (or nil for h2c). The server holds a
  // non-owning reference — FTls stays owned by the provider until StopListen.
  FServer.TlsContext := FTls;
  FPort := APort;
  FServer.Start(LConfig);

  DoOnListen;

  // Critical rule #3: only block main thread in console applications.
  // VCL / service / daemon binaries run their own message/event loop.
  if IsConsole then
  begin
    FRunning := True;
    if FStopEvent = nil then
      FStopEvent := TEvent.Create(nil, True, False, '');
    while FRunning do
      FStopEvent.WaitFor(INFINITE);
    FreeAndNil(FStopEvent);
  end;
end;

class procedure THorseProviderNghttp2.Listen;
begin
  if FPort <= 0 then
    FPort := 9200;
  ListenWithConfig(FPort, THorseCrossSocketConfig.Default);
end;

class procedure THorseProviderNghttp2.Listen(const APort: Integer; const AHost: string;
  const ACallbackListen: TProc; const ACallbackStopListen: TProc);
begin
  // Framework contract dispatched from Horse.Instance.Listen (line 1462).
  // Store the lifecycle callbacks via the abstract base's OnListen /
  // OnStopListen properties; DoOnListen / DoOnStopListen (already fired by
  // InternalListen / StopListen) will invoke them.
  if Assigned(ACallbackListen) then
    OnListen := ACallbackListen;
  if Assigned(ACallbackStopListen) then
    OnStopListen := ACallbackStopListen;
  // AHost intentionally ignored in v1 (INADDR_ANY only). Track TODO for v2.
  ListenWithConfig(APort, THorseCrossSocketConfig.Default);
end;

class function THorseProviderNghttp2.EventLoopActive: Boolean;
begin
  Result := (FServer <> nil) and FServer.UsingEventLoop;
end;

class function THorseProviderNghttp2.EngineName: string;
begin
  if FServer <> nil then
    Result := FServer.EngineName
  else
    Result := '';
end;

class procedure THorseProviderNghttp2.ListenWithConfig(const APort: Integer;
  const AConfig: THorseCrossSocketConfig);
var
  LNghttp2Config: THorseNghttp2Config;
begin
  // Translate the shared cross-provider config to nghttp2's own record.
  LNghttp2Config      := THorseNghttp2Config.Default;
  LNghttp2Config.Port := Word(APort);

  // Pool sizing, most specific source first.
  //
  // The WorkerThreads class property wins outright, and is the only way to
  // ask for inline dispatch — IoThreads cannot express it, since 0 already
  // means "pick for me" in the shared config.
  //
  // Otherwise IoThreads sizes the pool, its documented meaning carrying over:
  // 0 gives one worker per core, which suits CPU-bound routes. Raise it well
  // above core count for routes that mostly wait on a database or an upstream
  // service — those threads are parked, not burning CPU.
  if FWorkerThreads < 0 then
    LNghttp2Config.WorkerThreads := 0            // inline; no pool built
  else if FWorkerThreads > 0 then
    LNghttp2Config.WorkerThreads := FWorkerThreads
  else if AConfig.IoThreads > 0 then
    LNghttp2Config.WorkerThreads := AConfig.IoThreads
  else
    LNghttp2Config.WorkerThreads := TThread.ProcessorCount;

  // Each connection costs a thread in this transport — unless the event loop
  // is driving, where it costs a descriptor and a pump — so the shared
  // ceiling is a real limit here rather than a formality.
  if AConfig.MaxConnections > 0 then
    LNghttp2Config.MaxConnections := AConfig.MaxConnections;

  { Opt in to the event-loop driver. Requesting it is not the same as getting
    it: Nghttp2.Server only uses an engine that registered itself, so on
    Windows, on macOS, or in any build that does not link
    Nghttp2.Engine.Epoll, this degrades quietly to the thread driver rather
    than failing to start. }
  LNghttp2Config.UseEventLoop  := FUseEventLoop;
  LNghttp2Config.EngineThreads := FEngineThreads;

  // TLS: if the caller set SSLEnabled with a cert + key path, build a
  // TTlsServerContext and hand it to the nghttp2 server via InternalListen.
  // FTls is freed in StopListen. v1 supports only cert+key; SSLKeyPassword,
  // SSLCACertFile (CA), and SSLVerifyPeer (mTLS) are v1.1 refinements.
  if AConfig.SSLEnabled then
  begin
    if (AConfig.SSLCertFile = '') or (AConfig.SSLKeyFile = '') then
      raise EHorseException.Create(
        'HORSE_PROVIDER_NGHTTP2: SSLEnabled requires both SSLCertFile and SSLKeyFile');

    if FTls = nil then
    begin
      FTls := TTlsServerContext.Create;
      // Password MUST be set before LoadPrivateKeyFile — the callback fires
      // synchronously during that load. Empty string = unencrypted key,
      // callback returns 0 and OpenSSL proceeds without prompting.
      if AConfig.SSLKeyPassword <> '' then
        FTls.SetPrivateKeyPassword(AConfig.SSLKeyPassword);
      FTls.LoadCertificateFile(AConfig.SSLCertFile);
      FTls.LoadPrivateKeyFile(AConfig.SSLKeyFile);
      FTls.CheckKeyMatch;
      FTls.EnableHttp2Alpn;

      // mTLS — if the caller set SSLCACertFile AND SSLVerifyPeer, load the CA
      // and require every client to present a cert signed by it. Setting only
      // SSLCACertFile without SSLVerifyPeer is a no-op (would import trust
      // roots but never actually check the client), and the reverse is
      // meaningless (verify against WHAT?) — so both must be set together.
      if AConfig.SSLVerifyPeer and (AConfig.SSLCACertFile <> '') then
        FTls.EnableClientCertVerification(AConfig.SSLCACertFile);
    end;
  end;

  InternalListen(APort, LNghttp2Config);
end;

// ─── Stop / StopListenGraceful ───────────────────────────────────────────

class procedure THorseProviderNghttp2.StopListen;
begin
  // Framework contract (3)
  TriggerBeforeStop;

  FRunning := False;

  if FServer <> nil then
  begin
    FServer.Stop;
    FreeAndNil(FServer);
  end;

  // After the server: connection threads wait on their in-flight workers
  // during teardown, so the pool has to still be running while they do.
  if FWorkerPool <> nil then
    FreeAndNil(FWorkerPool);

  // Free the TLS context after the server has stopped — the server held a
  // non-owning reference to it, so it's now safe to release. Nil check
  // covers the h2c case where FTls was never built.
  if FTls <> nil then
    FreeAndNil(FTls);

  if FStopEvent <> nil then
    FStopEvent.SetEvent;

  DoOnStopListen;
end;

// Framework contract (4): coordinated drain honouring the caller's timeout.
class procedure THorseProviderNghttp2.StopListenGraceful(const ATimeoutMS: Integer);
var
  LDeadline: TDateTime;
  LDiag:     Boolean;      // DRAIN-DIAG-1
  LStarted:  TDateTime;
begin
  TriggerBeforeStop;

  { Publish the draining state for the whole window, exactly as
    THorseProviderAbstract.StopListenGraceful does. This override replaces the
    base wholesale, so without this the flag would never be raised on the
    nghttp2 path and THorse.IsShuttingDown would read False throughout a
    drain — telling a /health probe the server is ready to receive while it is
    in the middle of refusing connections and shutting down. That is the exact
    signal Kubernetes and load balancers read to take a pod out of rotation
    (horse/.agents/AGENTS.md, "Server Lifecycle & Graceful Shutdown").
    Cleared in the finally to match the base contract: the flag marks the
    shutdown window, not the terminal state. }
  THorseCore.SetIsShuttingDown(True);
  try
    if FServer <> nil then
    begin
      // Refuse-accept immediately; existing connections keep serving.
      FServer.StopAcceptingNewConnections;

      // Poll until either the drain completes or the caller's deadline elapses.
      // 20 ms poll interval — same as the CrossSocket reference (SEC-30).
      //
      // Both conditions are required. ActiveRequests alone is not a drain:
      // a worker retires that counter as its handler returns, which is before
      // the response has been submitted to nghttp2 and before its bytes have
      // reached the socket. Waiting on it alone means the force-close below
      // lands while replies are still queued — severing requests whose
      // handlers had already completed, which is the one thing a graceful
      // shutdown must never do. AllConnectionsIdle closes that gap by waiting
      // for every connection to have nothing left to submit or write.
      LDeadline := IncMilliSecond(Now, ATimeoutMS);

      { DRAIN-DIAG-1: bracket the wait loop. The per-connection timeline comes
        from the pumps themselves (Nghttp2.Server, TNghttp2ConnectionThread);
        these two lines say what the DRAIN believed at the only two instants
        that decide whether a reply survives — when it started waiting, and
        the moment before it force-closes.

        Added after three separate hypotheses about this drain each looked
        right and each turned out wrong, every one of them inferred from
        aggregate timings rather than observed state. }
      LDiag    := FServer.DrainDiagnostics;
      LStarted := Now;
      if LDiag then
        DrainLog(Format('[drain] %s enter: active=%d allIdle=%s timeout=%d ms',
          [FormatDateTime('hh:nn:ss.zzz', Now),
           FServer.ActiveRequests,
           BoolToStr(FServer.AllConnectionsIdle, True), ATimeoutMS]));

      while ((FServer.ActiveRequests > 0) or (not FServer.AllConnectionsIdle))
            and (Now < LDeadline) do
        Sleep(20);

      if LDiag then
        DrainLog(Format('[drain] %s exit after %d ms: active=%d allIdle=%s '
          + 'deadlineHit=%s -> ForceCloseAllConnections',
          [FormatDateTime('hh:nn:ss.zzz', Now),
           MilliSecondsBetween(Now, LStarted),
           FServer.ActiveRequests,
           BoolToStr(FServer.AllConnectionsIdle, True),
           BoolToStr(Now >= LDeadline, True)]));

      { FIX-DRAIN-RST-3 (2026-08-19). Force-close ONLY when the deadline was
        actually hit.

        STRACE, case A, a failing run — two threads tearing down one socket:

          183855  05.241165  shutdown(4, SHUT_WR)   = 0   <- connection thread
          183820  05.242928  shutdown(4, SHUT_RDWR) = 0   <- THIS call, 1.8 ms later
          183820  05.243093  close(4)               = 0
          183855  05.243167  close(4) = -1 EBADF          <- fd gone underneath it

        The connection thread had written the full response and was lingering
        for the peer's FIN. This call reached in mid-linger, RST'd the socket
        and destroyed the reply — then the owning thread's own close returned
        EBADF, which is a use-after-close on top of the data loss.

        It is also redundant. FServer.Stop already raises FStopping, gives
        every pump FAREWELL_TIMEOUT_MS to retire itself (so its farewell GOAWAY
        and its graceful close both complete), and force-closes only whatever
        is left. Calling it here pre-empts that entire design.

        This is why FIX-DRAIN-RST-1 and -2 each measured as no change when
        applied alone: BOTH sites destroy the socket, so fixing one leaves the
        other. -2 fixed the connection thread; this fixes the provider. }
      if Now >= LDeadline then
        FServer.ForceCloseAllConnections;
      FServer.Stop;
      FreeAndNil(FServer);
    end;

    // Only after the server: connection threads wait on their in-flight
    // workers during teardown, so the pool must outlive them.
    if FWorkerPool <> nil then
      FreeAndNil(FWorkerPool);

    // Release TLS context after server teardown (same rule as StopListen).
    if FTls <> nil then
      FreeAndNil(FTls);

    FRunning := False;
    if FStopEvent <> nil then
      FStopEvent.SetEvent;

    DoOnStopListen;
  finally
    THorseCore.SetIsShuttingDown(False);
  end;
end;

// ─── Async dispatch ──────────────────────────────────────────────────────

(* One queued request. The worker pool takes `procedure of object` rather than
   anonymous methods — FPC in Delphi mode has no closures without the
   FUNCTIONREFERENCES modeswitch — so the stream reference rides on an object
   instead of in a capture. Self-owned: Run frees it, nothing outlives it. *)
type
  TNghttp2PipelineTask = class
  private
    FStream: INghttp2Stream;
  public
    constructor Create(const AStream: INghttp2Stream);
    procedure Run;
  end;

constructor TNghttp2PipelineTask.Create(const AStream: INghttp2Stream);
begin
  inherited Create;
  FStream := AStream;
end;

procedure TNghttp2PipelineTask.Run;
var
  LStream: INghttp2Stream;
begin
  // Local copy so the interface outlives Self.Free below.
  LStream := FStream;
  try
    THorseProviderNghttp2.ExecutePipeline(LStream);
  finally
    // Both must fire however the pipeline ended. A missed EndAsyncDispatch
    // parks the connection until the peer gives up; a missed
    // DecActiveRequests parks StopListenGraceful for its whole timeout.
    if THorseProviderNghttp2.FServer <> nil then
      THorseProviderNghttp2.FServer.DecActiveRequests;
    LStream.EndAsyncDispatch;
    Free;
  end;
end;

{ Connection-thread callback, once per request. Kept to a registry lookup:
  anything expensive here is paid by every request on every connection, not
  only by streaming ones. }
function ShouldStreamInboundTrampoline(const AStream: INghttp2Stream): Boolean;
var
  LContentType: string;
begin
  Result := False;

  { WS-8441 first: a WebSocket stream is inbound-streaming by definition — its
    read loop consumes frames for the life of the connection, which END_STREAM
    dispatch could never start. Identified by extended CONNECT carrying
    :protocol, per RFC 8441 §4. }
  if THorseProviderNghttp2.EnableWebSocket
     and SameText(AStream.Header[':method'], 'CONNECT')
     and SameText(AStream.Header[':protocol'], 'websocket') then
    Exit(True);

  { Otherwise only gRPC traffic can be inbound-streaming, and the content-type
    test is a string compare against a header already in hand — no dictionary
    lookup for the overwhelming majority of requests. }
  LContentType := AStream.Header['content-type'];
  if not StartsText('application/grpc', LContentType) then Exit;

  Result := THorseGrpc.IsInboundStreaming(AStream.Header[':path']);

end;

procedure ExecutePipelineTrampoline(const AStream: INghttp2Stream);
var
  LTask: TNghttp2PipelineTask;
begin
  // No pool configured — run inline on the connection thread, exactly as
  // before. Every existing deployment that never sets IoThreads lands here.
  if THorseProviderNghttp2.FWorkerPool = nil then
  begin
    if THorseProviderNghttp2.FServer <> nil then
      THorseProviderNghttp2.FServer.IncActiveRequests;
    try
      THorseProviderNghttp2.ExecutePipeline(AStream);
    finally
      if THorseProviderNghttp2.FServer <> nil then
        THorseProviderNghttp2.FServer.DecActiveRequests;
    end;
    Exit;
  end;

  // Claim both counters BEFORE handing the stream over. Doing it inside the
  // worker would race the pump, which could observe zero pending work and
  // retire the connection while this request is still queued.
  if THorseProviderNghttp2.FServer <> nil then
    THorseProviderNghttp2.FServer.IncActiveRequests;
  AStream.BeginAsyncDispatch;

  LTask := TNghttp2PipelineTask.Create(AStream);
  if THorseProviderNghttp2.FWorkerPool.Submit(LTask.Run) then
    Exit;

  { Queue full. FALLBACK-1: run it here rather than refusing it, provided few
    enough threads are already doing so.

    LTask.Run is called directly instead of being re-implemented: it already
    performs ExecutePipeline, DecActiveRequests, EndAsyncDispatch and Free, in
    that order. Duplicating that sequence here is how a missed
    EndAsyncDispatch parks a connection until the peer gives up. }
  if THorseProviderNghttp2.TryClaimInlineSlot then
  begin
    TInterlocked.Increment(THorseProviderNghttp2.FInlineFallbacks);
    try
      LTask.Run;
    finally
      THorseProviderNghttp2.ReleaseInlineSlot;
    end;
    Exit;
  end;

  // Cap reached — enough threads are already blocked in handlers, and taking
  // another out of the read loop risks stalling the engine outright. Shed
  // instead: 503 + Retry-After is the honest answer, and the request was
  // never started.
  LTask.Free;
  AStream.EndAsyncDispatch;
  if THorseProviderNghttp2.FServer <> nil then
    THorseProviderNghttp2.FServer.DecActiveRequests;

  { OBSERV-1: count it, and say so ONCE. Before this the shed was invisible
    server-side — correct behaviour with no evidence it had occurred.

    One line, not one per shed: this fires under saturation, so logging every
    occurrence would add I/O on the exact path that is already overloaded and
    would bury the signal in its own noise. The counter carries the magnitude;
    the line only has to tell an operator where to look. }
  TInterlocked.Increment(THorseProviderNghttp2.FSheddedRequests);
  if IsConsole and (TInterlocked.CompareExchange(
       THorseProviderNghttp2.FSheddedLogged, 1, 0) = 0) then
    Writeln('[nghttp2] dispatch queue full and inline fallback at capacity — '
      + 'shedding with 503. Counters: SheddedRequests (refused) and '
      + 'InlineFallbacks (rescued). Levers: MaxInlineFallback (more threads '
      + 'may absorb overflow, at the cost of tail latency), WorkerThreads, or '
      + 'WORKER_THREADS_INLINE. This line prints once.');

  AStream.Header['retry-after'] := '1';
  THorseProviderNghttp2.SendError(AStream, 503, 'Service Unavailable: server busy');
end;

end.
