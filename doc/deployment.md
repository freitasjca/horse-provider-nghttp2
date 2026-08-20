# Deployment

Two decisions: how the binary is packaged, and what sits in front of it. The
second one is where this provider differs from every other Horse transport, so
it comes first.

## What can front an HTTP/2-only server

The provider speaks HTTP/2 exclusively. For a reverse proxy that means the
**back leg** — proxy to Horse — must be HTTP/2.

This is the part that catches people: nearly every proxy already accepts HTTP/2
from browsers, and that is the *front* leg. It tells you nothing about the back
leg, which most proxies serve over HTTP/1.1 by default. A proxy happily
negotiating h2 with Chrome will still fail to reach this server.

| Front | Back leg to Horse | Works |
|---|---|---|
| nginx `grpc_pass` | h2c | ✅ |
| nginx `proxy_pass` | HTTP/1.1 only | ❌ |
| Apache `mod_proxy_http2` + `h2c://` | h2c | ✅ |
| Apache `mod_proxy_http` | HTTP/1.1 only | ❌ |
| IIS ARR | HTTP/1.1 only | ❌ |
| None — direct | h2c or h2 | ✅ |

### nginx

`grpc_pass` is the h2c back leg. Despite the name it carries any HTTP/2 traffic,
not only gRPC, so it serves plain routes too.

```nginx
server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate     /etc/ssl/certs/api.pem;
    ssl_certificate_key /etc/ssl/private/api.key;

    location / {
        grpc_pass grpc://127.0.0.1:9010;   # h2c to Horse

        # Streaming/SSE routes: without this nginx buffers the whole
        # response and the client sees one blob at the end.
        grpc_buffer_size 4k;
        proxy_buffering  off;
    }
}
```

`proxy_pass` cannot substitute. `proxy_http_version` accepts only `1.0` or
`1.1`, so there is no configuration of it that reaches an HTTP/2-only backend.

For TLS between proxy and Horse, run the provider with `tls` and use
`grpc_pass grpcs://`.

### Apache httpd

```apache
<VirtualHost *:443>
    ServerName api.example.com

    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/api.pem
    SSLCertificateKeyFile /etc/ssl/private/api.key

    ProxyPass        / h2c://127.0.0.1:9010/
    ProxyPassReverse / h2c://127.0.0.1:9010/
</VirtualHost>
```

Requires `mod_proxy_http2`:

```bash
a2enmod proxy proxy_http2 http2 && systemctl restart apache2
```

The `h2c://` scheme is what selects the HTTP/2 back leg. With plain `http://`
Apache routes through `mod_proxy_http` and the request never completes.

### IIS

**Not supported.** ARR forwards to backends over HTTP/1.1 and exposes no
HTTP/2 back-leg option, so an nghttp2 service cannot be published through it.

Options, in order of preference: put nginx or Apache in front instead; expose
the service directly; or, if IIS is mandatory in the path, use a different Horse
provider for that endpoint — HTTP.sys is the natural Windows choice and speaks
HTTP/2 to clients natively.

### Direct exposure

Perfectly reasonable for gRPC, service-to-service traffic, and any client you
control. Two caveats for a public endpoint:

- **Browsers require TLS + ALPN** for HTTP/2. Cleartext h2c works for `curl
  --http2-prior-knowledge` and native clients, not for browsers. Run with
  `tls` and a real certificate.
- **HTTP/1.1 clients are refused, not downgraded.** There is no fallback path.
  Anything old enough to lack HTTP/2 simply cannot connect.

## In-process hosting is not available

ISAPI, Apache modules, CGI and FastCGI are **mutually exclusive with every Horse
provider**, this one included. Under those models the web server owns the
socket and hands Horse a parsed request; there is no socket left for a transport
provider to own.

`Horse.pas` enforces it at compile time:

```
{$MESSAGE FATAL 'HORSE_PROVIDER_NGHTTP2 cannot combine with HORSE_HOST_ISAPI —
                 IIS owns the socket; a self-hosted Provider cannot coexist.'}
```

There are equivalent guards for `HORSE_HOST_APACHE`, `HORSE_HOST_CGI` and
`HORSE_HOST_FCGI`. This is not a gap to work around — choosing in-process
hosting means choosing not to have a provider, and with it no HTTP/2 and no
gRPC.

## Binary shapes

All five ship with the provider. Pick one `HORSE_APPTYPE_*`, or none for
console.

| Shape | Define | Unit |
|---|---|---|
| Console | *(none)* | `Horse.Provider.Nghttp2` |
| VCL form | `HORSE_APPTYPE_VCL` | `Horse.Provider.Nghttp2.VCL` |
| Windows Service | `HORSE_APPTYPE_DAEMON` *(Windows)* | `Horse.Provider.Nghttp2.Daemon` |
| Linux daemon | `HORSE_APPTYPE_DAEMON` *(POSIX)* | `Horse.Provider.Nghttp2.Daemon` |
| FPC daemon | `HORSE_APPTYPE_DAEMON` *(FPC)* | `Horse.Provider.Nghttp2.FPC.Daemon` |
| Lazarus LCL form | `HORSE_APPTYPE_LCL` | `Horse.Provider.Nghttp2.FPC.LCL` |
| FPC HTTPApplication | *(FPC default)* | `Horse.Provider.Nghttp2.FPC.HTTPApplication` |

`Horse.Provider.Nghttp2.Daemon` is one unit with two shapes selected by build
target: a `Vcl.SvcMgr.TService` base on Windows, and a signal-handling daemon
runner (`SIGTERM`/`SIGINT`, `SIGPIPE` ignored) on POSIX.

## What to ship

Unlike every other Horse transport, this one **will not start** without a
third-party native library. Elsewhere the native dependency is either supplied
by the OS or needed only for HTTPS, so a plain-HTTP build is a single binary.
Here `libnghttp2` is mandatory whether or not you enable TLS.

| File | Windows | Linux | macOS | When |
|---|---|---|---|---|
| nghttp2 | `nghttp2.dll` | `libnghttp2.so.14` | `libnghttp2.dylib` | **always** |
| OpenSSL | `libssl-3-x64.dll`<br>`libcrypto-3-x64.dll` | `libssl.so.3`<br>`libcrypto.so.3` | `libssl.3.dylib`<br>`libcrypto.3.dylib` | TLS / mTLS / gRPC-over-TLS only |

OpenSSL 1.1.x equivalents (`libssl-1_1-x64.dll`, `libssl.so.1.1`, …) are
accepted too — the version is probed at run time via `OPENSSL_version_num`, 3.x
first, so upgrading OpenSSL needs no recompile.

Both libraries are resolved dynamically at startup, so a missing one surfaces as
a startup failure or a first-handshake failure, never a link error. Getting them:

- Windows — [getting-nghttp2-windows.md](https://github.com/freitasjca/Delphi-nghttp2/blob/main/doc/getting-nghttp2-windows.md). The curl for Windows bundle carries `nghttp2.dll` **and** both OpenSSL DLLs in one download, which is the shortest path.
- Linux — [getting-nghttp2-linux.md](https://github.com/freitasjca/Delphi-nghttp2/blob/main/doc/getting-nghttp2-linux.md). `sudo apt install libnghttp2-14` — the runtime package, not `-dev`.
- macOS — `brew install nghttp2`.

Verify what the loader actually found before shipping:

```bash
# Linux
ldconfig -p | grep nghttp2          # expect libnghttp2.so.14

# Windows — confirm the DLL matches your binary's architecture
dumpbin /headers nghttp2.dll | findstr machine
```

A 32-bit DLL beside a 64-bit `.exe` fails with the same "not found" message as a
genuinely absent file, so check the architecture before assuming the path is
wrong.

### Container images

```dockerfile
RUN apt-get update \
 && apt-get install -y --no-install-recommends libnghttp2-14 openssl \
 && rm -rf /var/lib/apt/lists/*
```

Drop `openssl` if the service runs h2c behind a TLS-terminating proxy — which,
given the back-leg constraint above, is a common shape for this provider.

## Behind a load balancer

Graceful shutdown is the piece that matters for rolling deploys, and this
provider implements it properly — see [graceful-shutdown.md](graceful-shutdown.md).
`StopListenGraceful(TimeoutMS)` sends a two-stage GOAWAY per RFC 9113 §6.8, so
in-flight requests finish and the peer learns exactly which streams it must
replay elsewhere.

Point health checks at a normal route. `THorse.IsShuttingDown` and
`THorse.ActiveRequests` are exposed for a `/health` endpoint that reports
draining state to the balancer.
