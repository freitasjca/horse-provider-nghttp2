unit Horse.Provider.Nghttp2.Grpc.Attributes;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.Attributes — COMPATIBILITY SHIM
//
//  The real unit is Nghttp2.Grpc.Attributes in Delphi-nghttp2 (>= 1.5.0). The
//  gRPC layer moved there on 2026-08-23 because it never depended on Horse —
//  only its unit name did. This shim exists so 1.4.x code keeps compiling.
//
//  Migration: change `uses Horse.Provider.Nghttp2.Grpc.Attributes` to
//  `uses Nghttp2.Grpc.Attributes`. Nothing else changes.
//
//  REMOVED IN 2.0.0, together with the THorse* type-name renames that are the
//  other half of this deprecation window. Do not add anything here.
//
//  These are ALIASES, not wrappers — the identifier below denotes the very
//  same class as the one in the library. That matters for attributes
//  specifically: RTTI records the actual attribute class, so the registry's
//  `LAttr is TGrpcServiceAttribute` test succeeds whichever name the
//  declaration site used. A wrapper class would have broken exactly that.
// ============================================================================

interface

uses
  Nghttp2.Grpc.Attributes;

type
  TGrpcServiceAttribute = Nghttp2.Grpc.Attributes.TGrpcServiceAttribute
    deprecated 'Moved in 1.5.0 to Delphi-nghttp2: use Nghttp2.Grpc.Attributes. Removed in 2.0.0.';

implementation

end.
