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

**Both fields are required.** `SSLVerifyPeer := True` without `SSLCACertFile` makes `Listen` raise. Before 1.10.0 that configuration started a server that verified **no** client certificate: mTLS requested, plain TLS delivered, nothing reported. The CrossSocket provider has always refused it, and it reads the same config record. `SSLCACertFile` on its own is still allowed, because it claims no verification.

Test with a client cert:

```
curl --http2 --insecure \
  --cert tls/client-cert.pem \
  --key  tls/client-key.pem \
  https://localhost:9443/ping
```

## Cipher configuration

```pascal
Cfg.SSLCipherList := 'ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384';
```

`SSLCipherList` restricts **TLS 1.2 and below**, in OpenSSL rule syntax (aliases, `!` exclusions, `@SECLEVEL`). Empty leaves OpenSSL's default.

- **Since 1.10.0. Before that, this field was accepted and ignored.** A restriction set on an older release did nothing, so re-check any deployment that relied on it.
- **It does not affect TLS 1.3.** OpenSSL configures TLS 1.3 suites through a separate call. With OpenSSL 3.x, most clients negotiate TLS 1.3, so this list only governs clients limited to TLS 1.2. Use `SSLCipherSuitesTLS13` (below) for TLS 1.3.
- An `@SECLEVEL=n` in the rules sets the context-wide security level, and TLS 1.3 handshakes obey it too.
- Rules that match no TLS 1.2 cipher make `Listen` raise, naming the rules.
- An unknown name next to a valid one is silently dropped by OpenSSL and **not** detected, because rule strings use aliases and can't be checked name by name. Check what was negotiated: `openssl s_client -connect host:9443 -tls1_2 -alpn h2` prints `Cipher is ...`.
- **For HTTP/2 over TLS 1.2, keep an RFC 7540 §9.2.2-permitted cipher** (ECDHE with an AEAD such as AES-GCM or ChaCha20). The server does **not** refuse a cipher on the RFC's Appendix A black list: measured, a server restricted to `AES128-SHA256` completes the handshake and serves HTTP/2, and `curl --http2` gets `200`. The RFC only says an endpoint *MAY* refuse such a connection with `INADEQUATE_SECURITY`; some clients do (browsers are documented to), curl did not. So such a list works for some clients and fails for others — keep a permitted cipher. Measured by `samples/tests/build-fpc.sh` stage 10d, which only reports and never fails the run.

Verified on the wire by `samples/tests/build-fpc.sh` stage 10b and `run-tests.bat` (`openssl s_client` as the peer): the configured cipher is negotiated, an excluded one is refused, and TLS 1.3 is unaffected.

### TLS 1.3 suites and minimum version (1.11.0)

These two fields come from the shared `THorseCrossSocketConfig` and need a Horse release that carries them (HashLoad/horse #597).

```pascal
Cfg.SSLCipherSuitesTLS13 := 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256';
Cfg.SSLMinVersion        := htvTLS13;   // TLS 1.3 only
```

- **`SSLCipherSuitesTLS13`**: exact, case-sensitive suite names, colon-separated, in priority order. Empty leaves OpenSSL's default. OpenSSL silently drops a misspelled name next to a valid one, so the provider reads the effective list back and `Listen` raises, naming every suite that was dropped.
- **`SSLMinVersion`**: `htvDefault` (no call, OpenSSL's floor), `htvTLS12` (TLS 1.2 or newer; TLS 1.3 still allowed) or `htvTLS13` (TLS 1.3 only). The minimum is read back from the context; if it did not take, `Listen` raises.
- Neither changes the TLS 1.2 rules, and the minimum does not change the maximum.

Verified on the wire by stage 10c in both harnesses:

- the configured TLS 1.3 suite is negotiated, an excluded one is refused, and TLS 1.2 is untouched;
- a suite typo stops the server at startup, naming the typo;
- `minver13` refuses a TLS 1.2 client, while `minver12` still serves TLS 1.3.

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
- TLS uses memory-BIO transport (`Nghttp2.Tls`, since Delphi-nghttp2 1.0.0): OpenSSL never holds the socket fd directly. This is the prerequisite for the epoll/IOCP event-loop engines and was validated 2026-08-16 with no regressions in the 94-check suite.
