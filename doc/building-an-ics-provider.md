# Building an ICS provider — design walkthrough

This document captures the design decisions behind `horse-provider-ics`.
If you're adding a new transport provider that has a similar single-thread-
affine engine (libuv, certain GUI frameworks), this is the closest worked
example to copy.

## The constraint that shaped everything

OverbyteICS sockets are single-thread-affine. The server runs on one
`TIcsWndControl` message loop and any socket touched from another thread
will tear in non-deterministic ways — corrupt buffers, lost responses,
sometimes a clean crash, often nothing for hours and then a heisenbug.

The two existing providers don't share this constraint:

- **mORMot's `THttpServer`** uses an internal thread pool — `OnRequest`
  fires on whichever pool thread picked up the connection. We can run the
  Horse pipeline inline, and `OutContent` / `OutCustomHeaders` are written
  back synchronously on that same thread.
- **Delphi-Cross-Socket** runs IOCP / epoll completion callbacks on a
  worker pool too. `ICrossHttpResponse.Send` is thread-safe.

ICS isn't. So the v1 design splits the work explicitly:

```
loop thread → snapshot → worker thread → marshal back → loop thread → Answer
```

## Why a snapshot record, not a smart pointer?

Three options:

1. **Pass the live `THttpConnection` to the worker.** Rejected — touching
   it off-loop is exactly what we can't do.
2. **Reference-counted wrapper around the connection.** Half-solves the
   lifetime question but doesn't address the off-loop access; the worker
   would still need to call `Conn.Receive` / `Conn.Method` / etc.
3. **Snapshot.** Copies every field we need into a plain record, transfers
   ownership to the worker. Free at the end. Compose-friendly: the same
   `TICSRequestSnapshot` is what `TICSRawRequest` wraps for
   `Req.RawWebRequest`.

Picked (3). The cost is one `string` / `TArray<string>` allocation per
request — negligible next to the pipeline itself.

## Marshaling primitive — `PostMessage` to `TIcsWndControl`

ICS gives us `WndHandler.AllocateMsgHandler(Self)` — registers a unique
`WM_USER+n` and dispatches it to `WndProc` on the owning component. We
allocate one such handler on a tiny `TIcsWndControl` descendant
(`TICSMarshalReceiver`) at server startup. Workers `PostMessage` to its
`Handle` with a token in `WParam`; the receiver's `WndProc` looks the
token up in the pending map.

Why not use `TThread.Synchronize` or `Queue`? — Those would only work if
the loop thread is the main VCL thread, which holds for console apps and
VCL hosts but not for the Windows Service shape (the listener thread that
calls `THorse.Listen` is created in `ServiceStart`). `PostMessage` to a
specific window handle is unambiguous regardless.

## Connection liveness

`THttpServer` already calls `OnClientConnect` / `OnClientDisconnect` on the
loop thread, so we maintain a `TDictionary<TObject, Boolean>` of live
connections under the same `FPendingLock` that guards the pending map.
The marshal-back handler checks this map before `AnswerString`.

The check + Answer is a TOCTOU window, but the only failure mode is
`AnswerString` raising — which we swallow. No socket corruption, no
double-free.

## Pool context lifetime

`THorseContext.Acquire` and `Release` happen entirely inside the worker
task — the context never crosses thread boundaries. The worker calls
`TICSResponseBridge.Flush` to harvest the response into a
`TICSResponsePayload` (plain strings), releases the context, and only then
posts the marshal-back message. Pool churn is bounded.

## Where `HORSE_PROVIDER_ICS` slots into Horse.pas

PATCH-HORSE-2 already structured `Horse.pas` around three axes. ICS is a
new entry on axis A (Provider). The chain extension is identical to
mORMot's: add to mutual-exclusion, add a Provider × Application-type
branch in the `uses` and `THorseProvider =` chains, add the FATAL
guards for v1's Delphi + Windows restriction.

```pascal
{$IF DEFINED(HORSE_PROVIDER_ICS)}
  {$IF DEFINED(FPC)}      {$MESSAGE FATAL ...} {$ENDIF}
  {$IFNDEF MSWINDOWS}     {$MESSAGE FATAL ...} {$ENDIF}
{$IFEND}
```

The FATAL block is *expansion*, not subtraction — every combination that
compiled pre-ICS still compiles, and every existing `.dproj` / `.lpi` is
unaffected.

## What would change for the drapid/ICS_Lazarus port

> **Reality check (2026-06-25):** this section covers the *mechanical* port
> (marshal-back, seams). It is moot in practice because **stock ICS compiles out
> OpenSSL under FPC** (`icsv97/Source/Include/OverbyteIcsDefs.inc:2429` →
> `{$IFDEF FPC}{$UNDEF USE_SSL}`), so `TSslHttpServer` does not exist on FPC and an
> ICS-on-Lazarus build would be plain-HTTP only — no advantage over the CrossSocket
> provider, which already runs on Lazarus *with* TLS. The port is **not pursued**;
> see `plans/ics-lazarus-fpc.md` for the full investigation. The notes below remain
> only as a record of the marshal-back design.

The v1 design specifically avoided anything that would force a redesign:

- All ICS-facing code lives in units behind `{$IF DEFINED(FPC)}` seams.
- The `TICSRequestView` record decouples Validate / Snapshot from the
  live ICS types; an FPC shim only has to populate this record.
- The marshal-back primitive is `PostMessage(HWND, UINT, WPARAM, LPARAM)`
  — Windows-native. The FPC port would need to either:
  1. Run only on Windows (with `LCL.WidgetSet = win32`), keeping
     `PostMessage` — straightforward.
  2. Use ICS_Lazarus's own message infrastructure on POSIX (untested
     ground; the upstream port currently tracks ICS 9.4, not 9.7).

Either way, the snapshot + worker pool + marshal-back skeleton stays.

## Things worth verifying on the Windows build box

1. **Sequential POST isolation** — A → ping → B should never see A's body in B.
2. **Concurrent POST** — 4 in-flight bodies should isolate cleanly.
3. **Slow handler** — a 5-second `Sleep` inside a route must not block
   other requests. (This is the headline reason we added the worker pool.)
4. **Mid-request disconnect** — kill the client while the worker is in
   the pipeline. No crash, no leak.
5. **TLS 1.3** — `openssl s_client -connect host:443 -tls1_3` should
   complete the handshake.
6. **mTLS** — present client cert from `ca.pem`; server must verify and
   accept; missing cert must produce TLS alert.

The shared `HorseCSTestClient` from `horse-provider-crosssocket/samples/
tests/` covers everything except 3, 5 and 6 directly — those need a
dedicated suite (`tests/HorseICSSlowHandler.dpr`, etc., not part of v1).
