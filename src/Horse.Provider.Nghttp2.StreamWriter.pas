unit Horse.Provider.Nghttp2.StreamWriter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.StreamWriter                              (STREAM-1)
//  Res.SendStream(...) support for the nghttp2 provider — Web Streams (NDJSON)
//  and Server-Sent Events.
//
//  What HTTP/2 changes about streaming
//  -----------------------------------
//  HTTP/1.1 has no way to say "body of unknown length" other than
//  Transfer-Encoding: chunked, so every provider on that protocol frames each
//  piece with a hex length prefix and terminates with a 0-length chunk.
//  HTTP/2 has framing built in: a DATA frame carries its own length, and the
//  body ends when a frame arrives with END_STREAM. Chunked framing on top of
//  that is not just redundant — RFC 9113 §8.2.2 forbids the header outright.
//
//  Horse already accounts for this. THorseStreamWriterBase.Create clears
//  FUseChunked when the request's ProtocolVersion is 'HTTP/2' (which
//  TNghttp2RawRequest.GetProtocolVersion returns), so the base class passes
//  our bytes through untouched and its Close emits no terminator. This
//  descendant therefore only has to move bytes; the protocol difference is
//  already handled above it.
//
//  Backpressure
//  ------------
//  There is none here, deliberately. Write appends to the stream's buffer and
//  returns; if the peer reads slower than the handler produces, the buffer
//  grows. HTTP/2 flow control throttles the wire, not the producer. A handler
//  that generates unboundedly fast (a `while True` with no delay) will grow
//  memory until the client catches up — pace the loop, or check IsConnected
//  and stop. Bounding the buffer is deferred to v0.2, where the fix is a cap
//  plus a signal the handler can wait on.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Horse.Response,
  Horse.Provider.RawAdapters,
  Horse.Provider.Nghttp2.RawResponse,
  Horse.Provider.Nghttp2.Response,
  Nghttp2.Types;

type
  TNghttp2StreamWriter = class(THorseStreamWriterBase)
  private
    FStream: INghttp2Stream;
    { The base class tracks this too, but privately. We need our own copy so
      Close can tell "handler wrote nothing" from "handler finished" — the
      first still owes the client a HEADERS frame. }
    FHeadersDone: Boolean;
  protected
    procedure SendRawHeaders; override;
    procedure WriteRawBytes(const ABytes: TBytes); override;
  public
    constructor Create(const AResponse: THorseResponse); override;
    function  IsConnected: Boolean; override;
    procedure Close; override;
  end;

{ Registered as the global stream-writer factory by this unit's initialization.
  Only one transport provider is ever linked into a build — the HORSE_PROVIDER_*
  defines are mutually exclusive — so this is the only factory in the process. }
function Nghttp2StreamWriterFactory(const AResponse: THorseResponse): IHorseStreamWriter;

implementation

constructor TNghttp2StreamWriter.Create(const AResponse: THorseResponse);
var
  LRawWebResponse: TObject;
  LAccess:         INghttp2StreamAccess;
begin
  inherited Create(AResponse);

  LRawWebResponse := AResponse.RawWebResponse;
  if Assigned(LRawWebResponse) and (LRawWebResponse is TInterfacedWebResponse) then
    if Supports(TInterfacedWebResponse(LRawWebResponse).RawRes,
                INghttp2StreamAccess, LAccess) then
      FStream := LAccess.GetNghttp2Stream;
end;

{ Reuses the response bridge so a streamed response carries exactly the same
  headers a buffered one would — content-type, user headers, Set-Cookie,
  security baseline. Duplicating the emit logic here is how the two paths
  would quietly drift apart.

  BeginStreaming submits HEADERS immediately with an open-ended data provider;
  everything after this point is DATA frames. }
procedure TNghttp2StreamWriter.SendRawHeaders;
begin
  if (not Assigned(FStream)) or FHeadersDone then Exit;
  FHeadersDone := True;

  TNghttp2ResponseBridge.EmitHeaders(FResponse, FStream, '');
  FStream.BeginStreaming;
end;

procedure TNghttp2StreamWriter.WriteRawBytes(const ABytes: TBytes);
begin
  if Length(ABytes) = 0 then Exit;
  if Assigned(FStream) then
    FStream.PushStreamData(ABytes);
end;

function TNghttp2StreamWriter.IsConnected: Boolean;
begin
  Result := Assigned(FStream) and FStream.IsStreamAlive;
end;

{ The base Close writes a chunked terminator, which is correct on HTTP/1.1 and
  illegal here — FUseChunked is already False on this path, so inherited does
  nothing, but call it anyway so any future base-class cleanup still runs.
  EndStreaming is what actually closes the stream: it lets the data provider
  report EOF, and nghttp2 sets END_STREAM on the final frame. }
procedure TNghttp2StreamWriter.Close;
begin
  inherited Close;
  if not Assigned(FStream) then Exit;

  { A handler that returned without ever writing still needs headers on the
    wire — otherwise the client sees a stream that opened and closed with no
    response at all. SendRawHeaders is idempotent via FHeadersDone. }
  SendRawHeaders;
  FStream.EndStreaming;
end;

function Nghttp2StreamWriterFactory(const AResponse: THorseResponse): IHorseStreamWriter;
begin
  Result := TNghttp2StreamWriter.Create(AResponse);
end;

initialization
  THorseResponse.RegisterStreamWriterFactory(Nghttp2StreamWriterFactory);

end.
