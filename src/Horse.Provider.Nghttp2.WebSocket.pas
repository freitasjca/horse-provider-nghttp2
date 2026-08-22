unit Horse.Provider.Nghttp2.WebSocket;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Horse.Provider.Nghttp2.WebSocket                                  (WS-8441)
//  WebSocket over HTTP/2 — RFC 8441 extended CONNECT.
//
//  There is no 101 here, and no Sec-WebSocket-Key handshake. HTTP/2 has no
//  protocol-switch status, so RFC 8441 instead opens an ordinary stream with
//  `:method CONNECT` plus `:protocol websocket`, which the server accepts by
//  answering `:status 200`. The stream then carries RFC 6455 frames as DATA in
//  both directions until it closes.
//
//  The key/accept exchange is gone because the threat it defended against is:
//  it existed to stop an attacker tricking an HTTP/1.1 cache or proxy into
//  treating a crafted request as an upgrade. HTTP/2 framing makes that
//  impossible, so RFC 8441 drops it.
//
//  What this unit actually contributes is small, because Horse split the
//  RFC 6455 codec from the channel: IHorseWebSocketTransport is six methods
//  over a byte stream, and STREAM-1 plus INBOUND-1 already provide five of
//  them. All masking, fragmentation, opcode and control-frame handling stays
//  in Horse.Core.WebSocket, shared with every other provider.
//
//  ── Reach, and why this is opt-in ────────────────────────────────────────
//  RFC 8441 needs client support, and support is uneven. Browsers have it —
//  and `new WebSocket(...)` is unchanged, the browser negotiates transparently
//  once the connection is h2 and the server advertises the setting. Most
//  non-browser clients and libraries speak RFC 6455 over HTTP/1.1 only, and
//  this provider has no HTTP/1.1 to fall back to, so for them it is not "slow
//  path", it is "cannot connect".
//
//  Hence THorseProviderNghttp2.EnableWebSocket defaults to False. Advertising
//  the setting invites conforming clients to try extended CONNECT, and a
//  server with nowhere to route those streams is worse than one that never
//  offered.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Horse.Core.WebSocket,
  Nghttp2.Types;

type
  { The six-method byte channel Horse's WebSocket core runs on.

    Read/Write map onto INBOUND-1 and STREAM-1 respectively; the rest is
    delegation. Note Read's contract differs from the socket transport's: it
    blocks with a timeout and reports 0 only at genuine end-of-stream, never
    for "nothing right now". }
  TNghttp2WebSocketTransport = class(TInterfacedObject, IHorseWebSocketTransport)
  private
    FStream: INghttp2Stream;
    FPath:   string;
  public
    constructor Create(const AStream: INghttp2Stream; const APath: string);
    function  Read(var ABuffer: TBytes; const ACount: Integer): Integer;
    function  Write(const ABuffer: TBytes; const ACount: Integer): Integer;
    procedure Close;
    function  IsConnected: Boolean;
    function  GetClientIP: string;
    function  GetServerPort: Integer;
  end;

  { Registered into Req.Services so Res.UpgradeToWebSocket can find it —
    the same contract the Indy and socket providers satisfy. }
  TNghttp2WebSocketUpgrader = class(THorseWebSocketUpgrader)
  private
    FStream: INghttp2Stream;
  public
    constructor Create(const AStream: INghttp2Stream);
    function Upgrade(const APath: string;
      const AHeartbeatInterval: Integer = 0): IHorseWebSocketConnection; override;
  end;

const
  { One Read tick. A timeout is not a disconnect — a WebSocket peer may sit
    silent for minutes and still be perfectly alive — so Read keeps waiting
    across ticks and only gives up when the stream actually dies. This bounds
    how often liveness is re-checked. }
  WS_READ_TICK_MS = 250;

implementation

// ── Transport ──────────────────────────────────────────────────────────────

constructor TNghttp2WebSocketTransport.Create(const AStream: INghttp2Stream;
  const APath: string);
begin
  inherited Create;
  FStream := AStream;
  FPath   := APath;
end;

{ Horse's read loop treats <= 0 as "connection over" and exits. ReadInbound
  returns -1 for a timeout with the stream still open, which must NOT be
  passed through as such — an idle WebSocket would be torn down after the
  first quiet quarter-second. Loop instead, and return 0 only when the stream
  has genuinely ended. }
function TNghttp2WebSocketTransport.Read(var ABuffer: TBytes;
  const ACount: Integer): Integer;
var
  LRead: Integer;
begin
  Result := 0;
  if not Assigned(FStream) then Exit;

  while True do
  begin
    LRead := FStream.ReadInbound(ABuffer, ACount, WS_READ_TICK_MS);

    if LRead > 0 then Exit(LRead);
    if LRead = 0 then Exit(0);            // peer half-closed — genuine end

    if not FStream.IsStreamAlive then Exit(0);
    // LRead < 0: idle tick, peer still there. Keep waiting.
  end;
end;

function TNghttp2WebSocketTransport.Write(const ABuffer: TBytes;
  const ACount: Integer): Integer;
var
  LChunk: TBytes;
begin
  Result := 0;
  if (not Assigned(FStream)) or (ACount <= 0) then Exit;

  { PushStreamData takes a whole TBytes; Horse hands a buffer plus a count that
    may be shorter than it. Copying the prefix is what keeps a partially-filled
    buffer from putting stale trailing bytes on the wire. }
  if ACount = Length(ABuffer) then
    LChunk := ABuffer
  else
  begin
    SetLength(LChunk, ACount);
    Move(ABuffer[0], LChunk[0], ACount);
  end;

  FStream.PushStreamData(LChunk);
  Result := ACount;
end;

procedure TNghttp2WebSocketTransport.Close;
begin
  if Assigned(FStream) then
    FStream.EndStreaming;
end;

function TNghttp2WebSocketTransport.IsConnected: Boolean;
begin
  Result := Assigned(FStream) and FStream.IsStreamAlive;
end;

function TNghttp2WebSocketTransport.GetClientIP: string;
begin
  if Assigned(FStream) and Assigned(FStream.Connection) then
    Result := FStream.Connection.PeerAddr
  else
    Result := '';
end;

function TNghttp2WebSocketTransport.GetServerPort: Integer;
begin
  if Assigned(FStream) and Assigned(FStream.Connection) then
    Result := FStream.Connection.LocalPort
  else
    Result := 0;
end;

// ── Upgrader ───────────────────────────────────────────────────────────────

constructor TNghttp2WebSocketUpgrader.Create(const AStream: INghttp2Stream);
begin
  inherited Create;
  FStream := AStream;
end;

{ Mirrors THorseWebSocketSocketUpgrader.Upgrade, minus the HTTP/1.1 handshake:
  accept, build the transport and connection, fire OnConnect, then run the
  blocking read loop on this worker thread until the peer goes away.

  The loop is why inbound streaming is mandatory for these paths — it consumes
  frames while the peer is still sending, which is exactly what END_STREAM
  dispatch cannot do. }
function TNghttp2WebSocketUpgrader.Upgrade(const APath: string;
  const AHeartbeatInterval: Integer): IHorseWebSocketConnection;
var
  LTransport:  IHorseWebSocketTransport;
  LConnection: IHorseWebSocketConnection;
  LBuffer:     TBytes;
  LBytesRead:  Integer;
begin
  { RFC 8441 §5: the response to a successful extended CONNECT is 200, not
    101 — HTTP/2 has no protocol-switch status. BeginStreaming opens the
    response side so DATA can flow before the handler returns. }
  FStream.StatusCode := 200;
  FStream.BeginStreaming;

  LTransport  := TNghttp2WebSocketTransport.Create(FStream, APath);
  LConnection := THorseWebSocketConnection.Create(LTransport, APath, AHeartbeatInterval);

  if Assigned(OnConnect) then
  begin
    try
      OnConnect(LConnection);
    except
      on E: Exception do
      begin
        LConnection.TriggerError(E);
        LConnection.Close(1011, 'Internal Error');
        LConnection.TriggerDisconnect;
        raise;
      end;
    end;
  end;


  SetLength(LBuffer, 4096);
  try
    while LConnection.IsConnected do
    begin
      LBytesRead := LTransport.Read(LBuffer, 4096);
      if LBytesRead > 0 then
        LConnection.HandleIncomingBytes(LBuffer, LBytesRead)
      else
        Break;
    end;
  finally
    { EndStreaming inside the finally: without it a stream whose peer vanished
      never carries END_STREAM and the connection is held open by a reply that
      will never come. }
    LTransport.Close;
    LConnection.TriggerDisconnect;
  end;

  Result := LConnection;
end;

end.
