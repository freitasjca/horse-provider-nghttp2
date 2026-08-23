unit Horse.Provider.Nghttp2.Grpc.Dispatcher;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.Dispatcher — COMPATIBILITY SHIM
//
//  The real unit is Nghttp2.Grpc.Dispatcher in Delphi-nghttp2 (>= 1.5.0). The
//  gRPC layer moved there on 2026-08-23 because it never depended on Horse —
//  only its unit name did. This shim exists so 1.4.x code keeps compiling.
//
//  Migration: change `uses Horse.Provider.Nghttp2.Grpc.Dispatcher` to
//  `uses Nghttp2.Grpc.Dispatcher`. Nothing else changes.
//
//  REMOVED IN 2.0.0, together with the THorse* type-name renames that are the
//  other half of this deprecation window. Do not add anything here.
//
//  Note that Horse.Provider.Nghttp2 itself does NOT go through this shim — it
//  uses the library unit directly. Nothing in the provider depends on these
//  aliases; they exist purely for code outside it.
// ============================================================================

interface

uses
  Nghttp2.Grpc.Dispatcher;

type
  { TryDispatch(AStream): True when the request was application/grpc* and has
    been fully answered — response body plus grpc-status trailer. }
  THorseGrpcDispatcher = Nghttp2.Grpc.Dispatcher.TGrpcDispatcher
    deprecated 'Moved and renamed: use Nghttp2.Grpc.Dispatcher.TGrpcDispatcher. Removed in 2.0.0.';

const
  { Standard gRPC status codes — the subset this dispatcher emits. }
  GRPC_STATUS_OK               = Nghttp2.Grpc.Dispatcher.GRPC_STATUS_OK
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Dispatcher. Removed in 2.0.0.';
  GRPC_STATUS_INVALID_ARGUMENT = Nghttp2.Grpc.Dispatcher.GRPC_STATUS_INVALID_ARGUMENT
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Dispatcher. Removed in 2.0.0.';
  GRPC_STATUS_NOT_FOUND        = Nghttp2.Grpc.Dispatcher.GRPC_STATUS_NOT_FOUND
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Dispatcher. Removed in 2.0.0.';
  GRPC_STATUS_UNIMPLEMENTED    = Nghttp2.Grpc.Dispatcher.GRPC_STATUS_UNIMPLEMENTED
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Dispatcher. Removed in 2.0.0.';
  GRPC_STATUS_INTERNAL         = Nghttp2.Grpc.Dispatcher.GRPC_STATUS_INTERNAL
    deprecated 'Moved to Delphi-nghttp2: use Nghttp2.Grpc.Dispatcher. Removed in 2.0.0.';

implementation

end.
