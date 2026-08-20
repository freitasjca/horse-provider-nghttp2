# TLS and mTLS

## TLS (h2 over HTTPS)

```pascal
uses Horse, Horse.Provider.Config;

var Cfg: THorseCrossSocketConfig;
begin
  Cfg := THorseCrossSocketConfig.Default;
  Cfg.SSLEnabled  := True;
  Cfg.SSLCertFile := 'tls/cert.pem';
  Cfg.SSLKeyFile  := 'tls/key.pem';
  THorse.Get('/ping', GetPing);
  THorse.ListenWithConfig(Cfg);
end.
```

Generate a self-signed cert for development:

```bash
bash samples/tests/gen-tls-cert.sh
```

Test:

```
curl --http2 --insecure https://localhost:9443/ping
```

On Windows, OpenSSL DLLs are also required — `libssl-3-x64.dll` and `libcrypto-3-x64.dll`, or their 1.1.x equivalents. See [getting-nghttp2-windows.md](https://github.com/freitasjca/Delphi-nghttp2/blob/main/doc/getting-nghttp2-windows.md) § *Also needed: OpenSSL DLLs* for where to get them, and [deployment.md](deployment.md#what-to-ship) for the full per-platform shipping list.

## mTLS (client certificate required)

Add two more fields:

```pascal
Cfg.SSLCACertFile := 'tls/ca.pem';
Cfg.SSLVerifyPeer := True;
```

Clients must present a certificate signed by `ca.pem` or the TLS handshake is rejected before any HTTP/2 data is exchanged.

Test with a client cert:

```
curl --http2 --insecure \
  --cert tls/client-cert.pem \
  --key  tls/client-key.pem \
  https://localhost:9443/ping
```

## Programmatic client (TLS + mTLS)

```pascal
var Cfg: THorseCrossSocketConfig;
Cfg := THorseCrossSocketConfig.Default;
Cfg.SSLEnabled    := True;
Cfg.SSLCertFile   := 'tls/client-cert.pem';  // mTLS: present this cert
Cfg.SSLKeyFile    := 'tls/client-key.pem';
Cfg.SSLCACertFile := 'tls/ca.pem';
THorse.ListenWithConfig(Cfg);
```

Or via `HorseNghttp2TestClient.exe --client-cert tls/client-cert.pem --client-key tls/client-key.pem`.

## Notes

- OpenSSL 3.x and 1.1.x are both supported; the version is detected at runtime via `OPENSSL_version_num` — no recompile needed when upgrading OpenSSL.
- `SSLKeyPassword` is accepted and wires `SSL_CTX_set_default_passwd_cb`, but has never been exercised against an encrypted key. If you test this, please report the result.
- TLS uses memory-BIO transport (Nghttp2.Tls v2.2): OpenSSL never holds the socket fd directly. This is the prerequisite for the epoll/IOCP event-loop engines and was validated 2026-08-16 with no regressions in the 94-check suite.
