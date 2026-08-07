unit Horse.Provider.Nghttp2.Request;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Request
//  TNghttp2RequestBridge — validates an incoming HTTP/2 stream and (on rvOK)
//  populates a THorseRequest with shadow fields, non-owning body, headers,
//  cookies, and the RawWebRequest adapter.
//
//  Called TWICE in the standard hot path per SEC-29:
//    1) with AHorseReq = nil → validate only; if not rvOK, send error and
//       skip pool acquisition entirely
//    2) with a pooled THorseRequest → full population
//
//  HTTP/2 pseudo-headers (RFC 7540 §8.1.2.3): :method, :scheme, :authority,
//  :path — all lowercase, name-prefixed with colon. There is no Host header
//  in HTTP/2; :authority replaces it.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Horse,
  Horse.Commons,
  Nghttp2.Types;

type
  TRequestValidationResult = (
    rvOK,
    rvBadRequest,        // → 400
    rvMethodNotAllowed   // → 405
  );

  TNghttp2RequestBridge = class
  public
    class function Populate(
      const AStream:   INghttp2Stream;
      const AHorseReq: THorseRequest;   // nil = probe-only validation (SEC-29)
      out   ARejectReason: string
    ): TRequestValidationResult; static;
  end;

implementation

uses
  Horse.Provider.Nghttp2.WebRequestAdapter;

class function TNghttp2RequestBridge.Populate(
  const AStream:   INghttp2Stream;
  const AHorseReq: THorseRequest;
  out   ARejectReason: string
): TRequestValidationResult;
var
  LMethod, LPath, LScheme, LAuthority: string;
  LContentType, LRemoteAddr:           string;
  LMethodType:                         TMethodType;
  LHeaders:                            TStringList;
  I:                                   Integer;
  LName:                               string;
begin
  Result := rvOK;
  ARejectReason := '';

  // ── Extract HTTP/2 pseudo-headers ────────────────────────────────────────
  LMethod      := AStream.Header[':method'];
  LScheme      := AStream.Header[':scheme'];
  LAuthority   := AStream.Header[':authority'];
  LPath        := AStream.Header[':path'];
  LContentType := AStream.Header['content-type'];
  if AStream.Connection <> nil then
    LRemoteAddr := AStream.Connection.PeerAddr
  else
    LRemoteAddr := '';

  // ── Validation ──────────────────────────────────────────────────────────

  // (1) Method must be present and not TRACE/CONNECT.
  //     HTTP/2 CONNECT has extended semantics (RFC 8441 WebSocket-over-HTTP/2);
  //     out of scope for v1.
  if LMethod = '' then
  begin
    ARejectReason := 'Missing :method pseudo-header';
    Exit(rvBadRequest);
  end;
  if SameText(LMethod, 'TRACE') or SameText(LMethod, 'CONNECT') then
  begin
    ARejectReason := 'Method not allowed: ' + LMethod;
    Exit(rvMethodNotAllowed);
  end;

  // (2) :scheme must be http or https (RFC 7540 §8.1.2.3).
  if (LScheme <> '') and not (SameText(LScheme, 'http') or SameText(LScheme, 'https')) then
  begin
    ARejectReason := 'Invalid :scheme value';
    Exit(rvBadRequest);
  end;

  // (3) :authority must be present. HTTP/2 does not use the Host header;
  //     an intermediary may still forward "host" — we accept it as a fallback.
  if LAuthority = '' then
    LAuthority := AStream.Header['host'];
  if LAuthority = '' then
  begin
    ARejectReason := 'Missing :authority pseudo-header';
    Exit(rvBadRequest);
  end;

  // (4) :path must be present and non-empty.
  if LPath = '' then
  begin
    ARejectReason := 'Missing :path pseudo-header';
    Exit(rvBadRequest);
  end;

  // (5) Forbid the connection-specific headers HTTP/2 rejects
  //     (RFC 7540 §8.1.2.2). transfer-encoding is disallowed except for the
  //     literal value "trailers" — not implemented in v1, so reject any presence.
  if (AStream.Header['connection']         <> '') or
     (AStream.Header['keep-alive']         <> '') or
     (AStream.Header['proxy-connection']   <> '') or
     (AStream.Header['transfer-encoding']  <> '') or
     (AStream.Header['upgrade']            <> '') then
  begin
    ARejectReason := 'Forbidden connection-specific header in HTTP/2 request';
    Exit(rvBadRequest);
  end;

  // ── Probe-only mode (SEC-29): pool context never acquired on failure ────
  if AHorseReq = nil then
    Exit;

  // ── Method string → TMethodType enum ────────────────────────────────────
  // Horse.Commons.TMethodType = (mtAny, mtGet, mtPut, mtPost, mtHead,
  //                              mtDelete, mtPatch, mtQuery).
  // Note: no distinct mtOptions — Horse doesn't dispatch OPTIONS through the
  // method-type enum. Horse.CORS handles OPTIONS preflight at the middleware
  // layer via string comparison on Req.MethodType-agnostic pipelines, then
  // raises EHorseCallbackInterrupted after sending 204. We map OPTIONS to
  // mtAny so any wildcard route matches and CORS middleware still runs.
  if      SameText(LMethod, 'GET')     then LMethodType := mtGet
  else if SameText(LMethod, 'POST')    then LMethodType := mtPost
  else if SameText(LMethod, 'PUT')     then LMethodType := mtPut
  else if SameText(LMethod, 'DELETE')  then LMethodType := mtDelete
  else if SameText(LMethod, 'PATCH')   then LMethodType := mtPatch
  // HEAD → mtGet per RFC 7231 §4.3.2: "The HEAD method is identical to GET
  // except that the server MUST NOT send a message body in the response."
  // Routing HEAD to GET handlers lets THorse.Get('/x') serve HEAD /x. Body
  // stripping on HEAD is a nice-to-have for bandwidth; correct clients ignore
  // any body on HEAD responses anyway.
  else if SameText(LMethod, 'HEAD')    then LMethodType := mtGet
  else                                      LMethodType := mtAny;

  // ── Populate THorseRequest shadow fields ────────────────────────────────
  //     Signature per patched Horse.Request.pas:
  //     Populate(AMethod, AMethodType, APath, AContentType, ARemoteAddr).
  //     :authority becomes the Host shadow field via a subsequent header set;
  //     Populate itself does not take Host — Host is read from the header dict.
  AHorseReq.Populate(LMethod, LMethodType, LPath, LContentType, LRemoteAddr);

  // ── Body registration (PATCH-REQ-11) ────────────────────────────────────
  //     AOwnsBody=False — the stream is owned by the Session's INghttp2Stream
  //     impl, which frees it when the stream closes. If we passed True (or
  //     used the single-arg overload, which defaults to True), THorseRequest.Clear
  //     on pool recycle would FreeAndNil a stream the Session still owns
  //     → double-free on the next request.
  if Assigned(AStream.Body) then
    AHorseReq.Body(AStream.Body, {AOwnsBody=}False);

  // ── Header dictionary population ────────────────────────────────────────
  //     Middleware that reads Req.Headers.GetValue needs the dictionary
  //     populated. Pseudo-headers (:method, :path, :authority, :scheme) are
  //     skipped — they're not real headers, and adding them would confuse
  //     downstream Indy-style middleware.
  LHeaders := TStringList.Create;
  try
    AStream.PopulateRequestHeadersInto(LHeaders);
    for I := 0 to LHeaders.Count - 1 do
    begin
      LName := LHeaders.Names[I];
      if (LName <> '') and (LName[1] <> ':') then
        AHorseReq.Headers.Dictionary.AddOrSetValue(LName, LHeaders.ValueFromIndex[I]);
    end;
  finally
    LHeaders.Free;
  end;

  // ── Cookies ─────────────────────────────────────────────────────────────
  AHorseReq.PopulateCookiesFromHeader(AStream.Header['cookie']);

  // ── RawWebRequest adapter (PATCH-REQ-8) — needed by Horse.CORS et al. ──
  //     Ownership transfers to THorseRequest; freed by Clear on pool release.
  AHorseReq.SetCSRawWebRequest(TNghttp2WebRequest.Create(AStream));
end;

end.
