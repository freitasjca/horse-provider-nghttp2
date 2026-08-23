# gRPC

The provider ships a full gRPC v0.1 stack: protobuf codec (all scalar types, nested messages, and repeated fields), service registry, and dispatcher. Both registration styles produce identical wire behaviour.

## Registration styles

**Procedural — explicit per-method (`RegisterMethod`):**

```pascal
TGrpcRegistry.RegisterMethod('/users.UserService/GetUser',
  TGetUserRequest, TGetUserResponse, UserService.GetUser);
```

**IInvokable — one-line service registration (`RegisterService<T>`):**

```pascal
TGrpcRegistry.RegisterService<IUserService>(TUserServiceImpl.Create);
```

`RegisterService<T>` uses RTTI to walk the interface and register each method automatically. On FPC this requires **libffi** (`sudo apt install libffi-dev` + the libffi FPC package path on the compile line). Suppress with `HORSE_GRPC_NO_FFI` if only using `RegisterMethod`.

## Demo

See `samples/grpc/` for a complete working example:

- `HorseNghttp2GrpcDemo.dpr` — server with `IGreeter` service
- `HorseNghttp2GrpcTestClient.dpr` — native Delphi/FPC client (35 checks)
- `greeter.proto` — for grpcurl interop

Run:

```bat
dcc64 -B samples\grpc\HorseNghttp2GrpcDemo.dpr
samples\grpc\HorseNghttp2GrpcDemo.exe
```

```bat
dcc64 -B samples\grpc\HorseNghttp2GrpcTestClient.dpr
samples\grpc\HorseNghttp2GrpcTestClient.exe
# → 35 passed, 0 failed
```

Add `tls` / `mtls` to the demo and point the client at `https://127.0.0.1:18443` (with `--client-cert tls/client-cert.pem --client-key tls/client-key.pem` for mTLS) to cover the other two transports.

## grpcurl

[grpcurl](https://github.com/fullstorydev/grpcurl) is the standard gRPC command-line client. On Windows, download the binary from the [releases page](https://github.com/fullstorydev/grpcurl/releases) — there is no Chocolatey package.

```
grpcurl -plaintext \
  -import-path samples\grpc \
  -proto greeter.proto \
  -d '{"name":"World"}' \
  localhost:18020 greeter.Greeter/Greet
# → {"message": "Hello, World!"}
```

Always pass `-import-path <dir>` unless your shell is already sitting in the
directory holding the `.proto`.

> **The failure this prevents does not look like a path problem.** grpcurl with
> `-proto` never asks the server what it offers — it builds the request purely
> from the schema file. So a stale or wrong `.proto` produces
>
> ```
> Error invoking method "greeter.Greeter/ChatGreetings":
>   service "greeter.Greeter" does not include a method named "ChatGreetings"
> ```
>
> which reads as *the server lacks the method* and is in fact *the file I
> parsed lacks the method*. The binaries build into `bin/<Platform>/<Config>`
> while the `.proto` stays in `samples/grpc`, so running from the output
> directory without `-import-path` hits this every time. If a method the native
> suite just exercised is reported missing, suspect the schema path before the
> server.

### Shell quoting

grpcurl's own syntax is identical everywhere; the shell around it is not, and
each one breaks a different argument.

| Shell | Body argument | Streaming input |
|---|---|---|
| bash / zsh | `-d '{"name":"World"}'` | `-d @` |
| PowerShell | `-d '{\"name\":\"World\"}'` | **`-d '@'`** |
| cmd.exe | `-d "{\"name\":\"World\"}"` | `-d @` |

PowerShell needs `@` quoted because a bare one starts an array or splat
expression — the command fails to parse before grpcurl is launched, so the
error mentions an "Unrecognized token" and never gRPC. cmd.exe needs double
quotes because it does not treat `'` as a quote character at all, so
single-quoted JSON arrives with the quotes still in it.

To feed messages over time — the only way to observe streaming rather than
batching:

```powershell
& {
  '{"name":"A"}'; Start-Sleep -Milliseconds 400
  '{"name":"B"}'; Start-Sleep -Milliseconds 400
  '{"name":"C"}'
} | grpcurl -plaintext -proto greeter.proto -d '@' localhost:18020 greeter.Greeter/ChatGreetings
```

```bat
(echo {"name":"A"}&ping -n 2 127.0.0.1 >nul&echo {"name":"B"}) | grpcurl -plaintext -proto greeter.proto -d @ localhost:18020 greeter.Greeter/ChatGreetings
```

`ping -n 2 127.0.0.1 >nul` is the cmd.exe sleep. `timeout /t 1` is the obvious
choice and does not work: it refuses to run when stdin is redirected, which it
is inside a pipe.

## Validation

| Configuration | Result |
|---|---|
| h2c — Windows/Delphi 12 | **35/35** ✅ (all three streaming shapes) + grpcurl ✓ streaming |
| h2c — Ubuntu/FPC trunk 3.3.1 | **35/35** ✅ (all three streaming shapes) + grpcurl ✓ |
| h2c — Linux64/Delphi | 16/16 ✅ (pre-M6a) |
| TLS + mTLS — Windows/Delphi 12 | 16/16 ✅ (pre-M6a) |
| TLS + mTLS — Ubuntu/FPC trunk 3.3.1 | 16/16 ✅ (pre-M6a) |

Server-streaming is covered on **h2c only** so far. TLS and mTLS share the same
dispatcher and writer, so a transport-specific difference is unlikely — but
that is reasoning, not a test result.

grpcurl matters here beyond "it works": it validates our framing and schema
against an independent implementation. The Pascal client encodes with the same
codec it decodes with, so a symmetric framing defect would pass it and fail
every other gRPC stack.

The streaming method was additionally exercised **cross-machine and
cross-platform** — Linux grpcurl against the Windows/Delphi server over a real
interface rather than loopback — which rules out both loopback artifacts and
same-implementation bias in one run.

Incremental *arrival* is not what grpcurl establishes here; it is inherited
from `PushStreamData`, already timing-validated on all four driver x platform
combinations — see [streaming.md](streaming.md#testing).

## Repeated fields

Declare a `repeated` proto3 field as a `TArray<T>` published property. `T` may
be any supported scalar, an enum, or a nested message class.

```pascal
[TGrpcMessage]
TSearchResult = class
private
  Fids:  TArray<Integer>;
  Ftags: TArray<string>;
  Fhits: TArray<THit>;
public
  destructor Destroy; override;
published
  [TProtoMember(1)] property ids:  TArray<Integer> read Fids  write Fids;
  [TProtoMember(2)] property tags: TArray<string>  read Ftags write Ftags;
  [TProtoMember(3)] property hits: TArray<THit>    read Fhits write Fhits;
end;
```

**Ownership — this one bites.** The decoder allocates one instance per repeated
*message* element and hands it to the array. Nothing else frees them, so the
containing class must:

```pascal
destructor TSearchResult.Destroy;
var I: Integer;
begin
  for I := 0 to High(Fhits) do
    Fhits[I].Free;
  inherited;
end;
```

Omit that and every decoded response leaks one object per element — invisible
in a unit test, obvious under load.

### Wire behaviour

| Element type | Encoding |
|---|---|
| int32, int64, bool, enum, float, double | **packed** — one LEN record, no per-element tag |
| string, bytes, nested message | one tagged LEN record **per element** |

That split is proto3's, not ours: packing a length-delimited type would be
ambiguous. The decoder accepts **both** forms for packable types regardless of
what the peer chose, as proto3 requires, and appends across fragments — a
sender may split one repeated field into several records and mix the two forms
within a single message.

An empty array emits nothing. proto3 cannot distinguish "empty" from "absent",
so both decode to length 0.

> **Scalars differ here.** Repeated fields omit themselves when empty, but
> *scalar* fields are written unconditionally — including ones holding their
> proto3 default. An empty `TBytes` still costs a tag plus a zero length. This
> is a deviation from canonical proto3 (which omits defaults), harmless for
> interop but relevant if you ever byte-compare output against another stack.
> Tracked in [limitations.md](limitations.md).

### `TBytes` is not a repeated field

`TBytes` (= `TArray<Byte>`) is proto3 `bytes`, a **scalar**, and is deliberately
excluded from repeated handling. For a genuine `repeated bytes`, wrap the
element in a message class — `TArray<Byte>` will always mean `bytes`.

## Server-streaming RPCs

One request in, many responses out, then a `grpc-status` trailer. Declare it in
the `.proto` with `stream` on the response:

```proto
rpc ListGreetings (GreetRequest) returns (stream GreetResponse);
```

Register explicitly — `RegisterService<T>` reflects unary methods only, because
a streaming RPC returns a *sequence*, not a value, and has no natural
`IInvokable` shape:

```pascal
TGrpcRegistry.RegisterServerStream('/greeter.Greeter/ListGreetings',
  TGreetRequest, TGreetResponse, GreeterService.ListGreetings);
```

`AResponseClass` is the type of **each** streamed message, not a wrapper.

```pascal
procedure TGreeterService.ListGreetings(const AReq: TObject;
  const AWriter: IGrpcStreamWriter);
var
  LReq:  TGreetRequest;
  LResp: TGreetResponse;
  I:     Integer;
begin
  LReq := TGreetRequest(AReq);
  for I := 1 to 5 do
  begin
    if not AWriter.IsConnected then Break;

    LResp := TGreetResponse.Create;
    LResp.text := Format('Hello, %s! (%d of 5)', [LReq.name, I]);
    AWriter.Send(LResp);        // takes ownership — do NOT free
  end;
end;
```

**`Send` takes ownership** of each message and frees it, matching
`TGrpcInvokeMethod` where the dispatcher frees what the callback returns. A
streaming handler allocates in a loop, so caller-frees would make leaking the
default outcome rather than the exceptional one.

**Check `IsConnected` before each send.** On HTTP/2 a departed peer arrives as
`RST_STREAM` or `GOAWAY`, not as a write error, so a producing loop that
ignores it runs to completion with nowhere to send.

### Status is a trailer, and it arrives last

Returning normally yields `grpc-status: 0`. Raising yields `13 INTERNAL` with
the exception message — **but any messages already sent have gone**. A stream
cannot be recalled, and reporting the failure in the trailer is the only
mechanism gRPC has for this.

The consequence is on the client side: a streaming client must read
`grpc-status` *after* the last message. One that stops reading when messages
stop never sees it, and a failed stream then looks identical to a short one.

Internally this is why `AddTrailer` behaves differently under streaming — the
status cannot be known until the handler finishes, so trailers stay mutable
until `EndStreaming`. That is safe only because a streamed response reads its
trailer list at EOF rather than at submit time.

## Client-streaming and bidirectional RPCs

```proto
rpc JoinNames     (stream GreetRequest) returns (GreetResponse);         // many in, one out
rpc ChatGreetings (stream GreetRequest) returns (stream GreetResponse);  // many in, many out
```

```pascal
TGrpcRegistry.RegisterClientStream('/greeter.Greeter/JoinNames',
  TGreetRequest, TGreetResponse, GreeterService.JoinNames);

TGrpcRegistry.RegisterBidiStream('/greeter.Greeter/ChatGreetings',
  TGreetRequest, TGreetResponse, GreeterService.ChatGreetings);
```

Both hand the handler an `IGrpcStreamReader`. Client-streaming also gets a
dispatcher-owned response object; bidi gets a writer instead.

```pascal
procedure TGreeterService.JoinNames(const AReader: IGrpcStreamReader;
  const AResponse: TObject);
var
  LMsg: TObject;
begin
  while AReader.Next(LMsg) do
    Accumulate(TGreetRequest(LMsg).name);

  TGreetResponse(AResponse).text := Format('%d received', [AReader.Count]);
end;
```

`Next` blocks until a message arrives and returns False only once the peer
half-closes, so `while AReader.Next(LMsg) do` *is* the protocol.

**`AMessage` is owned by the reader and valid only until the next `Next`.**
Do not free it; copy out anything you need to keep. Reader-owned deliberately:
a handler loops over an unknown number of messages, so caller-frees would make
leaking the default, and a caller-supplied buffer would carry stale fields from
the previous message into any field the next one omits.

### Registering one changes when your handler runs

An inbound-streaming method is dispatched on **HEADERS**, not on END_STREAM.
It has to be — a handler that must read the body as it arrives cannot be
started after the body has finished arriving. Consequences:

- `Req.Body` is empty on these paths and always will be. The data is in the
  reader.
- The handler runs while the peer is still sending, so it occupies a worker
  for the life of the call. Size the pool with that in mind — a hundred
  concurrent bidi streams is a hundred busy workers.
- **Async dispatch is required.** `Next` blocks, and under inline dispatch the
  handler *is* the connection thread that would have to feed it. The transport
  refuses at setup rather than deadlocking later.

Everything else on the server is unaffected: paths that are not registered as
inbound-streaming keep accumulating and dispatching on END_STREAM exactly as
before.

### Proving a stream is really incremental

Harder than it looks, and worth the warning: **grpcurl buffers stdin**. With
`-d @` it reads every message before opening the RPC, so pacing the input
proves nothing about the server — the messages still arrive in one burst.

Nothing client-side distinguishes the cases either. A shell that collects a
pipeline's output stamps every line at drain time, so client timestamps show
one instant whether the server streamed or buffered. Total elapsed time does
not help: 800 ms of paced input yields ~900 ms end-to-end whether grpcurl
spent it reading stdin or the server spent it accumulating a body.

What works is stamping inside the handler — dispatch time and each read:

```pascal
WriteLn(Format('[bidi] handler entered @ %s', [FormatDateTime('hh:nn:ss.zzz', Now)]));
while AReader.Next(LMsg) do
  WriteLn(Format('[bidi]   read #%d @ %s',
    [AReader.Count, FormatDateTime('hh:nn:ss.zzz', Now)]));
```

Add them to `ChatGreetings` in `samples/grpc/Sample.Greeter.Service.pas` when
you need to answer this question; they are not kept in the sample, because the
noise would obscure the demo's normal output.

There is also a structural argument needing no timing at all, and it is the one
that actually settled this. Had the transport not entered inbound mode,
`DoDataChunk` would route to the request body, `MarkInboundEnded` would never
fire, and `ReadInbound` would time out forever against a live stream — the
handler would **hang**, not return early. A client-streaming call that
completes at all has necessarily gone through the inbound queue.

### Message framing is reassembled, not per-frame

gRPC messages have no relationship to HTTP/2 DATA frame boundaries — one frame
may carry three messages and half a fourth, and one message may span many
frames. The reader buffers and extracts whole messages.

This matters when writing tests: a decoder that assumes one message per frame
passes against a client that happens to send them that way and corrupts
against every real one. Check 05 sends three messages in a single body for
exactly that reason, and asserts the server reports having read three.

Two guards worth knowing: a single message is capped at **4 MB** (a corrupt
4-byte length prefix would otherwise let a peer make the server allocate up to
4 GB before a payload byte is validated), and a half-close with a partial
message still buffered **raises** rather than returning cleanly — otherwise a
truncated stream is indistinguishable from a short one.

## Limitations (v1.0.0)

- **No map fields** — `map<K,V>` is not yet supported. Planned.
- **Scalar variants still missing** — unsigned (`uint32`/`uint64`), ZigZag (`sint32`/`sint64`) and fixed (`fixed*`/`sfixed*`) encodings. `int32`/`int64` cover the common cases; the rest are planned.
- **Streaming RPCs are covered on h2c only** — all three shapes work; TLS/mTLS share the dispatcher, reader and writer, so a transport-specific difference is unlikely, but untested.
- **FPC requires libffi** for `RegisterService<T>`. Use `RegisterMethod` + `HORSE_GRPC_NO_FFI` to avoid the dependency.
