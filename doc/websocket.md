# WebSocket over HTTP/2 (RFC 8441)

**Status: VALIDATED end-to-end, 2026-08-21.**

`build-fpc.sh` stage 18 — driven by Python `h2`, an independent HTTP/2
implementation — passes 4/4:

```text
PASS  server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL
PASS  extended CONNECT accepted with :status 200 (no 101 in HTTP/2)
PASS  server sent its 'welcome' text frame
PASS  masked client frame round-tripped as 'echo:hello'
```

## Two Horse core fixes were required

The provider was correct from the start; it was blocked on two independent
defects in Horse core, and the first hid the second.

**1. `FeedBytes` interface-to-class cast — FPC only.** (HashLoad/horse PR #551.)
`Horse.Core.WebSocket.FeedBytes` receives `IHorseWebSocketConnection` and casts
back to the class at 11 sites. Delphi resolves that to the implementing object;
FPC `{$MODE DELPHI}` does not, so `FOnMessage`/`FOnBinary`/`FOnError` read at
the wrong address and no inbound callback fires. Sending still works and
`OnError` is unreachable through the same cast, so it fails silently.

**2. epoll transport treats `EAGAIN` as a disconnect.** (HashLoad/horse PR #549.)
Not on this provider's path — nghttp2 has its own transport — but it is what
made the first defect so hard to see. On epoll it severed the connection ~1 ms
after the upgrade, so no bytes ever reached `FeedBytes` and patching the cast
appeared to change nothing.

Separating them needed a 2×2 control matrix: each fix alone fails, both together
pass. Until PR #551 merges upstream, this provider needs
`patches/horse/src/Horse.Core.WebSocket.pas` applied for WebSocket receive to
work on FPC.

Note that `Req.IsWebSocket` still relies on a header-synthesis workaround in
`Horse.Provider.Nghttp2.Request.pas`; PR #550 adds `SetWebSocketUpgrade` to core
so that can be dropped once merged.

## Enabling

```pascal
THorseProviderNghttp2.EnableWebSocket := True;   // BEFORE Listen

THorse.Get('/ws', WsEcho);
```

```pascal
procedure WsOnMessage(const AConn: IHorseWebSocketConnection; const AText: string);
begin
  AConn.SendText('echo:' + AText);
end;

procedure WsOnConnect(const AConn: IHorseWebSocketConnection);
begin
  AConn.OnMessage := WsOnMessage;
  AConn.SendText('welcome');
end;

procedure WsEcho(Req: THorseRequest; Res: THorseResponse);
begin
  Res.UpgradeToWebSocket(WsOnConnect);
end;
```

**Plain unit-scope procedures, not methods.** `TOnWebSocketConnect` is
`reference to procedure` on Delphi and a plain `procedure` on FPC — never
`of object`. A bound method fails to compile on FPC with *"Incompatible type
for arg no. 1 … expected `<procedure variable type>`"*. A global procedure
satisfies both. (This differs from `Res.SendStream` and the gRPC handlers,
which *are* `of object` and do take methods — the families are not uniform.)

Do not reference `Req` or `Res` inside the callbacks: the HTTP request
lifecycle ends at the upgrade and the context is recycled.

## Why it is off by default

Not caution — reach. Enabling advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL`,
which invites conforming clients to attempt extended CONNECT. That is a good
trade only if your clients can use it:

- **Browsers can.** Chrome, Firefox and Safari implement RFC 8441, and
  `new WebSocket(...)` is unchanged — the browser negotiates transparently once
  the connection is h2 and the server advertises.
- **Most non-browser clients cannot.** Delphi WebSocket libraries, Python
  `websockets`, and the bulk of tooling speak RFC 6455 over HTTP/1.1 only.
- **There is no fallback here.** Other Horse providers serve RFC 6455 over
  HTTP/1.1; this one has no HTTP/1.1 at all. For an incapable client the
  result is *cannot connect*, not *slower path*.

A server advertising an upgrade it can only honour for some callers is worse
than one that never offered.

## What RFC 8441 changes

There is no `101` and no `Sec-WebSocket-Key` handshake. HTTP/2 has no
protocol-switch status, so a client opens an ordinary stream carrying
`:method CONNECT` plus `:protocol websocket`, and the server accepts with
`:status 200`. The stream then carries RFC 6455 frames as DATA both ways.

The key/accept exchange is gone because the attack it defended against is: it
existed to stop an attacker tricking an HTTP/1.1 cache or proxy into treating a
crafted request as an upgrade. HTTP/2 framing makes that impossible.

**Plain CONNECT is still refused.** Only the extended form carrying
`:protocol` is accepted — honouring RFC 7540 §8.3 tunnelling would turn every
deployment into a forward proxy.

## How it fits together

Horse separates the RFC 6455 codec from the channel, so this provider supplies
only a transport — six methods, five of which already existed:

| `IHorseWebSocketTransport` | Backed by |
|---|---|
| `Write` | `PushStreamData` (STREAM-1) |
| `Read` | `ReadInbound` (INBOUND-1) |
| `Close` | `EndStreaming` |
| `IsConnected` | `IsStreamAlive` |
| `GetClientIP` / `GetServerPort` | `INghttp2Connection` |

All masking, fragmentation, opcode and control-frame handling stays in
`Horse.Core.WebSocket`, shared with every other provider.

A WebSocket stream is inbound-streaming by definition, so it dispatches on
HEADERS rather than END_STREAM — its read loop must consume frames while the
peer is still sending. That also means **it requires the worker pool** (the
default): the loop blocks for the life of the connection, so each connection
occupies one worker throughout. Size accordingly.

## Testing it

No client in this repo speaks RFC 8441 — `TNghttp2Client` has no extended
CONNECT — so validation needs a browser:

```js
const ws = new WebSocket('ws://127.0.0.1:9010/ws');
ws.onmessage = e => console.log(e.data);   // "welcome", then "echo:..."
ws.onopen    = () => ws.send('hello');
```

Chrome only uses RFC 8441 when the connection is already HTTP/2, which for
`ws://` means h2c with prior knowledge — browsers generally will not do that.
In practice this needs a **TLS build** and `wss://`, where ALPN negotiates h2
first. Run the server with `tls` and use `wss://127.0.0.1:9443/ws`.

Adding extended CONNECT to `TNghttp2Client` would make this suite-testable and
is the obvious next step if WebSocket becomes load-bearing.
