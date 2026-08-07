# ICS TLS / mutual-TLS integration test

Proves the OverbyteICS provider serves **HTTPS** and enforces **mutual TLS**.
ICS's modern OpenSSL 3.x/4.x stack is the provider's distinctive value, so this
is its most important test.

| File | Role |
|---|---|
| `HorseICSTLSTestServer.dpr` | HTTPS server on **port 9111**; `GET /ping`, `POST /echo` |
| `HorseICSTLSTestClient.dpr` | Driver; exit code = number of failed assertions |
| `certs/` | Self-signed fixture PKI (shared with the other providers) |

**Delphi only** (ICS is Delphi-only — Windows + POSIX/Linux64). Needs the ICS
`Source/` path and the OpenSSL libraries that ship with ICS.

## Certificates (`certs/`)

Generated once by `certs/gen-certs.sh` (OpenSSL) and committed:

```
ca.crt / ca.key          test CA
server.crt / server.key  server cert — CN/SAN = localhost, 127.0.0.1, ::1
client.crt / client.key  client cert — for mutual TLS
```

**Test-only throwaway keys.** Copy `certs/` next to the built binaries (or run
from this `tests/` folder); both programs locate it via `FindCertDir`.

## Build

`HORSE_PROVIDER_ICS` is set inline at the top of the server `.dpr`. Add the ICS
`Source/` folder and `horse-provider-ics/src` to the search path. The client
needs `Delphi-Cross-Socket` on the search path (`TCrossHttpClient` is the HTTPS
driver, same as the ICS param test client).

## Run

**One-way TLS:**

```
HorseICSTLSTestServer           # terminal 1
HorseICSTLSTestClient           # terminal 2  → T1, T2 pass
```

**Mutual TLS** — pass `mtls` to **both**:

```
HorseICSTLSTestServer mtls      # terminal 1
HorseICSTLSTestClient mtls       # terminal 2  → T3, T4 pass
```

## What each assertion proves

| Mode | Check | Proves |
|---|---|---|
| one-way | T1 `GET /ping` → 200 "pong" | TLS handshake + HTTPS round-trip (TSslHttpServer) |
| one-way | T2 `POST /echo` → body echoed | request body survives the TLS path |
| mTLS | T3 `GET /ping` **with** client cert → 200 | `SslVerifyPeer` accepts a CA-signed client cert |
| mTLS | T4 `GET /ping` **without** client cert → rejected | `SSL_VERIFY_PEER \| FAIL_IF_NO_PEER_CERT` enforced |

## Provider config exercised

`THorseICSConfig`: `SSLEnabled`, `SSLCertFile`, `SSLPrivKeyFile`, `SSLCAFile`,
`SSLVerifyPeer`, `SSLVersionMethod` — passed via
`THorseProviderICS.ListenWithConfig(9111, Config)`, wired onto ICS's
`TSslContext` (`SslCertFile` / `SslPrivKeyFile` / `SslCAFile` / `SslVerifyPeer`).

> The `POST /echo` body is sent with `Content-Length` (not chunked) because ICS
> rejects a request body without `Content-Length` before the handler runs.
