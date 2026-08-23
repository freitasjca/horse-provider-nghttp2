unit Horse.Provider.Nghttp2.Grpc.StreamReader;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.StreamReader — COMPATIBILITY SHIM
//
//  The real unit is Nghttp2.Grpc.StreamReader in Delphi-nghttp2 (>= 1.5.0).
//  The gRPC layer moved there on 2026-08-23 because it never depended on
//  Horse — only its unit name did. This shim keeps 1.4.x code compiling.
//
//  Migration: change `uses Horse.Provider.Nghttp2.Grpc.StreamReader` to
//  `uses Nghttp2.Grpc.StreamReader`. Nothing else changes.
//
//  REMOVED IN 2.0.0, together with the THorse* type-name renames that are the
//  other half of this deprecation window. Do not add anything here.
//
//  Most handlers never name this class — they receive an IGrpcStreamReader
//  from the dispatcher, and that interface is declared in the Registry unit.
//  The alias is here for the tests and tools that construct one directly.
// ============================================================================

interface

uses
  Nghttp2.Grpc.StreamReader;

const
  { Read-loop tick and the reassembly ceiling. Aliased because a caller sizing
    its own buffers against them should keep reading the library's values, not
    a copy that can drift. }
  GRPC_READ_TICK_MS = Nghttp2.Grpc.StreamReader.GRPC_READ_TICK_MS
    deprecated 'Moved in 1.5.0 to Delphi-nghttp2: use Nghttp2.Grpc.StreamReader. Removed in 2.0.0.';
  GRPC_MAX_MESSAGE_BYTES = Nghttp2.Grpc.StreamReader.GRPC_MAX_MESSAGE_BYTES
    deprecated 'Moved in 1.5.0 to Delphi-nghttp2: use Nghttp2.Grpc.StreamReader. Removed in 2.0.0.';

type
  { Client-streaming / bidi reader over one HTTP/2 stream. Next returns a
    READER-OWNED object valid only until the following call. }
  TGrpcStreamReader = Nghttp2.Grpc.StreamReader.TGrpcStreamReader
    deprecated 'Moved in 1.5.0 to Delphi-nghttp2: use Nghttp2.Grpc.StreamReader. Removed in 2.0.0.';

implementation

end.
