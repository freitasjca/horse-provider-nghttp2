unit Horse.Provider.Nghttp2.RawRequest;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.RawRequest
//  IHorseRawRequest implementation wrapping one HTTP/2 stream.
//
//  Body content is cached on first read — HTTP/2 body streams are consumable
//  once; Horse's middleware chain calls Req.Body multiple times.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Horse.Provider.RawInterfaces,
  Nghttp2.Types;

type
  TNghttp2RawRequest = class(TInterfacedObject, IHorseRawRequest)
  private
    FStream:        INghttp2Stream;
    FContentCache:  string;
    FContentCached: Boolean;
  public
    constructor Create(const AStream: INghttp2Stream);

    { IHorseRawRequest }
    function  GetMethod: string;
    function  GetProtocolVersion: string;
    function  GetURL: string;
    function  GetPathInfo: string;
    function  GetQueryString: string;
    function  GetHost: string;
    function  GetRemoteAddr: string;
    function  GetServerPort: Integer;
    function  GetContentType: string;
    function  GetContent: string;
{$IF DEFINED(FPC)}
    function  GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
    function  GetContentLength: Int64;
{$ELSE}
    function  GetContentLength: Integer;
{$IFEND}
    function  GetFieldByName(const AName: string): string;
    procedure PopulateHeaders(ADest: TStrings);
    procedure PopulateQueryFields(ADest: TStrings);
    procedure PopulateContentFields(ADest: TStrings);
    procedure PopulateCookieFields(ADest: TStrings);
    function  ReadBody(var Buffer; Count: Integer): Integer;
  end;

implementation

constructor TNghttp2RawRequest.Create(const AStream: INghttp2Stream);
begin
  inherited Create;
  FStream        := AStream;
  FContentCached := False;
end;

function TNghttp2RawRequest.GetMethod: string;
begin
  Result := FStream.Header[':method'];

  // Horse's router (Horse.Core.RouterTree.pas) re-derives the method-type via
  // TMethodType.FromString(RawWebRequest.Method), IGNORING the mtType we set
  // on Populate. Since Horse.Get() registers mtGet only, HEAD requests fail
  // to match GET handlers and return 405. Per RFC 7231 §4.3.2 HEAD is
  // semantically "GET without body" — advertise HEAD as GET to the router so
  // THorse.Get('/x') serves HEAD /x. The client is responsible for ignoring
  // the body per RFC. Defense-in-depth: Nghttp2.Request also maps HEAD→mtGet
  // for the shadow-field TMethodType path.
  if SameText(Result, 'HEAD') then
    Result := 'GET';

  { WS-8441 — same mechanism, same place. RFC 8441 §4 makes extended CONNECT
    (CONNECT + :protocol) the HTTP/2 spelling of HTTP/1.1's `GET` +
    `Upgrade: websocket`: same path, same intent, different wire form because
    HTTP/2 has no upgrade. Horse has no mtConnect, so the router matches
    nothing and answers a bare "Method Not Allowed" before any handler runs.

    Rewriting in Nghttp2.Request.pas alone is NOT enough — that sets the
    shadow TMethodType, which the router does not consult. This function is
    what it reads. Both are set, mirroring the HEAD case above.

    Plain CONNECT (no :protocol) is deliberately untouched: it stays a real
    CONNECT, and Nghttp2.Request rejects it as 405 before reaching a route,
    because honouring RFC 7540 §8.3 tunnelling would make this a forward
    proxy. }
  if SameText(Result, 'CONNECT') and (FStream.Header[':protocol'] <> '') then
    Result := 'GET';
end;

function TNghttp2RawRequest.GetProtocolVersion: string;
begin
  Result := 'HTTP/2';
end;

function TNghttp2RawRequest.GetURL: string;
begin
  Result := FStream.Header[':path'];
end;

function TNghttp2RawRequest.GetPathInfo: string;
var
  S: string;
  QPos: Integer;
begin
  S := GetURL;
  QPos := Pos('?', S);
  if QPos > 0 then
    Result := Copy(S, 1, QPos - 1)
  else
    Result := S;
end;

function TNghttp2RawRequest.GetQueryString: string;
var
  S: string;
  QPos: Integer;
begin
  S := GetURL;
  QPos := Pos('?', S);
  if QPos > 0 then
    Result := Copy(S, QPos + 1, MaxInt)
  else
    Result := '';
end;

function TNghttp2RawRequest.GetHost: string;
begin
  Result := FStream.Header[':authority'];
end;

function TNghttp2RawRequest.GetRemoteAddr: string;
begin
  if FStream.Connection <> nil then
    Result := FStream.Connection.PeerAddr
  else
    Result := '';
end;

function TNghttp2RawRequest.GetServerPort: Integer;
begin
  if FStream.Connection <> nil then
    Result := FStream.Connection.LocalPort
  else
    Result := 0;
end;

function TNghttp2RawRequest.GetContentType: string;
begin
  Result := FStream.Header['content-type'];
end;

function TNghttp2RawRequest.GetContent: string;
var
  LStream: TStream;
  LBytes:  TBytes;
begin
  if FContentCached then Exit(FContentCache);
  FContentCache := '';
  LStream := FStream.Body;
  if Assigned(LStream) and (LStream.Size > 0) then
  begin
    LStream.Position := 0;
    SetLength(LBytes, LStream.Size);
    LStream.Read(LBytes[0], LStream.Size);
    FContentCache := TEncoding.UTF8.GetString(LBytes);
  end;
  FContentCached := True;
  Result := FContentCache;
end;

{$IF DEFINED(FPC)}
function TNghttp2RawRequest.GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
function TNghttp2RawRequest.GetContentLength: Int64;
{$ELSE}
function TNghttp2RawRequest.GetContentLength: Integer;
{$IFEND}
begin
  Result := StrToInt64Def(FStream.Header['content-length'], -1);
end;

function TNghttp2RawRequest.GetFieldByName(const AName: string): string;
begin
  // HTTP/2 forbids uppercase in header field names (RFC 7540 §8.1.2);
  // the transport always stores them lowercase.
  Result := FStream.Header[LowerCase(AName)];
end;

procedure TNghttp2RawRequest.PopulateHeaders(ADest: TStrings);
begin
  // Delegates to the session's stream — pseudo-headers (:method, :path,
  // :authority, :scheme) are included in the emit. Middleware that treats
  // pseudo-headers as regular headers is HTTP/2-aware; middleware that
  // expects only real headers can filter names starting with ':'.
  if Assigned(FStream) then
    FStream.PopulateRequestHeadersInto(ADest);
end;

procedure TNghttp2RawRequest.PopulateQueryFields(ADest: TStrings);
var
  S, Pair: string;
  AmpPos, EqPos: Integer;
begin
  S := GetQueryString;
  while S <> '' do
  begin
    AmpPos := Pos('&', S);
    if AmpPos > 0 then
    begin
      Pair := Copy(S, 1, AmpPos - 1);
      Delete(S, 1, AmpPos);
    end
    else
    begin
      Pair := S;
      S := '';
    end;
    EqPos := Pos('=', Pair);
    if EqPos > 0 then
      ADest.Add(Copy(Pair, 1, EqPos - 1) + '=' + Copy(Pair, EqPos + 1, MaxInt))
    else if Pair <> '' then
      ADest.Add(Pair + '=');
  end;
end;

procedure TNghttp2RawRequest.PopulateContentFields(ADest: TStrings);
begin
  // application/x-www-form-urlencoded parsing is application-level in Horse;
  // this is a no-op unless a Horse middleware explicitly expects populated
  // ContentFields from the transport (Indy legacy behaviour).
end;

procedure TNghttp2RawRequest.PopulateCookieFields(ADest: TStrings);
var
  S, Pair: string;
  SemiPos: Integer;
begin
  S := Trim(FStream.Header['cookie']);
  while S <> '' do
  begin
    SemiPos := Pos(';', S);
    if SemiPos > 0 then
    begin
      Pair := Trim(Copy(S, 1, SemiPos - 1));
      Delete(S, 1, SemiPos);
      S := TrimLeft(S);
    end
    else
    begin
      Pair := Trim(S);
      S := '';
    end;
    if Pair <> '' then
      ADest.Add(Pair);
  end;
end;

function TNghttp2RawRequest.ReadBody(var Buffer; Count: Integer): Integer;
var
  LStream: TStream;
begin
  LStream := FStream.Body;
  if not Assigned(LStream) then Exit(0);
  Result := LStream.Read(Buffer, Count);
end;

end.
