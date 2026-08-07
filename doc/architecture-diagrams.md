# Architecture diagrams — `horse-provider-ics`

## Request lifecycle

```
                   ┌─────────────────────────────────────────────┐
                   │            ICS message-loop thread          │
                   │                                             │
   client ────►   THttpServer.OnGetDocument(Conn, var Flags)     │
                   │  Validate                                   │
                   │  Snapshot ──┐                               │
                   │             │                               │
                   │             ▼                               │
                   │  Flags := hgWillSendMySelf                  │
                   │  (loop keeps serving other connections)     │
                   │                                             │
                   └───────────┬─────────────────────────────────┘
                               │ Submit(task)
                               ▼
                   ┌─────────────────────────────────────────────┐
                   │              Worker pool thread             │
                   │                                             │
                   │  Acquire pool ctx                           │
                   │  Populate THorseRequest from snapshot       │
                   │  Ctx.Response.SetCSRawWebResponse(...)      │
                   │  THorse.Execute(Req, Res)                   │
                   │  payload := Flush(Res, banner)              │
                   │  Release pool ctx                           │
                   │                                             │
                   └───────────┬─────────────────────────────────┘
                               │ PostMessage(loop, WM_X, token)
                               ▼
                   ┌─────────────────────────────────────────────┐
                   │            ICS message-loop thread          │
                   │                                             │
                   │  TICSMarshalReceiver.WndProc                │
                   │  lookup pending[token]                      │
                   │  if conn still alive:                       │
                   │    Conn.AnswerString(status, ct, hdrs, body)│
                   │  free snapshot + pending                    │
                   └─────────────────────────────────────────────┘
                               │
                               ▼
                           response → client
```

POST/PUT/PATCH adds one stage: `OnPostDocument` sets `hgAcceptData`;
`OnPostedData` fires repeatedly until `Received >= ContentLength`, then
the same `Snapshot → Submit → … → AnswerString` chain runs. A **body-less**
PUT/PATCH (no `Content-Length`) skips that stage and dispatches immediately.
Two ICS rules shape this: non-GET/POST methods are gated behind `Server.Options`,
and ICS rejects no-`Content-Length` body methods with 400 — the provider works
around both (see `implementation-notes.md` → *ICS server quirks*).

## Type relationships

```
THorseProviderICS  (= THorseProvider when HORSE_PROVIDER_ICS is set)
  │
  ├── owns THttpServer / TSslHttpServer
  ├── owns TSslContext  (when SSLEnabled)
  ├── owns TICSMarshalReceiver  (TIcsWndControl descendant)
  └── owns THorseICSWorkerPool singleton

per-request:
  TICSRequestSnapshot
    └── PICSRequestSnapshot is the worker's view; freed on loop after Answer

  TICSPendingRequest
    ├── Token (key into FPendingMap)
    ├── Conn  (THttpConnection — loop-thread access only)
    ├── Snapshot   ← worker owns until marshal-back
    └── Payload    ← worker writes; loop reads
```

## Inheritance — hybrid adapter

```
TInterfacedWebRequest (generic — horse/src/Horse.Provider.RawAdapters, upstream ≥3.3.0)
        ↑
TICSWebRequest        (thin constructor — Horse.Provider.ICS.WebRequestAdapter)
        ↑
takes IHorseRawRequest = TICSRawRequest (Horse.Provider.ICS.RawRequest)
        │
        └── wraps PICSRequestSnapshot (snapshot, not live connection)
```

Identical structure for response:

```
TInterfacedWebResponse
        ↑
TICSWebResponse
        ↑
takes IHorseRawResponse = TICSRawResponse (stub — header writes captured by
                                            inherited CustomHeaders TStrings)
```

## PATCH-HORSE-2 three-axis model — where ICS fits

| Axis | Define | Value with ICS |
|---|---|---|
| A · Provider | `HORSE_PROVIDER_ICS` | ICS |
| B · Application type | implicit / `HORSE_APPTYPE_VCL` / `HORSE_APPTYPE_DAEMON` | Console (default) / VCL / Service |
| C · Host-managed | — | none (ICS self-hosts) |

`HORSE_APPTYPE_LCL` and `HORSE_HOST_*` × `HORSE_PROVIDER_ICS` are
compile-time fatal — LCL implies FPC (v2), and host-managed shapes
own the socket.
