# Streaming — Web Streams and Server-Sent Events

`Res.SendStream` works on the nghttp2 provider as of STREAM-1. v1.0.0 answered
`501` on these routes; that stub is gone.

## Using it

Identical to every other Horse provider — the handler sets a content type and
writes into the callback:

```pascal
procedure StreamNdjson(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/x-ndjson; charset=utf-8');
  Res.SendStream(GRoutes.Pull);
end;

procedure TRoutes.Pull(const AWriter: IHorseStreamWriter);
var
  I: Integer;
begin
  for I := 1 to 5 do
  begin
    if not AWriter.IsConnected then Break;
    AWriter.Write(Format('{"id":%d}'#10, [I]));
  end;
end;
```

Server-Sent Events differ only in content type and payload shape:

```pascal
Res.ContentType('text/event-stream; charset=utf-8');
Res.AddHeader('Cache-Control', 'no-cache');
Res.SendStream(GRoutes.Sse);
// inside: AWriter.Write('event: message'#10'data: {...}'#10#10);
```

`THorseStreamProc` is `procedure(...) of object` — a **method pointer**. Use a
method of a class, not an anonymous procedure: FPC without `FUNCTIONREFERENCES`
compiles no anonymous procs, and a bound method is the one form both compilers
accept. (Delphi-only code may use the `THorseStreamAnonProc` overload.)

Always check `IsConnected` before each write. On HTTP/2 a departed peer arrives
as `RST_STREAM` or `GOAWAY`, not as a socket error the write itself would
raise — a loop that ignores it runs to completion with nowhere to send.

## What HTTP/2 changes

Nothing in your handler; everything underneath it.

HTTP/1.1 has no way to express "body of unknown length" except
`Transfer-Encoding: chunked`, so providers on that protocol prefix every piece
with a hex length and terminate with a zero-length chunk. HTTP/2 has framing
built in: a DATA frame carries its own length, and the body ends when a frame
arrives with `END_STREAM`. Chunked framing on top of that is not merely
redundant — **RFC 9113 §8.2.2 forbids the header outright**.

Horse already accounts for this. `THorseStreamWriterBase.Create` clears its
`FUseChunked` flag when the request's `ProtocolVersion` is `HTTP/2`, which
`TNghttp2RawRequest.GetProtocolVersion` returns. The base class therefore
passes bytes through unframed and its `Close` emits no terminator. The provider
only has to move bytes.

## How it works

```
handler thread                         connection thread
──────────────                         ─────────────────
BeginStreaming ──── stages response ──► nghttp2_submit_response
                                          │  (HEADERS out immediately,
                                          │   data provider stays hungry)
                                          ▼
PushStreamData ──► buffer + wake ──────► read_callback
   (repeat)                                 buffered? → emit DATA frame
                                            empty?    → NGHTTP2_ERR_DEFERRED
                                                        (provider parks)
                                          ▲
                                          └── nghttp2_session_resume_data
                                              (paid in DrainPendingResponses)
EndStreaming ────── sets ended ────────► read_callback → EOF → END_STREAM
```

The mechanism reuses the async-dispatch machinery already in the session: a
streaming handler is an async dispatch that stages data repeatedly instead of
once, so `BeginAsyncDispatch` keeps the connection alive and pumping for its
whole duration.

### The trap

`NGHTTP2_ERR_DEFERRED` parks the data provider **permanently** until
`nghttp2_session_resume_data` re-arms it. That call is session-affine — only the
connection thread may make it — while `PushStreamData` typically runs on a
worker thread. The wake path (`FStreamDataReady` → `FResponseReady` +
`FOnWorkStaged`) mirrors the existing staged-response path exactly.

Miss that wake-up and the stream stalls **forever**, not merely late. The
failure is silent: status and body checks on a completed request still pass,
because the request never completes at all.

## Backpressure

`Write` parks the producing handler once the outbound backlog passes **1 MB**,
and releases it at **256 KB**.

Two watermarks rather than one: blocking until the buffer empties makes the
producer stop and start on every frame, whereas parking at the high mark and
resuming at the low one lets it refill in useful batches. The wait happens
*before* the append, not after — waiting afterwards would let the buffer
overshoot by one write of arbitrary size, which defeats the bound for a handler
emitting megabyte chunks.

What this prevents: HTTP/2 flow control throttles the **wire**, not the
producer. Without a bound, a `while True do Writer.Write(...)` loop is an
out-of-memory, not a slow response.

```pascal
// Safe now — the writer blocks rather than the buffer growing.
for I := 1 to 1024 do
begin
  if not AWriter.IsConnected then Break;
  AWriter.Write(SixtyFourKilobytes);
end;
```

Still check `IsConnected`: backpressure bounds memory, it does not notice that
a peer has gone. A producer parked against a dead stream is released by
`MarkStreamClosed`, but one looping happily against a departed peer keeps
going until it checks.

### Not under inline dispatch

`WORKER_THREADS_INLINE` runs the handler **on the connection thread** — the
same thread whose read callback would drain the buffer, after the handler
returns. A wait there could never be satisfied, so it would deadlock rather
than throttle. The producer therefore does not block in that mode, and the
buffer is unbounded by construction.

That is a property of inline dispatch, not something the writer can fix. If
you stream, use the worker pool (the default).

## Testing

| What | Where | Status |
|---|---|---|
| Status, body, ordering, content-type, concurrent streams, SSE | `HorseNghttp2TestClient` tests 33–37 | ✓ 106/106 on FPC 3.3.1, all six transport configurations |
| **Incremental arrival** (timing) | `build-fpc.sh` stage 15 | ✓ 5 events spanned 247 ms (theoretical 240 ms) |
| **Producer backpressure** (memory) | `build-fpc.sh` stage 16 | ✓ streamed 17.1 MB, peak RSS grew 2.9 MB |

Validated 2026-08-20 on FPC trunk 3.3.1 / Linux across h2c, TLS and mTLS, on
both the thread driver and the epoll event loop; and on Delphi 12 / Win64
across TLS and mTLS (106/106 each).

Incremental arrival is confirmed on **all four** driver × platform combinations,
each measured against the handler's 60 ms inter-event sleep:

| Driver | Measurement |
|---|---|
| Linux / epoll | span 247 ms (`build-fpc.sh` stage 15) |
| Linux / thread | covered by the same suite |
| Windows / thread | gaps 63 / 69 / 68 / 69 ms, span 269 ms |
| Windows / IOCP | gaps 63 / 62 / 63 / 62 ms, span 250 ms |

Both Windows figures were taken cross-machine (WSL2 → Windows host, a real
interface rather than loopback), so they rule out loopback-specific artifacts
as well as buffering.

Note what does **not** count as evidence: check 37's `total: 330 ms`, and
unstamped `curl -N` output. Both look conclusive and are not — see
[platform-coverage.md](platform-coverage.md).

The split matters. `TNghttp2Client` returns a *completed* response, so a stream
correctly delivered in five DATA frames is byte-identical to one buffered whole
and flushed at the end — **every check in the Pascal suite passes either way**.
Only `curl -N`, which prints each frame as it lands, can tell them apart. That
is why stage 15 exists and why it asserts on elapsed milliseconds rather than
on content.

By hand:

```bash
curl --http2-prior-knowledge -N http://127.0.0.1:9010/stream/sse
```

`-N` is not optional — without it curl buffers, and the arrival pattern, which
is the only thing distinguishing streaming from a slow single response, is lost.

## Limitations

- No backpressure under inline dispatch (above).
- gRPC streaming RPCs are a **separate** feature — all three shapes ship (see
  [grpc.md](grpc.md)). This page is HTTP streaming; that is `stream` in a
  `.proto`.
