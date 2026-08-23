unit Horse.Provider.Nghttp2.Grpc.StreamWriter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.StreamWriter — COMPATIBILITY SHIM
//
//  The real unit is Nghttp2.Grpc.StreamWriter in Delphi-nghttp2 (>= 1.5.0).
//  The gRPC layer moved there on 2026-08-23 because it never depended on
//  Horse — only its unit name did. This shim keeps 1.4.x code compiling.
//
//  Migration: change `uses Horse.Provider.Nghttp2.Grpc.StreamWriter` to
//  `uses Nghttp2.Grpc.StreamWriter`. Nothing else changes.
//
//  REMOVED IN 2.0.0, together with the THorse* type-name renames that are the
//  other half of this deprecation window. Do not add anything here.
//
//  Most handlers never name this class — they receive an IGrpcStreamWriter
//  from the dispatcher, and that interface is declared in the Registry unit.
//  The alias is here for the tests and tools that construct one directly.
// ============================================================================

interface

uses
  Nghttp2.Grpc.StreamWriter;

type
  { Server-streaming writer over one HTTP/2 stream. Send TAKES OWNERSHIP of
    the response object it is handed. }
  TGrpcStreamWriter = Nghttp2.Grpc.StreamWriter.TGrpcStreamWriter
    deprecated 'Moved in 1.5.0 to Delphi-nghttp2: use Nghttp2.Grpc.StreamWriter. Removed in 2.0.0.';

implementation

end.
