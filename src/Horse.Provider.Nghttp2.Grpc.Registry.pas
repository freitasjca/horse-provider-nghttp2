unit Horse.Provider.Nghttp2.Grpc.Registry;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.Registry
//  Process-wide registry of gRPC methods → handler dispatch info.
//  M4a of the horse-provider-nghttp2 gRPC plan (2026-08-07).
//
//  Users register methods once at startup via THorseGrpc.RegisterMethod.
//  The dispatcher (Horse.Grpc.Dispatcher) looks up incoming paths against
//  this registry to find the handler + request/response classes to
//  instantiate for protobuf deserialize/serialize.
//
//  Handler signature is deliberately simple: `procedure(AReq, AResp: TObject) of object`.
//  IInvokable + RTTI service dispatch (per horse-grpc SKILL §2) is a later
//  enhancement; the plain method-pointer form works on BOTH Delphi and FPC
//  and doesn't require ARC gymnastics.
//
//  Path convention: `/<PackageName>.<ServiceName>/<MethodName>` per the
//  gRPC-over-HTTP/2 spec. Case-sensitive, no normalization.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Generics.Collections
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections
{$IFEND}
  ;

type
  { Signature of a gRPC method handler.
    - ARequest is a fresh instance of the registered request class,
      populated by the dispatcher from the deserialised protobuf body.
    - AResponse is a fresh instance of the registered response class;
      the handler populates its properties.
    Ownership: dispatcher creates + frees BOTH — handler MUST NOT free
    either. Handler may raise; dispatcher catches and returns
    grpc-status 13 (INTERNAL) with the exception message. }
  TGrpcHandler = procedure(const ARequest: TObject; const AResponse: TObject) of object;

  TGrpcMethodInfo = record
    Path:          string;
    RequestClass:  TClass;
    ResponseClass: TClass;
    Handler:       TGrpcHandler;
  end;

  EHorseGrpcRegistry = class(Exception);

  { Process-wide singleton via class methods + class vars.
    Same shape as THorseProtobufRtti (see Nghttp2.Protobuf.Rtti.pas). }
  THorseGrpc = class
  strict private
    class var FRegistry: TDictionary<string, TGrpcMethodInfo>;
    class var FLock:     TCriticalSection;
    class var FReady:    Boolean;
    class procedure LazyInit;
  public
    { Register a method. Called once at startup per method (or per service
      × method combination). Raises EHorseGrpcRegistry on invalid input
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

    { Registry lookup. Returns True + populates AInfo when found;
      False otherwise. Thread-safe. }
    class function TryGet(const APath: string; out AInfo: TGrpcMethodInfo): Boolean;

    { Count of currently-registered methods (for diagnostics). }
    class function Count: Integer;

    { Explicit shutdown — rarely needed; finalization does this too. }
    class procedure Shutdown;
  end;

implementation

class procedure THorseGrpc.LazyInit;
begin
  if FReady then Exit;
  if FLock = nil then
    FLock := TCriticalSection.Create;
  FLock.Enter;
  try
    if FReady then Exit;
    FRegistry := TDictionary<string, TGrpcMethodInfo>.Create;
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
    FReady := False;
  finally
    FLock.Leave;
  end;
  FLock.Free;
  FLock := nil;
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
    if FRegistry.ContainsKey(APath) then
      raise EHorseGrpcRegistry.CreateFmt(
        'RegisterMethod: %s already registered — duplicate registration', [APath]);
    LInfo.Path          := APath;
    LInfo.RequestClass  := ARequestClass;
    LInfo.ResponseClass := AResponseClass;
    LInfo.Handler       := AHandler;
    FRegistry.Add(APath, LInfo);
  finally
    FLock.Leave;
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
