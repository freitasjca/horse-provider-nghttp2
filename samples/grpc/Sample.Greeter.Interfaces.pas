unit Sample.Greeter.Interfaces;

// ============================================================================
//  Sample.Greeter.Interfaces — IInvokable service interface for the M4c demo.
//
//  RTTI rules per horse-grpc SKILL §2 + delphi-standards:
//    - {$M+} unit-wide so the interface carries classic RTTI
//    - Interface must derive from IInvokable (required for TRttiMethod.Invoke)
//    - Interface must carry `[TGrpcService('<package>.<Service>')]`
//    - Every method must have the shape:
//        function <Name>(const ARequest: TSomeRequest): TSomeResponse;
//      (single class parameter, class return type — dispatcher extracts both
//      via RTTI to look up protobuf serialisers)
//    - GUID required — Delphi RTTI needs it for interface method dispatch
// ============================================================================

{$M+}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

// FPC needs the explicit extended-RTTI directive alongside {$M+} — otherwise
// TRttiInterfaceType.GetAttributes and .GetDeclaredMethods both come back
// EMPTY and RegisterService<T> either raises "lacks a [TGrpcService]
// attribute" or silently registers zero methods (every call then answers
// UNIMPLEMENTED). Same rule already applied in Sample.Greeter.Messages.pas;
// see delphi-fpc-compat. Directive must live INSIDE `interface`, not above
// it (FPC rejects it at unit scope).
{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

uses
  Horse.Provider.Nghttp2.Grpc.Attributes,   { TGrpcServiceAttribute }
  Sample.Greeter.Messages;                  { message classes }

type
  [TGrpcService('greeter.Greeter')]
  IGreeter = interface(IInvokable)
    ['{6A9C4E8B-3D1F-4B2A-9F5E-7C8D2E4A1B33}']
    function Greet(const ARequest: TGreetRequest): TGreetResponse;
    function Echo (const ARequest: TEchoRequest):  TEchoResponse;
  end;

implementation

end.
