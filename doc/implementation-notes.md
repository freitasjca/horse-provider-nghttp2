# Implementation notes — `horse-provider-ics`

## Why a worker pool + marshal-back?

OverbyteICS sockets are **single-thread-affine**. The whole transport runs
on one Windows message loop driven by a `TIcsWndControl` descendant; touching
the live `THttpConnection` from another thread is undefined behaviour.

Running `THorse.Execute` inline on the loop thread would serialise every
request — one slow handler would freeze the server. We therefore:

1. **Snapshot** the request data on the loop thread into a plain
   `TICSRequestSnapshot` record.
2. **Enqueue** the snapshot to `THorseICSWorkerPool` (4–64 threads, bounded
   queue of 4 096).
3. The worker runs the pipeline against a pool-acquired `THorseContext`.
4. The worker `PostMessage`s a token back to the marshal-back receiver's
   hidden window; the loop thread looks up the response payload and calls
   `THttpConnection.AnswerString`.

This is identical in spirit to how mORMot's `THttpAsyncServer` dispatches
to its thread pool, except ICS forces us to bounce the response back to
exactly one specific thread.

## Body buffering (POST/PUT/PATCH)

For a request **with** a `Content-Length`, ICS fires `OnPostDocument` (etc.);
`StartBodyAccumulator` sets `Flags := hgAcceptData` and creates a per-connection
`TICSPendingPost` buffer keyed by the `THttpConnection` pointer. ICS then drains
body bytes via repeated `OnPostedData` callbacks; the handler calls
`Conn.Receive(...)` into a stack buffer, copies into the pending buffer, and
dispatches once `Received >= ContentLength` (capped by `MaxBodyBytes`).

**Body-less requests dispatch immediately.** When `RequestContentLength <= 0`,
`StartBodyAccumulator` calls `DispatchWithBody(..., nil, 0)` straight away — ICS
does **not** fire `OnPostedData` when there is nothing to post, so waiting in
`hgAcceptData` would hang the request (and wedge a keep-alive connection). See
*ICS server quirks* below for why a body-less PUT/PATCH reaches this handler at
all, and why a **chunked** (no-`Content-Length`) POST does **not**.

## Connection liveness

The peer can drop mid-pipeline. We track liveness via
`OnClientConnect` / `OnClientDisconnect`, which populate a
`TDictionary<TObject, Boolean>` keyed on the `THttpConnection`. The marshal-
back handler checks this map before calling `AnswerString`. If the
connection is gone, the response is silently dropped.

This is approximate — there's a TOCTOU window between the dictionary check
and `AnswerString`. The `try` block around `AnswerString` swallows any
exception that fires if the connection is closing concurrently, so the
worker pool stays healthy.

## Pool-context lifetime

`THorseContext.Acquire` and `Release` always happen **on the same worker
thread**. The context never crosses the worker → loop boundary — the worker
calls `Flush` to build a `TICSResponsePayload` (plain strings) and the
context is released immediately, before `PostMessage`. Pool churn stays
bounded under load.

## TLS

`THorseICSConfig.SSLEnabled` switches the server to `TSslHttpServer` and
allocates a `TSslContext`. ICS ships OpenSSL 3.x DLLs — the same engine
that powers modern curl / nginx. mTLS is two settings:

```pascal
Cfg.SSLCAFile     := 'ca.pem';
Cfg.SSLVerifyPeer := True;
```

TLS version selection maps to ICS's `TSslVersionMethod` (`SslVersionMethodFromConfig`):

| `TICSSslMinVersion` | ICS value |
|---|---|
| `icsSslBest` (default) | `sslBestVer` (auto-negotiate, up to TLS 1.3) |
| `icsSslTLS12` | `sslTLS_V1_2` |
| `icsSslTLS13` | `sslBestVer` |

> **Note:** ICS's `TSslVersionMethod` enum (`OverbyteIcsSslBase`) stops at
> `sslTLS_V1_2`, then `sslBestVer` — there is **no** TLS-1.3-only member (and the
> names use `_V1_`, not `_1_`). So `icsSslTLS13` maps to `sslBestVer`, which
> negotiates the highest mutually-supported protocol (TLS 1.3 when both peers
> support it) rather than forcing 1.3-only. Strict 1.3-only would additionally
> need the SslContext options (`sslOpt2_NO_TLSv1`/`_1_1`/`_1_2`) — a follow-up.

## ICS server quirks (found during v1 bring-up)

ICS's `THttpServer` enforces several HTTP rules that a request must satisfy
*before it ever reaches our handler*. These were expensive to find, so they are
recorded here.

1. **Non-GET/POST methods are gated by `Options`.** ICS only fires
   `OnPut/Delete/Patch/OptionsDocument` when the matching `hoAllowPut` /
   `hoAllowDelete` / `hoAllowPatch` / `hoAllowOptions` flag is in `Server.Options`
   (`OverbyteIcsHttpSrv` ~4926). `InternalListen` sets all four; without them
   PUT/DELETE/PATCH silently fall through to an ICS default.

2. **Body-less PUT/PATCH are rejected with 400.** `ProcessPut`/`ProcessPatch`
   always route to `ProcessPostPutPat`, which `Answer400 + CloseDelayed`s any
   request with **no `Content-Length`** (`OverbyteIcsHttpSrv:5302`) — *before* the
   document event fires. A body-less PUT/PATCH is valid (RFC 7230), so the
   provider installs a custom connection class (`THorseICSConnection`, via
   `THttpServer.ClientClass`) whose `ProcessPut`/`ProcessPatch` treat a missing
   `Content-Length` as a valid zero-length body (`FRequestHasContentLength := True;
   FRequestContentLength := 0`) before calling `inherited`. (`ProcessGet`/
   `ProcessDelete` already have a no-body escape; PUT/PATCH do not.) **This
   leniency is non-SSL only** — the SSL server uses `TSslHttpConnection`, so a
   `TSslHttpConnection`-derived equivalent is a follow-up; a body-less PUT/PATCH
   over TLS would still 400.

3. **Chunked (no-`Content-Length`) POST is rejected with 400.** Same
   `ProcessPostPutPat` rule. We can't inject `Content-Length: 0` as we do for
   body-less PUT — a chunked POST has a *real* body we'd lose. So **clients must
   send `Content-Length` on uploads** (browsers do). The param suite's multipart
   test (Section I) builds its body as bytes so `Content-Length` is sent. True
   chunked request bodies are unsupported in v1.

4. **Response header framing.** `TICSResponseBridge.Flush` keeps the trailing
   CRLF on the header block: `AnswerStream` appends exactly **one** more CRLF to
   form the blank line that ends the headers. Stripping ours left the response
   with no header/body separator, so the client hung waiting for more headers.
   (Every line `BuildHeaders` emits already ends in CRLF.)

5. **Keep-alive is disabled (one request per connection).** The provider answers
   asynchronously (deferred `AnswerString` from the marshal-back). After returning
   `hgWillSendMySelf`, ICS may start reading the **next** keep-alive request on the
   same connection before our answer is written — desyncing request/response
   pairing (off-by-one / stale bodies). `DispatchOnLoop` calls
   `THorseICSConnection.DisableKeepAlive` (`FKeepAlive := False`) before answering,
   so each request gets a fresh connection. **Trade-off:** lower keep-alive
   throughput; a future refactor could serialise per-connection (don't let ICS
   read the next request until the deferred answer is written) and restore it.

## What we deliberately don't do

- **Multipart parsing — IMPLEMENTED** (no longer in this list; see *Mirrors of
  mORMot / CrossSocket* below). Decoded via ICS's own `TFormDataAnalyser`
  (`OverbyteIcsFormDataDecoder`). Plain `application/x-www-form-urlencoded` is
  parsed inline as before.
- **WebSocket upgrade.** ICS supports WS but the Horse `ws` surface lives
  in `horse-ws` — wiring that in is a separate concern from the transport.
- **FPC support.** All `{$IF DEFINED(FPC)}` seams are kept but no FPC
  branch is exercised in v1.

## Threading model — at a glance

| Thread | Touches | Never touches |
|---|---|---|
| Loop | live `THttpConnection`, ICS window queue, `FPostBuffers`, `FLiveConns`, pending map | `THorseRequest` / `THorseResponse`, pool context |
| Worker | `THorseRequest`, `THorseResponse`, snapshot, pool context | `THttpConnection`, ICS window queue |

`FPendingLock` (a `TCriticalSection`) guards every shared map.

## Mirrors of mORMot / CrossSocket

- `Validate` returns `TRequestValidationResult` (rvOK / rvBadRequest /
  rvMethodNotAllowed / rvPayloadTooLarge) — same enum, same checks.
- `Flush` produces shadow-field-first content, falls back to
  `RawWebResponse.Content` (COMPAT-1).
- `THorseContextPool` mirrors `Horse.Provider.Mormot.Pool` and
  `Horse.Provider.CrossSocket.Pool` line for line.
- `THorseICSWorkerPool` is a near-clone of
  `Horse.Provider.CrossSocket.WorkerPool`, including the `FIX-WP-4`
  generic-over-Pointer queue trick for Delphi < 10.4 compatibility.
- **RFC 6265 cookies (PATCH-COOKIE-1).** `TICSResponseBridge.BuildHeaders`
  emits one `Set-Cookie` line per `Res.Cookie(...)` / `Res.AddCookie` entry via
  the existing `EmitHeader` path. Because ICS sends the CRLF header block
  verbatim through `AnswerString`, repeated `Set-Cookie` lines are never folded
  into one — no single-value-map problem like the CrossSocket/mORMot bridges had
  to work around. All attributes round-trip (validated by
  `THorseCookie.ToHeaderValue`); exercised by the param suite's **Section K**.
- **PATCH-SENDFILE-1.** `Res.SendFile`/`Download` materialise a response-owned
  copy of the source stream (in the shared `Horse.Response`), and `WriteBody`
  drains that owned `ContentStream` **synchronously** — so ICS needs no
  async-safe byte-send change (unlike CrossSocket's async `Send(TStream)`).
  Freeing the caller's stream right after `SendFile` is safe; exercised by
  **Section J** (wildcard `Get('/*')` + `SendFile` + `FreeAndNil`).
- **Multipart/form-data (PATCH-PARAM-1).** `TICSRequestBridge.PopulateMultipartFields`
  decodes the body with ICS's `TFormDataAnalyser` (`OverbyteIcsFormDataDecoder`,
  Delphi/MSWINDOWS) and populates `Req.ContentFields` at full parity with the
  CrossSocket / mORMot providers: text parts → `Field(name).AsString`, file parts →
  an **owned** `TBytesStream` via `AddStream(name, stream, AOwnsStream=True)`
  (THorseCoreParam frees it on pool Clear/Destroy — same as mORMot, which also
  synthesises the stream; CrossSocket passes `False` because its parts are owned by
  `THttpMultiPartFormData`). Sibling `<name>_filename` / `<name>_contenttype`
  entries mirror the other providers. Exercised by **Section I** (I1–I3).
  *Fidelity note:* the ICS snapshot stores the body as a `string`, so a truly binary
  upload's byte fidelity is bounded by that capture — fine for text/UTF-8 parts.

## Open issues / known limitations

- **Chunked request bodies are unsupported.** ICS rejects any POST/PUT/PATCH
  with no `Content-Length` (400 — see *ICS server quirks* #2/#3), so a chunked
  upload never reaches `TICSPendingPost`. Clients must send `Content-Length`
  (browsers do). Bodies are fully buffered (sized from `RequestContentLength`,
  capped by `MaxBodyBytes`); there is no streaming-into-the-handler path yet.
- **Keep-alive is disabled** — one request per connection, to avoid the
  deferred-answer / next-request desync (*ICS server quirks* #5). A future
  per-connection serialisation refactor could restore it.
- **Receive() loop** in `HandlePostedData` assumes ICS's non-blocking
  receive returns 0 when there's no data ready. If a future ICS revision
  changes that contract the loop needs to honour `WSAEWOULDBLOCK`
  explicitly.
- **Marshal-back during Stop.** If a worker finishes the pipeline *after*
  `Stop` has freed `FReceiver` but *before* the worker's `Decrement` runs,
  the `PostMessage` is silently dropped. The pool entry is cleaned up by
  `Stop`'s pending-map sweep. Tested by killing the listener while requests
  are in flight.
