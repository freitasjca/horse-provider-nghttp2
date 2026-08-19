unit Horse.Provider.Nghttp2.Grpc.Registry;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.Registry
//  Process-wide registry of gRPC methods → handler dispatch info.
//  M4a of the horse-provider-nghttp2 gRPC plan (2026-08-07).
//  M4c ergonomic layer added 2026-08-09 — RegisterService<T> generic.
//
//  Two registration styles, both routed to the same internal storage:
//
//  1. **Procedural (M4a)** — `THorseGrpc.RegisterMethod(path, ReqClass,
//     RespClass, handler)` — explicit per-method registration with a
//     `procedure(AReq, AResp: TObject) of object` handler that mutates the
//     dispatcher-created response instance. Backward-compatible; no ARC
//     gymnastics; works on Delphi + FPC.
//
//  2. **IInvokable (M4c)** — `THorseGrpc.RegisterService<IGreeter>(impl)` —
//     walks the interface via RTTI, extracts path from `[TGrpcService]`
//     attribute + method name, extracts request/response classes from
//     method signature, and wires each method through
//     `TGrpcInvokableWrapper` (owned by the registry, freed at Shutdown).
//     User's methods RETURN the response instance (dispatcher frees it).
//     Requires `_AddRef`/`_Release` = -1 on the impl class — see
//     horse-grpc SKILL §2.
//
//  Path convention (both styles): `/<PackageName>.<ServiceName>/<MethodName>`
//  per the gRPC-over-HTTP/2 spec. Case-sensitive, no normalization.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Rtti, TypInfo, Generics.Collections
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Rtti,
  System.TypInfo, System.Generics.Collections
{$IFEND}
  ,Horse.Provider.Nghttp2.Grpc.Attributes;

type
  { Signature of a gRPC method handler (M4a procedural path).
    - ARequest is a fresh instance of the registered request class,
      populated by the dispatcher from the deserialised protobuf body.
    - AResponse is a fresh instance of the registered response class;
      the handler populates its properties.
    Ownership: dispatcher creates + frees BOTH — handler MUST NOT free
    either. Handler may raise; dispatcher catches and returns
    grpc-status 13 (INTERNAL) with the exception message. }
  TGrpcHandler = procedure(const ARequest: TObject; const AResponse: TObject) of object;

  { Signature of a gRPC invoke callback (M4c interface path).
    - ARequest is a fresh instance of the request class (populated).
    - Return value is a NEW response instance the callback allocates.
      Dispatcher frees it after serialising to protobuf.
    Ownership: dispatcher frees the returned response. }
  TGrpcInvokeMethod = function(const ARequest: TObject): TObject of object;

  TGrpcMethodInfo = record
    Path:          string;
    RequestClass:  TClass;
    ResponseClass: TClass;
    Handler:       TGrpcHandler;       // set for procedural M4a path
    InvokeMethod:  TGrpcInvokeMethod;  // set for IInvokable M4c path (mutually exclusive with Handler)
  end;

  EHorseGrpcRegistry = class(Exception);

  { Internal — one wrapper instance per registered interface method.
    Holds a strong ref to the service interface (which has ARC disabled
    per horse-grpc SKILL §2) and the TRttiMethod for invocation.
    Owned by THorseGrpc.FWrappers, freed on Shutdown.

    GENERIC IN T ON PURPOSE — do not "simplify" this back to a plain
    `FIntf: IInterface` field. Erasing the interface type before building
    the instance TValue makes TRttiMethod.Invoke fail on FPC with

        expected IGreeter, but got IUnknown

    because the method's hidden Self parameter is typed to the DECLARING
    interface, and Invoke VALIDATES the TValue's type info — it does not
    merely dispatch through the vtable. Delphi tolerates the erased form;
    FPC does not. Diagnosed 2026-08-12, gRPC FPC Phase 2.

    Each specialisation is a distinct class with no common ancestor beyond
    TObject, so FWrappers is a TObjectList<TObject> — the list only owns
    lifetimes, it never calls back in. }
  TGrpcInvokableWrapper<T: IInvokable> = class
  strict private
    FIntf:   T;
    FMethod: TRttiMethod;
  public
    constructor Create(const AIntf: T; const AMethod: TRttiMethod);
    { The `of object` method-pointer matching TGrpcInvokeMethod. }
    function Invoke(const ARequest: TObject): TObject;
  end;

  { Process-wide singleton via class methods + class vars.
    Same shape as THorseProtobufRtti (see Nghttp2.Protobuf.Rtti.pas). }
  THorseGrpc = class
  strict private
    class var FRegistry: TDictionary<string, TGrpcMethodInfo>;
    class var FWrappers: TObjectList<TObject>;   // holds TGrpcInvokableWrapper<T> of assorted T
    class var FLock:     TCriticalSection;
    class var FReady:    Boolean;
    { Process-lifetime RTTI context — horse-grpc SKILL §3 "RTTI Context
      Lifetime". MUST NOT be a local in RegisterService: the TRttiMethod
      handed to each wrapper is owned by the context's pool and is used on
      every later dispatch, so a local context freed at the end of
      registration leaves every FMethod dangling. Same shape as
      THorseProtobufRtti.FContext. }
    class var FCtx:      TRttiContext;
    class procedure LazyInit;
    { Internal — invariant checks + insertion under the already-held lock.
      Used by both RegisterMethod (with Handler) and RegisterService<T>
      (with InvokeMethod). Caller must hold FLock. }
    class procedure InsertLocked(const AInfo: TGrpcMethodInfo);
  public
    { M4a — Register a single method with a procedural handler. Called once
      at startup per method. Raises EHorseGrpcRegistry on invalid input
      (nil handler, non-slash-prefixed path, duplicate registration).

      Example:
        THorseGrpc.RegisterMethod(
          '/users.UserService/GetUser',
          TUserRequest, TUserResponse,
          FUserServiceInstance.GetUser); }
    class procedure RegisterMethod(
      const APath:      string;
      ARequestClass:    TClass;
      AResponseClass:   TClass;
      AHandler:         TGrpcHandler);

    { M4c — Register a whole service interface. Walks TypeInfo(T) via RTTI:
      reads [TGrpcService('name')] attribute for the service name, walks
      each declared method, extracts request class from its single
      `const ARequest: TFoo` parameter, extracts response class from the
      return type, and registers each as `/<Name>/<MethodName>`.

      T must derive from IInvokable and carry [TGrpcService(...)]. AImpl is
      the concrete implementation; the registry holds an interface reference
      so ARC is engaged — override `_AddRef`/`_Release` to return -1 on the
      impl to prevent auto-destruction during dispatch (horse-grpc SKILL §2).

      Example:
        THorseGrpc.RegisterService<IGreeter>(TGreeterServiceImpl.Create);

      Raises EHorseGrpcRegistry on invalid input (missing attribute, bad
      method signature, duplicate path). Partial registration is possible
      if failure occurs mid-walk — call Shutdown then re-register. }
    class procedure RegisterService<T: IInvokable>(const AImpl: T);

    { Registry lookup. Returns True + populates AInfo when found;
      False otherwise. Thread-safe. }
    class function TryGet(const APath: string; out AInfo: TGrpcMethodInfo): Boolean;

    { Count of currently-registered methods (for diagnostics). }
    class function Count: Integer;

    { Explicit shutdown — rarely needed; finalization does this too. }
    class procedure Shutdown;
  end;

implementation

{$IF DEFINED(FPC) AND NOT DEFINED(HORSE_GRPC_NO_FFI)}
uses
  { Imported for its INITIALIZATION SIDE EFFECT ONLY — nothing here calls
    into it. FPC ships no built-in function-call manager, so a bare
    TRttiMethod.Invoke fails at run time with:

      ENotImplemented: Invoke functionality is not implemented on this
      platform. Use external managers, e.g. ffi.manager.

    ffi.manager (FPC package libffi) registers a libffi-backed manager in
    its initialization section, which is what makes Invoke work. Delphi
    needs none of this — its Invoke is native.

    Build requirements on FPC:
      - add  -Fu<fpc-units>/libffi  to the compile line
      - libffi present at run time (Ubuntu: libffi8; Windows: libffi.dll)

    Escape hatch: define HORSE_GRPC_NO_FFI to drop the dependency. The M4a
    procedural API (RegisterMethod) keeps working — it never touches RTTI
    invoke — but RegisterService<T> will then fail with the ENotImplemented
    above on first call. }
  ffi.manager;
{$IFEND}

// ── TGrpcInvokableWrapper ────────────────────────────────────────────────

constructor TGrpcInvokableWrapper<T>.Create(const AIntf: T; const AMethod: TRttiMethod);
begin
  inherited Create;
  FIntf   := AIntf;
  FMethod := AMethod;
end;

function TGrpcInvokableWrapper<T>.Invoke(const ARequest: TObject): TObject;
var
  LArgs:   array of TValue;
  LResult: TValue;
begin
  SetLength(LArgs, 1);
  LArgs[0] := TValue.From<TObject>(ARequest);

  { Invoke on the interface reference — RTTI dispatches through the vtable.
    `_AddRef`/`_Release` returning -1 on the impl prevents ARC from
    destroying the service instance mid-dispatch (horse-grpc SKILL §2).
    TValue.From<T> (not <IInterface>) keeps the declaring interface's type
    info on the instance value — FPC's invoke path needs it. }
  LResult := FMethod.Invoke(TValue.From<T>(FIntf), LArgs);

  if LResult.IsEmpty or not LResult.IsObject then
    raise EHorseGrpcRegistry.CreateFmt(
      'RegisterService: method %s did not return a TObject instance',
      [FMethod.Name]);

  Result := LResult.AsObject;
end;

// ── THorseGrpc ────────────────────────────────────────────────────────────

class procedure THorseGrpc.LazyInit;
begin
  if FReady then Exit;
  if FLock = nil then
    FLock := TCriticalSection.Create;
  FLock.Enter;
  try
    if FReady then Exit;
    FRegistry := TDictionary<string, TGrpcMethodInfo>.Create;
    FWrappers := TObjectList<TObject>.Create({AOwnsObjects=}True);
    FReady := True;
  finally
    FLock.Leave;
  end;
end;

class procedure THorseGrpc.Shutdown;
begin
  if not FReady then Exit;
  FLock.Enter;
  try
    if not FReady then Exit;
    FRegistry.Free;
    FRegistry := nil;
    FWrappers.Free;   // OwnsObjects=True — frees every wrapper
    FWrappers := nil;
    FCtx.Free;        // releases the RTTI pool token; wrappers are already gone
    FReady := False;
  finally
    FLock.Leave;
  end;
  FLock.Free;
  FLock := nil;
end;

class procedure THorseGrpc.InsertLocked(const AInfo: TGrpcMethodInfo);
begin
  if FRegistry.ContainsKey(AInfo.Path) then
    raise EHorseGrpcRegistry.CreateFmt(
      'RegisterMethod: %s already registered — duplicate registration', [AInfo.Path]);
  FRegistry.Add(AInfo.Path, AInfo);
end;

class procedure THorseGrpc.RegisterMethod(
  const APath:    string;
  ARequestClass:  TClass;
  AResponseClass: TClass;
  AHandler:       TGrpcHandler);
var
  LInfo: TGrpcMethodInfo;
begin
  if APath = '' then
    raise EHorseGrpcRegistry.Create('RegisterMethod: APath cannot be empty');
  if (Length(APath) < 2) or (APath[1] <> '/') then
    raise EHorseGrpcRegistry.CreateFmt(
      'RegisterMethod: APath %s must start with "/" and follow /<Service>/<Method> form',
      [APath]);
  if ARequestClass = nil then
    raise EHorseGrpcRegistry.CreateFmt('RegisterMethod(%s): ARequestClass is nil', [APath]);
  if AResponseClass = nil then
    raise EHorseGrpcRegistry.CreateFmt('RegisterMethod(%s): AResponseClass is nil', [APath]);
  if not Assigned(AHandler) then
    raise EHorseGrpcRegistry.CreateFmt('RegisterMethod(%s): AHandler is nil', [APath]);

  LazyInit;
  FLock.Enter;
  try
    LInfo.Path          := APath;
    LInfo.RequestClass  := ARequestClass;
    LInfo.ResponseClass := AResponseClass;
    LInfo.Handler       := AHandler;
    LInfo.InvokeMethod  := nil;
    InsertLocked(LInfo);
  finally
    FLock.Leave;
  end;
end;

class procedure THorseGrpc.RegisterService<T>(const AImpl: T);
var
  LIntfType:  TRttiInterfaceType;
  LMethods:   TArray<TRttiMethod>;
  LMethod:    TRttiMethod;
  LParams:    TArray<TRttiParameter>;
  LAttr:      TCustomAttribute;
  LSvcName:   string;
  LReqClass:  TClass;
  LRespClass: TClass;
  LWrapper:   TGrpcInvokableWrapper<T>;
  LInfo:      TGrpcMethodInfo;
begin
  if TypeInfo(T) = nil then
    raise EHorseGrpcRegistry.Create(
      'RegisterService<T>: no RTTI for T (compile with {$M+} on the interface unit)');

  LazyInit;

  { `as TRttiInterfaceType` raises EInvalidCast if T isn't an interface —
    no need for a separate nil check. }
  LIntfType := FCtx.GetType(TypeInfo(T)) as TRttiInterfaceType;

  { Locate [TGrpcService('...')] on the interface. Direct `is` test against
    the attribute class — the unit is already in our uses clause, so the
    earlier ClassName-string + RTTI-property dance bought nothing. }
  LSvcName := '';
  for LAttr in LIntfType.GetAttributes do
    if LAttr is TGrpcServiceAttribute then
    begin
      LSvcName := TGrpcServiceAttribute(LAttr).Name;
      Break;
    end;

  if LSvcName = '' then
    raise EHorseGrpcRegistry.CreateFmt(
      'RegisterService<T>: interface %s lacks a [TGrpcService(''name'')] attribute ' +
      '(on FPC, also check the unit declaring it carries the {$RTTI EXPLICIT ...} directive)',
      [LIntfType.Name]);

  { A service interface with zero visible methods means the RTTI directive
    is missing on the declaring unit — fail loudly instead of registering
    nothing and answering UNIMPLEMENTED to every call at run time. }
  LMethods := LIntfType.GetDeclaredMethods;
  if Length(LMethods) = 0 then
    raise EHorseGrpcRegistry.CreateFmt(
      'RegisterService<T>: interface %s exposes no methods via RTTI — ' +
      'declare it in a unit with {$M+} (and, on FPC, {$RTTI EXPLICIT METHODS([vcPublic])})',
      [LIntfType.Name]);

  for LMethod in LMethods do
  begin
    { Signature validation — exactly one class parameter + class return type. }
    LParams := LMethod.GetParameters;
    if Length(LParams) <> 1 then
      raise EHorseGrpcRegistry.CreateFmt(
        'RegisterService(%s.%s): expected 1 parameter, got %d — must be `function %s(const ARequest: TRequestClass): TResponseClass`',
        [LIntfType.Name, LMethod.Name, Length(LParams), LMethod.Name]);
    if (LParams[0].ParamType = nil) or (LParams[0].ParamType.TypeKind <> tkClass) then
      raise EHorseGrpcRegistry.CreateFmt(
        'RegisterService(%s.%s): parameter must be a TObject subclass',
        [LIntfType.Name, LMethod.Name]);
    if (LMethod.ReturnType = nil) or (LMethod.ReturnType.TypeKind <> tkClass) then
      raise EHorseGrpcRegistry.CreateFmt(
        'RegisterService(%s.%s): return type must be a TObject subclass',
        [LIntfType.Name, LMethod.Name]);

    LReqClass  := (LParams[0].ParamType as TRttiInstanceType).MetaclassType;
    LRespClass := (LMethod.ReturnType   as TRttiInstanceType).MetaclassType;

    LWrapper := TGrpcInvokableWrapper<T>.Create(AImpl, LMethod);
    FLock.Enter;
    try
      FWrappers.Add(LWrapper);   { Registry owns; freed on Shutdown }
    finally
      FLock.Leave;
    end;

    LInfo.Path          := '/' + LSvcName + '/' + LMethod.Name;
    LInfo.RequestClass  := LReqClass;
    LInfo.ResponseClass := LRespClass;
    LInfo.Handler       := nil;
    LInfo.InvokeMethod  := LWrapper.Invoke;

    FLock.Enter;
    try
      InsertLocked(LInfo);
    finally
      FLock.Leave;
    end;
  end;
end;

class function THorseGrpc.TryGet(const APath: string; out AInfo: TGrpcMethodInfo): Boolean;
begin
  if not FReady then Exit(False);
  FLock.Enter;
  try
    Result := FRegistry.TryGetValue(APath, AInfo);
  finally
    FLock.Leave;
  end;
end;

class function THorseGrpc.Count: Integer;
begin
  if not FReady then Exit(0);
  FLock.Enter;
  try
    Result := FRegistry.Count;
  finally
    FLock.Leave;
  end;
end;

initialization
  // FReady starts False by class-var default; LazyInit bootstraps on first use.

finalization
  THorseGrpc.Shutdown;

end.
