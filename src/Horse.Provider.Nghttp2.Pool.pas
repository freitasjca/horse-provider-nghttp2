unit Horse.Provider.Nghttp2.Pool;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Pool
//  Pre-warmed pool of THorseContext (=THorseRequest + THorseResponse pairs).
//
//  Acquire → hot request; Release → Reset + return to pool.
//
//  CRITICAL — non-owning body rule (FIX-POOL-1 / PATCH-REQ-11):
//    THorseRequest.FBody, on the nghttp2 path, is a stream owned by the
//    Session's TNghttp2StreamState. It is registered with Body(stream, False)
//    in the Request bridge. Reset MUST call FRequest.Clear (which sets
//    FBody := nil without Free) — NOT FRequest.Body(nil), which would free
//    the transport-owned stream and crash on the next request.
//
//  Same singleton pattern as horse-provider-crosssocket. Singleton is
//  intentional: contexts are stateless after Reset, so sharing across
//  THorseInstance instances is safe. (The AGENTS.md Multi-Instance rule
//  targets provider *configuration* state, not stateless pools.)
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
{$IFEND}
  Horse;

type
  THorseContext = class
  private
    FRequest:  THorseRequest;
    FResponse: THorseResponse;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure   Reset;
    property Request:  THorseRequest  read FRequest;
    property Response: THorseResponse read FResponse;
  end;

  THorseContextPool = class
  private
    class var FInstance: THorseContextPool;
    FPool: TStack<THorseContext>;
    FLock: TCriticalSection;
    procedure PrewarmPool(ACount: Integer);
  public
    class function  Instance: THorseContextPool; static;
    class procedure ReleaseInstance; static;

    constructor Create(APrewarmCount: Integer = 16);
    destructor  Destroy; override;

    function  Acquire: THorseContext;
    procedure Release(AContext: THorseContext);
  end;

implementation

// ============================================================================
// THorseContext
// ============================================================================

constructor THorseContext.Create;
begin
  inherited Create;
  // THorseRequest has a parameterless overload (upstream 3.3.0) — FWebRequest
  // stays nil; the CrossSocket-style shadow fields carry the request data.
  FRequest := THorseRequest.Create;
  // THorseResponse has no parameterless overload. Pass nil for AWebResponse
  // and let the request bridge (SetCSRawWebResponse) supply a real
  // TWebResponse before the pipeline runs. Matches the CrossSocket pool
  // pattern (Horse.Provider.CrossSocket.Pool.pas).
  FResponse := THorseResponse.Create(nil);
end;

destructor THorseContext.Destroy;
begin
  // NEVER call FRequest.Body(nil) here — it would free a non-owning
  // stream. FRequest.Free itself is safe: THorseRequest.Destroy respects
  // the AOwnsBody flag set by Body(stream, False).
  FResponse.Free;
  FRequest.Free;
  inherited;
end;

procedure THorseContext.Reset;
begin
  // Clear (NOT Body(nil)) is the only safe path for a non-owning body.
  FRequest.Clear;
  FResponse.Clear;
end;

// ============================================================================
// THorseContextPool
// ============================================================================

constructor THorseContextPool.Create(APrewarmCount: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FPool := TStack<THorseContext>.Create;
  if APrewarmCount > 0 then
    PrewarmPool(APrewarmCount);
end;

destructor THorseContextPool.Destroy;
var
  LCtx: THorseContext;
begin
  FLock.Enter;
  try
    while FPool.Count > 0 do
    begin
      LCtx := FPool.Pop;
      LCtx.Free;
    end;
  finally
    FLock.Leave;
  end;
  FPool.Free;
  FLock.Free;
  inherited;
end;

procedure THorseContextPool.PrewarmPool(ACount: Integer);
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 1 to ACount do
      FPool.Push(THorseContext.Create);
  finally
    FLock.Leave;
  end;
end;

function THorseContextPool.Acquire: THorseContext;
begin
  FLock.Enter;
  try
    if FPool.Count > 0 then
      Result := FPool.Pop
    else
      Result := THorseContext.Create;
  finally
    FLock.Leave;
  end;
end;

procedure THorseContextPool.Release(AContext: THorseContext);
begin
  if AContext = nil then Exit;
  AContext.Reset;
  FLock.Enter;
  try
    FPool.Push(AContext);
  finally
    FLock.Leave;
  end;
end;

// ─── Singleton accessor ──────────────────────────────────────────────────

class function THorseContextPool.Instance: THorseContextPool;
begin
  if FInstance = nil then
    FInstance := THorseContextPool.Create;
  Result := FInstance;
end;

class procedure THorseContextPool.ReleaseInstance;
begin
  if FInstance <> nil then
  begin
    FInstance.Free;
    FInstance := nil;
  end;
end;

initialization

finalization
  THorseContextPool.ReleaseInstance;

end.
