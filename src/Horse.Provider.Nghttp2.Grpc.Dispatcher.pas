unit Horse.Provider.Nghttp2.Grpc.Dispatcher;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Grpc.Dispatcher
//  Intercepts application/grpc requests, decodes the 5-byte-prefixed
//  protobuf body, invokes the registered handler, encodes the response,
//  and emits the grpc-status trailer.
//  M4a of the horse-provider-nghttp2 gRPC plan (2026-08-07).
//
//  Wire format per gRPC-over-HTTP/2 spec:
//    Request/Response body   = [1B compressed flag][4B BE length][protobuf]
//    Response trailer        = grpc-status: N  (+ optional grpc-message)
//
//  Content-Type recognition: `application/grpc` and `application/grpc+proto`
//  both match (StartsText check). `application/grpc-web` explicitly NOT
//  handled — needs a base64/framing translator, deferred to v0.2.
//
//  Status code mapping:
//    OK           = 0   — normal successful method invocation
//    UNIMPLEMENTED= 12  — path not in registry
//    INTERNAL     = 13  — protobuf decode error, handler exception,
//                        or dispatcher-side framing error
//    (Other codes 1-11, 14-16 available for handlers to signal via custom
//    exception classes; not yet implemented — see plan §M4 Deferred.)
// ============================================================================

interface

uses
  Nghttp2.Types;

type
  THorseGrpcDispatcher = class
  public
    { Called from Horse.Provider.Nghttp2.ExecutePipeline BEFORE the pool
      acquire + Horse.Execute. If the request is application/grpc*, this
      routine fully handles it (writes response + trailer, returns True).
      Otherwise returns False and the caller falls through to Horse routing. }
    class function TryDispatch(const AStream: INghttp2Stream): Boolean; static;
  end;

const
  // Standard gRPC status codes — https://github.com/grpc/grpc/blob/master/doc/statuscodes.md
  GRPC_STATUS_OK               = 0;
  GRPC_STATUS_INVALID_ARGUMENT = 3;
  GRPC_STATUS_NOT_FOUND        = 5;
  GRPC_STATUS_UNIMPLEMENTED    = 12;
  GRPC_STATUS_INTERNAL         = 13;

implementation

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, StrUtils,
{$ELSE}
  System.SysUtils, System.Classes, System.StrUtils,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Horse.Provider.Nghttp2.Grpc.Registry;

// ── 5-byte prefix framing ──────────────────────────────────────────────────

function StripGrpcPrefix(const AData: TBytes; out ABody: TBytes; out AError: string): Boolean;
var
  LMsgLen: UInt32;
begin
  Result := False;
  if Length(AData) < 5 then
  begin
    AError := 'gRPC frame too short (< 5-byte prefix)';
    Exit;
  end;
  if AData[0] <> 0 then
  begin
    AError := 'gRPC compression flag set (per-message compression not supported in v0.1)';
    Exit;
  end;
  // 4-byte big-endian length prefix
  LMsgLen := (UInt32(AData[1]) shl 24) or
             (UInt32(AData[2]) shl 16) or
             (UInt32(AData[3]) shl 8)  or
              UInt32(AData[4]);
  if Length(AData) < 5 + Integer(LMsgLen) then
  begin
    AError := Format('gRPC frame truncated: header says %u bytes, buffer has %d',
                     [LMsgLen, Length(AData) - 5]);
    Exit;
  end;
  SetLength(ABody, LMsgLen);
  if LMsgLen > 0 then
    Move(AData[5], ABody[0], LMsgLen);
  Result := True;
end;

function WrapGrpcPrefix(const AProtoBody: TBytes): TBytes;
var
  LLen: UInt32;
begin
  LLen := UInt32(Length(AProtoBody));
  SetLength(Result, 5 + Integer(LLen));
  Result[0] := 0;                          // compression flag = uncompressed
  Result[1] := Byte((LLen shr 24) and $FF);
  Result[2] := Byte((LLen shr 16) and $FF);
  Result[3] := Byte((LLen shr 8) and $FF);
  Result[4] := Byte( LLen        and $FF);
  if LLen > 0 then
    Move(AProtoBody[0], Result[5], LLen);
end;

// ── Body accumulation from the request stream ──────────────────────────────

function ReadStreamAsBytes(const AStream: TStream): TBytes;
begin
  if (AStream = nil) or (AStream.Size = 0) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  SetLength(Result, AStream.Size);
  AStream.Position := 0;
  AStream.ReadBuffer(Result[0], AStream.Size);
end;

// ── Error-path helper: emit an empty body + grpc-status trailer ────────────

procedure SendGrpcStatusOnly(
  const AStream: INghttp2Stream;
  AStatus: Integer;
  const AMessage: string);
var
  LEmpty: TBytes;
begin
  AStream.StatusCode := 200;
  AStream.Header['content-type'] := 'application/grpc';
  AStream.AddTrailer('grpc-status', IntToStr(AStatus));
  if AMessage <> '' then
    AStream.AddTrailer('grpc-message', AMessage);
  // Empty framed body per gRPC spec — client sees zero-length message and
  // reads status from trailers. We still emit the 5-byte prefix for a
  // well-formed frame (compression=0, length=0).
  SetLength(LEmpty, 5);
  LEmpty[0] := 0;
  LEmpty[1] := 0;
  LEmpty[2] := 0;
  LEmpty[3] := 0;
  LEmpty[4] := 0;
  AStream.Send(LEmpty);
end;

// ── Main dispatcher ────────────────────────────────────────────────────────

class function THorseGrpcDispatcher.TryDispatch(const AStream: INghttp2Stream): Boolean;
var
  LContentType: string;
  LPath:        string;
  LInfo:        TGrpcMethodInfo;
  LReqBytes:    TBytes;
  LProtoBytes:  TBytes;
  LError:       string;
  LReqObj:      TObject;
  LRespObj:     TObject;
  LRespProto:   TBytes;
  LFramed:      TBytes;
begin
  // 1. Content-type check — only intercept application/grpc*
  LContentType := AStream.Header['content-type'];
  if not StartsText('application/grpc', LContentType) then
    Exit(False);

  // From here on, we own the response — always return True even on error,
  // because we've committed to writing a gRPC-format response.
  Result := True;

  // 2. Registry lookup — 404-equivalent is UNIMPLEMENTED status trailer
  LPath := AStream.Header[':path'];
  if not THorseGrpc.TryGet(LPath, LInfo) then
  begin
    SendGrpcStatusOnly(AStream, GRPC_STATUS_UNIMPLEMENTED,
      'method not registered: ' + LPath);
    Exit;
  end;

  // 3. Read + un-frame the request body
  LReqBytes := ReadStreamAsBytes(AStream.Body);
  if not StripGrpcPrefix(LReqBytes, LProtoBytes, LError) then
  begin
    SendGrpcStatusOnly(AStream, GRPC_STATUS_INVALID_ARGUMENT, LError);
    Exit;
  end;

  // 4. Deserialize request, invoke handler, serialize response
  try
    LReqObj := LInfo.RequestClass.Create;
    try
      try
        TProtoSerializer.Deserialize(LProtoBytes, LReqObj);
      except
        on E: Exception do
        begin
          SendGrpcStatusOnly(AStream, GRPC_STATUS_INVALID_ARGUMENT,
            'protobuf decode: ' + E.Message);
          Exit;
        end;
      end;

      LRespObj := LInfo.ResponseClass.Create;
      try
        try
          LInfo.Handler(LReqObj, LRespObj);
        except
          on E: Exception do
          begin
            // SEC-31 style: don't leak stack — Message only.
            SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
              E.ClassName + ': ' + E.Message);
            Exit;
          end;
        end;

        try
          LRespProto := TProtoSerializer.Serialize(LRespObj);
        except
          on E: Exception do
          begin
            SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
              'protobuf encode: ' + E.Message);
            Exit;
          end;
        end;
      finally
        LRespObj.Free;
      end;
    finally
      LReqObj.Free;
    end;
  except
    on E: Exception do
    begin
      // Catch-all for Create failures / OOM / etc.
      SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
        'dispatcher fault: ' + E.Message);
      Exit;
    end;
  end;

  // 5. Frame the response, set headers + status-0 trailer, send.
  LFramed := WrapGrpcPrefix(LRespProto);
  AStream.StatusCode := 200;
  AStream.Header['content-type'] := 'application/grpc';
  AStream.AddTrailer('grpc-status',  '0');
  AStream.AddTrailer('grpc-message', 'OK');
  AStream.Send(LFramed);
end;

end.
