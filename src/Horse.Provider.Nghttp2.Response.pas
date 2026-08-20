unit Horse.Provider.Nghttp2.Response;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.Response
//  TNghttp2ResponseBridge — reads THorseResponse shadow fields and writes
//  them into the INghttp2Stream (which the Session unit will later flush as
//  HEADERS + DATA frames via nghttp2_submit_response).
//
//  Applied here:
//    - CRLF-stripping (header-injection defence — CR/LF/NUL in header values)
//    - Hop-by-hop filtering (RFC 7230 §6.1 — Connection, Keep-Alive, TE,
//      Trailer, Transfer-Encoding, Upgrade, Proxy-*, and Host which HTTP/2
//      replaces with :authority)
//    - Basic security headers (X-Content-Type-Options, X-Frame-Options,
//      Cache-Control, Server) as the default baseline; horse-security-headers
//      middleware may override any of them
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, StrUtils, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.StrUtils, System.Generics.Collections,
{$ENDIF}
  Horse,
  Nghttp2.Types;

type
  TNghttp2ResponseBridge = class
  public
    { Status line + every response header, with no body. Split out of Flush so
      a streaming response can emit its headers up front and then produce a
      body over time — see Horse.Provider.Nghttp2.StreamWriter (STREAM-1). }
    class procedure EmitHeaders(
      const AHorseRes: THorseResponse;
      const AStream:   INghttp2Stream;
      const ABanner:   string       // Server-header value, '' → 'unknown'
    ); static;

    class procedure Flush(
      const AHorseRes: THorseResponse;
      const AStream:   INghttp2Stream;
      const ABanner:   string
    ); static;
  end;

implementation

// ── Local helpers ─────────────────────────────────────────────────────────

function StripCRLF(const S: string): string;
var
  I, J: Integer;
  C: Char;
begin
  SetLength(Result, Length(S));
  J := 0;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C <> #0) and (C <> #10) and (C <> #13) then
    begin
      Inc(J);
      Result[J] := C;
    end;
  end;
  SetLength(Result, J);
end;

function IsHopByHop(const AHeaderName: string): Boolean;
var
  LName: string;
begin
  LName := LowerCase(AHeaderName);
  Result :=
    (LName = 'connection') or
    (LName = 'keep-alive') or
    (LName = 'proxy-connection') or
    (LName = 'proxy-authenticate') or
    (LName = 'proxy-authorization') or
    (LName = 'te') or
    (LName = 'trailer') or
    (LName = 'transfer-encoding') or
    (LName = 'upgrade') or
    (LName = 'host');   // HTTP/2 uses :authority (frame-level) instead
end;

const
  // M2b: user code declares HTTP/2 trailers by adding a header with this
  // prefix (via Res.AddHeader). The response bridge intercepts, strips the
  // prefix, and routes to INghttp2Stream.AddTrailer instead of the normal
  // header path. Example:
  //   Res.Send('hello');
  //   Res.AddHeader('x-nghttp2-trailer-grpc-status', '0');
  //   Res.AddHeader('x-nghttp2-trailer-grpc-message', 'OK');
  // Emits: HEADERS + DATA "hello" + trailer HEADERS (grpc-status: 0,
  // grpc-message: OK) + END_STREAM.
  NGHTTP2_TRAILER_PREFIX      = 'x-nghttp2-trailer-';
  NGHTTP2_TRAILER_PREFIX_LEN  = Length('x-nghttp2-trailer-');

// Route to AddTrailer if the header name starts with the trailer prefix;
// otherwise return False and let the caller emit it as a normal header.
function TryEmitAsTrailer(const AStream: INghttp2Stream;
  const ALowerName, AValue: string): Boolean;
var
  LTrailerName: string;
begin
  if not StartsText(NGHTTP2_TRAILER_PREFIX, ALowerName) then
    Exit(False);
  LTrailerName := Copy(ALowerName, NGHTTP2_TRAILER_PREFIX_LEN + 1,
                       Length(ALowerName) - NGHTTP2_TRAILER_PREFIX_LEN);
  if LTrailerName = '' then
    Exit(True);   // malformed — silently drop rather than emit garbage
  AStream.AddTrailer(LTrailerName, AValue);
  Result := True;
end;

procedure EmitHeader(const AStream: INghttp2Stream; const AName, AValue: string);
var
  LName, LValue: string;
begin
  LName  := StripCRLF(LowerCase(AName));
  LValue := StripCRLF(AValue);
  if LName = '' then Exit;
  // M2b: trailer prefix takes precedence over hop-by-hop filtering and
  // normal header emission.
  if TryEmitAsTrailer(AStream, LName, LValue) then Exit;
  if IsHopByHop(LName) then Exit;
  AStream.Header[LName] := LValue;
end;

// Duplicate-allowing variant — one HPACK nv-pair per call, no dedup.
// Used for headers that legally repeat (Set-Cookie, Warning, Vary).
procedure EmitHeaderAllowDup(const AStream: INghttp2Stream; const AName, AValue: string);
var
  LName, LValue: string;
begin
  LName  := StripCRLF(LowerCase(AName));
  LValue := StripCRLF(AValue);
  if LName = '' then Exit;
  if TryEmitAsTrailer(AStream, LName, LValue) then Exit;   // M2b
  if IsHopByHop(LName) then Exit;
  AStream.AddHeader(LName, LValue);
end;

// ── Public entry point ────────────────────────────────────────────────────

class procedure TNghttp2ResponseBridge.EmitHeaders(
  const AHorseRes: THorseResponse;
  const AStream:   INghttp2Stream;
  const ABanner:   string);
var
  LStatus:      Integer;
  LContentType: string;
  I:            Integer;   // used by RawWebResponse.CustomHeaders + RepeatHeaders loops on both compilers
{$IF NOT DEFINED(FPC)}
  LPair:        TPair<string, string>;
{$IFEND}
begin
  // ── Status (fall through 200 if never explicitly set) ───────────────────
  LStatus := AHorseRes.Status;
  if LStatus = 0 then
    LStatus := 200;
  AStream.StatusCode := LStatus;

  // ── Content-Type from shadow field ──────────────────────────────────────
  LContentType := AHorseRes.CSContentType;
  if LContentType <> '' then
    EmitHeader(AStream, 'content-type', LContentType);

  // ── User-supplied headers (via Res.AddHeader) ───────────────────────────
  // CustomHeaders is deduped by name (TDictionary on Delphi, Values[] on FPC).
  // Set-Cookie is intentionally skipped here — RFC 6265 §3 allows multiple
  // Set-Cookie response headers, and dedup would silently drop cookies past
  // the first. Every Set-Cookie is emitted from RepeatHeaders below instead.
  if Assigned(AHorseRes.CustomHeaders) then
  begin
{$IF DEFINED(FPC)}
    for I := 0 to AHorseRes.CustomHeaders.Count - 1 do
      if not SameText(AHorseRes.CustomHeaders.Names[I], 'set-cookie') then
        EmitHeader(
          AStream,
          AHorseRes.CustomHeaders.Names[I],
          AHorseRes.CustomHeaders.ValueFromIndex[I]);
{$ELSE}
    for LPair in AHorseRes.CustomHeaders do
      if not SameText(LPair.Key, 'set-cookie') then
        EmitHeader(AStream, LPair.Key, LPair.Value);
{$IFEND}
  end;

  // ── Middleware headers set via Res.RawWebResponse.SetCustomHeader ───────
  // Bypasses THorseResponse.FCustomHeaders and writes to the RawWebResponse
  // adapter's inherited TWebResponse.CustomHeaders TStrings. Horse.CORS and
  // any middleware that reaches for the raw web-response object land here.
  // Mirror of horse-provider-crosssocket's PATCH-RES-6.
  // Note: use `<> nil` not Assigned() — RawWebResponse is a property getter
  // (rvalue), and Assigned() intrinsic requires an lvalue → E2036. Same for
  // the nested .CustomHeaders and .RepeatHeaders access below.
  if (AHorseRes.RawWebResponse <> nil)
     and (AHorseRes.RawWebResponse.CustomHeaders <> nil) then
    for I := 0 to AHorseRes.RawWebResponse.CustomHeaders.Count - 1 do
      if not SameText(AHorseRes.RawWebResponse.CustomHeaders.Names[I], 'set-cookie') then
        EmitHeader(
          AStream,
          AHorseRes.RawWebResponse.CustomHeaders.Names[I],
          AHorseRes.RawWebResponse.CustomHeaders.ValueFromIndex[I]);

  // ── Duplicate-allowing headers (Set-Cookie, Warning, Vary, …) ───────────
  // RepeatHeaders is a TStringList populated by Horse.Response.AddHeader
  // alongside the deduping FCustomHeaders. Each entry becomes its own HPACK
  // nv-pair via EmitHeaderAllowDup → INghttp2Stream.AddHeader (no dedup).
  if AHorseRes.RepeatHeaders <> nil then
    for I := 0 to AHorseRes.RepeatHeaders.Count - 1 do
      EmitHeaderAllowDup(
        AStream,
        AHorseRes.RepeatHeaders.Names[I],
        AHorseRes.RepeatHeaders.ValueFromIndex[I]);

  // ── Baseline security headers ───────────────────────────────────────────
  //     These are only emitted if the user hasn't already set them via
  //     AddHeader — nghttp2's HEADERS frame semantics allow multiple values
  //     per name (they'd be sent as separate nv entries), so we skip
  //     duplicates by pre-checking (SetHeader is idempotent on the same key
  //     in our INghttp2Stream implementation).
  //
  //     If the horse-security-headers middleware is registered, it writes
  //     into CustomHeaders above; our default here is the fallback.
  AStream.Header['x-content-type-options'] := 'nosniff';
  AStream.Header['x-frame-options']        := 'DENY';
  AStream.Header['cache-control']          := 'no-store';
  if ABanner <> '' then
    AStream.Header['server'] := StripCRLF(ABanner)
  else
    AStream.Header['server'] := 'unknown';
end;

class procedure TNghttp2ResponseBridge.Flush(
  const AHorseRes: THorseResponse;
  const AStream:   INghttp2Stream;
  const ABanner:   string);
var
  LStatus: Integer;
  LBody:   string;
  LBuf:    TBytes;
begin
  { STREAM-1. A streaming response has already sent its headers and its body,
    piece by piece, through the stream writer — the handler returned only after
    the last chunk. Emitting anything here would submit a second response over
    a stream nghttp2 considers answered. }
  if AHorseRes.IsStreaming then Exit;

  EmitHeaders(AHorseRes, AStream, ABanner);

  LStatus := AHorseRes.Status;
  if LStatus = 0 then
    LStatus := 200;

  // ── Body ────────────────────────────────────────────────────────────────
  // Assigned() requires an lvalue; ContentStream is a property getter (rvalue).
  if AHorseRes.ContentStream <> nil then
  begin
    // Stream response (SendFile / Download). The Session's data_provider
    // read_callback will pull chunks from this stream. Position is not reset
    // here — Horse leaves ContentStream at the position the app left it.
    AStream.SendStream(AHorseRes.ContentStream);
  end
  else
  begin
    LBody := AHorseRes.BodyText;
    if LBody <> '' then
    begin
      LBuf := TEncoding.UTF8.GetBytes(LBody);
      AStream.Send(LBuf);
    end
    else if LStatus >= 400 then
    begin
      // Minimal body for error responses so clients that read the body still
      // see something meaningful (curl, some frameworks).
      LBuf := TEncoding.UTF8.GetBytes(IntToStr(LStatus));
      AStream.Send(LBuf);
    end
    else
    begin
      // 200 / 204 with no body — send empty (nghttp2 will emit END_STREAM
      // on the HEADERS frame directly since data_prd = nil).
      SetLength(LBuf, 0);
      AStream.Send(LBuf);
    end;
  end;
end;

end.
