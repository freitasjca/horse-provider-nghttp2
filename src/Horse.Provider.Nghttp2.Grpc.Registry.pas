unit Horse.Provider.Nghttp2.Grpc.Registry;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.Registry — COMPATIBILITY SHIM
//
//  The real unit is Nghttp2.Grpc.Registry in Delphi-nghttp2 (>= 1.5.0). The
//  gRPC layer moved there on 2026-08-23 because it never depended on Horse —
//  only its unit name did. This shim exists so 1.4.x code keeps compiling.
//
//  Migration: change `uses Horse.Provider.Nghttp2.Grpc.Registry` to
//  `uses Nghttp2.Grpc.Registry`. Nothing else changes.
//
//  REMOVED IN 2.0.0, together with the THorse* type-name renames that are the
//  other half of this deprecation window. Do not add anything here.
//
//  These are ALIASES, not wrappers, and that is the whole design. An alias
//  denotes the SAME type, so `THorseGrpc.RegisterService<IGreeter>(...)` still
//  reaches the real generic class method, an `except on E: EHorseGrpcRegistry`
//  still catches what the library raises, and an IGrpcStreamWriter obtained
//  here is assignment-compatible with one obtained there. Wrapper classes
//  would have broken all three.
//
//  NOT aliased: TGrpcInvokableWrapper<T>. It is internal — owned by
//  THorseGrpc.FWrappers, never named by callers — and open generics do not
//  alias identically across both compilers. If you were somehow referencing
//  it, use Nghttp2.Grpc.Registry directly.
// ============================================================================

interface

uses
  Nghttp2.Grpc.Registry;

type
  { Handler signatures — see the library unit for the ownership contracts. }
  TGrpcHandler = Nghttp2.Grpc.Registry.TGrpcHandler
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';
  TGrpcInvokeMethod = Nghttp2.Grpc.Registry.TGrpcInvokeMethod
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';
  TGrpcServerStreamHandler = Nghttp2.Grpc.Registry.TGrpcServerStreamHandler
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';
  TGrpcClientStreamHandler = Nghttp2.Grpc.Registry.TGrpcClientStreamHandler
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';
  TGrpcBidiStreamHandler = Nghttp2.Grpc.Registry.TGrpcBidiStreamHandler
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';

  { Streaming handles handed to streaming handlers. }
  IGrpcStreamWriter = Nghttp2.Grpc.Registry.IGrpcStreamWriter
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';
  IGrpcStreamReader = Nghttp2.Grpc.Registry.IGrpcStreamReader
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';

  TGrpcMethodInfo = Nghttp2.Grpc.Registry.TGrpcMethodInfo
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';

  EHorseGrpcRegistry = Nghttp2.Grpc.Registry.EHorseGrpcRegistry
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';

  { The registry itself — RegisterMethod, RegisterService<T>,
    RegisterServerStream, RegisterClientStream, RegisterBidiStream,
    IsInboundStreaming, TryGet, Count, Shutdown. }
  THorseGrpc = Nghttp2.Grpc.Registry.THorseGrpc
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Registry. Removed in 2.0.0.';

implementation

end.
