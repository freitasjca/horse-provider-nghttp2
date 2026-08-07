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
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.DateUtils,
{$IFEND}
  Horse.Exception,
  Horse.Provider.Abstract,
  Horse.Provider.Config,
  Nghttp2.Server,
  Nghttp2.Types,
  Nghttp2.Tls;    { for TTlsServerContext — used in the FTls class var declaration below }

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
  end;

implementation

uses
  Horse,
  Horse.Commons,
  Horse.Exception.Interrupted,
  Horse.Provider.Nghttp2.Pool,
  Horse.Provider.Nghttp2.Request,
  Horse.Provider.Nghttp2.Response,
  Horse.Provider.Nghttp2.WebResponseAdapter,
  Horse.Provider.Nghttp2.Grpc.Dispatcher,   { M4a: intercept application/grpc* before Horse routing }
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

// ============================================================================
// THorseProviderNghttp2
// ============================================================================

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
  // send an error directly and skip the pool entirely — no context
  // allocated, no request-in-flight counter bump.
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

  // SEC-30 counter: increment on entry to the accepted-request path (past
  // validation), decrement in finally. Wraps the whole pipeline scope so
  // StopListenGraceful's drain sees a truthful in-flight count. Only bumped
  // when we're actually going to execute — validation failures above don't
  // count as in-flight.
  if FServer <> nil then
    FServer.IncActiveRequests;
  try

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

  finally
    if FServer <> nil then
      FServer.DecActiveRequests;
  end;
end;

// ─── Listen / ListenWithConfig ───────────────────────────────────────────

class procedure THorseProviderNghttp2.InternalListen(APort: Integer;
  const AConfig: THorseNghttp2Config);
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

  FServer := TNghttp2Server.Create;
  FServer.OnRequest := ExecutePipelineTrampoline;
  // Hand the TLS context to the server (or nil for h2c). The server holds a
  // non-owning reference — FTls stays owned by the provider until StopListen.
  FServer.TlsContext := FTls;
  FPort := APort;
  FServer.Start(AConfig);

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

class procedure THorseProviderNghttp2.ListenWithConfig(const APort: Integer;
  const AConfig: THorseCrossSocketConfig);
var
  LNghttp2Config: THorseNghttp2Config;
begin
  // Translate the shared cross-provider config to nghttp2's own record.
  LNghttp2Config      := THorseNghttp2Config.Default;
  LNghttp2Config.Port := Word(APort);

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
begin
  TriggerBeforeStop;

  if FServer <> nil then
  begin
    // Refuse-accept immediately; existing connections keep serving.
    FServer.StopAcceptingNewConnections;

    // Poll until either the drain completes or the caller's deadline elapses.
    // 20 ms poll interval — same as the CrossSocket reference (SEC-30).
    LDeadline := IncMilliSecond(Now, ATimeoutMS);
    while (FServer.ActiveRequests > 0) and (Now < LDeadline) do
      Sleep(20);

    // Hard cutoff for anything still in-flight past the deadline.
    FServer.ForceCloseAllConnections;
    FServer.Stop;
    FreeAndNil(FServer);
  end;

  // Release TLS context after server teardown (same rule as StopListen).
  if FTls <> nil then
    FreeAndNil(FTls);

  FRunning := False;
  if FStopEvent <> nil then
    FStopEvent.SetEvent;

  DoOnStopListen;
end;

// ─── Trampoline (see forward decl above) ─────────────────────────────────

procedure ExecutePipelineTrampoline(const AStream: INghttp2Stream);
begin
  THorseProviderNghttp2.ExecutePipeline(AStream);
end;

end.
