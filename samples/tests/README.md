# Smoke tests

Minimal end-to-end verification that the nghttp2 provider serves HTTP/2 correctly.

**Two files**:
- `HorseNghttp2TestServer.dpr` — Horse server exposing ~12 routes on port 9200 (h2c cleartext)
- `run-smoke-tests.sh` — bash+curl driver that hits every route and checks status codes, bodies, headers, and HTTP protocol version

For a full Pascal HTTP/2 client (parity with `HorseCSTestClient.dpr`), see the roadmap in `plans/horse-provider-nghttp2.md` — v2 adds client-side libnghttp2 bindings to `Horse.Provider.Nghttp2.Native.pas`.

## Prerequisites

| Requirement | Where |
|---|---|
| **libnghttp2 ≥ 1.40** | `apt install libnghttp2-14` / `brew install nghttp2` / vcpkg |
| **HashLoad/horse ≥ 3.3.0 + NGHTTP2 hooks** | See `patches/horse-provider-nghttp2/scripts/fork-sync-workflow.md` |
| **`horse-provider-nghttp2/src/`** on the Delphi/Lazarus search path | via `boss install` or manual `boss link` |
| **curl with HTTP/2** (for smoke script) | `curl --version \| grep HTTP2` |

## Build

### Delphi (Windows)

```bat
boss install
dcc32 -B HorseNghttp2TestServer.dpr
```

Or open in the IDE and press F9. The `.dpr` sets `{$DEFINE HORSE_PROVIDER_NGHTTP2}` — no project define needed.

### Lazarus / FPC

```bash
lazbuild HorseNghttp2TestServer.dpr    # or wrap in a .lpi
```

Requires FPC ≥ 3.3.1 for the Delphi-mode dual-compilation guards.

## Run

Terminal 1 (server):
```
$ ./HorseNghttp2TestServer
HorseNghttp2TestServer — h2c on port 9200
Connect with:  curl --http2-prior-knowledge http://localhost:9200/ping
Full suite:    ./run-smoke-tests.sh
Ctrl-C to stop.
```

Terminal 2 (client):
```
$ ./run-smoke-tests.sh
Smoke suite against http://localhost:9200
─────────────────────────────────────────────────────────────
✓ HTTP/2 negotiated (prior-knowledge)  (HTTP/2)
✓ GET /ping
✓ GET /param/:id
✓ GET /param/:a/and/:b
✓ GET /query?name=alice
✓ POST /echo
✓ POST /echo (JSON)
✓ GET /header-echo (User-Agent)
✓ GET /custom-header injects X-Custom-Header  (x-custom-header: nghttp2)
✓ GET /json → Content-Type application/json  (content-type: application/json; charset=utf-8)
✓ GET /json body
✓ GET /error400  (HTTP 400)
✓ GET /nope-not-a-route  (HTTP 404)
✓ GET /large (57344 bytes — multi-DATA frame)
✓ GET /cookie-set (route body)
✓ GET /cookie-set → Set-Cookie  (set-cookie: session=abc123; Path=/; HttpOnly)
✓ GET /cookie-echo (Cookie header echoed)
✓ GET /ping → X-Content-Type-Options: nosniff  (x-content-type-options: nosniff)
✓ GET /ping → X-Frame-Options: DENY  (x-frame-options: DENY)
✓ GET /ping → Cache-Control: no-store  (cache-control: no-store)
─────────────────────────────────────────────────────────────
Passed: 20   Failed: 0
```

Exit code = failure count. Non-zero fails CI.

## What each test exercises

| Test | Provider code path validated |
|---|---|
| `HTTP/2 negotiated` | h2c preface + SETTINGS frame handshake (`Session.SendInitialSettings`) |
| `GET /ping` | Minimal HEADERS + DATA emit; baseline path through Session pump |
| `GET /param/:id` | Horse router + `Params` populated from URL |
| `GET /param/:a/and/:b` | Two-param route pattern |
| `GET /query` | Query-string parsing (RawRequest `GetQueryString` + `PopulateQueryFields`) |
| `POST /echo` | Request body accumulation (`on_data_chunk_recv_callback` → `AppendRequestBody`) |
| `POST /echo (JSON)` | `Content-Type` header on request |
| `GET /header-echo` | Request header dictionary population (`PopulateRequestHeadersInto`) |
| `GET /custom-header` | Response `AddHeader` → `CustomHeaders` → `ResponseBridge.Flush` → nv-pair emit |
| `GET /json` | `ContentType(...)` shadow-field path |
| `GET /error400` | Explicit status setting |
| `GET /nope-not-a-route` | Router miss → 404 (Horse's default) |
| `GET /large` (57344 bytes) | Multi-DATA-frame emission + nghttp2 flow control |
| `GET /cookie-set` | `Set-Cookie` header via `AddHeader` (allows duplicates) |
| `GET /cookie-echo` | Cookie header parsing (`PopulateCookieFields`) |
| Security headers | `ResponseBridge.Flush` baseline defaults (`X-Content-Type-Options`, `X-Frame-Options`, `Cache-Control`) |

## Troubleshooting

**"curl was built WITHOUT HTTP/2 support"** — install a newer curl (`>= 7.47`) linked against nghttp2. On Ubuntu: `apt install curl`. On Windows: use `curl.exe` shipped with recent Git for Windows or install via winget.

**Connection refused** — server didn't start. Check the terminal running `HorseNghttp2TestServer` for FATAL messages. Common causes: `libnghttp2` not on the loader path (see main README), port 9200 already in use.

**Every test fails with HTTP/1.1** — client didn't upgrade. This shouldn't happen with `--http2-prior-knowledge`, but verify the server binary is truly the nghttp2 one (not, say, a leftover CrossSocket build).

**Some tests fail, others pass** — the shape of the failure tells you where to look:
- HEADERS-related failures → `Response.pas` / `Session.pas` `SetHeader` / `DoSubmitResponse`
- Body mismatches → `Request.pas` `AppendRequestBody` (POST) or `ReadResponseBodyCallback` (GET body)
- 404 where a route should hit → verify Horse's router registered the pattern
- Cookies missing → `RawRequest.PopulateCookieFields` / response header emission

## HTTP/2-specific tests not yet in v1

Reserved for expansion once the corresponding provider features land:
- Concurrent multiplexed requests on one connection (needs stress test client)
- `WINDOW_UPDATE` / `RST_STREAM` protocol negotiation
- HPACK dynamic-table state across requests
- ALPN (requires v1.1 TLS)
- Server push (deprecated by browsers; v2 scope only if a use case appears)
- Trailers (v2)
