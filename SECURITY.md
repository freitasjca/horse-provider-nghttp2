# Security Policy

## Reporting a vulnerability

**Please report privately, not as a public issue.**

Use GitHub's private reporting: the **Security** tab → **Report a vulnerability**.
That opens a private thread visible only to the maintainers, so a fix can be prepared
before the details are public.

If that is unavailable to you, open a public issue saying only that you have a security
report and asking for a contact — no details — and you will be given one.

## Report it here, or to the library?

This provider is a thin bridge. Most of the code that touches attacker-controlled bytes
lives one layer down, in
[`Delphi-nghttp2`](https://github.com/freitasjca/Delphi-nghttp2): HTTP/2 framing, HPACK,
the gRPC message prefix, the protobuf codec and TLS.

**Report to whichever repository you were looking at — do not spend time deciding.**
Both are maintained by the same person and a report in the wrong place will be moved,
not bounced. If in doubt, the library is the better guess for anything involving parsing
bytes off the wire; this repository is the better guess for anything involving Horse
request/response objects, the context pool, routing, or the provider's lifecycle and
shutdown behaviour.

## What to expect

A small project maintained by one person. No service-level agreement, and no same-day
response. What is promised: your report gets read and acknowledged; a real issue gets
fixed, released and credited to you unless you decline; a non-issue gets an explanation
rather than silence; and you will not be asked to stay quiet indefinitely — if a fix
runs long, a disclosure date is agreed together.

## Scope

In scope, roughly in priority order:

- Memory safety anywhere reachable from network input
- Anything that lets a request escape its own Horse context — the per-stream context
  pool is reused, so cross-request data leakage would be serious
- Request smuggling, header injection, or response splitting through the bridge
- TLS/mTLS configuration that does not enforce what it claims to
- Resource exhaustion driven by a *small* request — an allocation or a loop whose cost
  is disproportionate to what the peer sent

Not in scope: denial of service by sheer volume. `MaxConnections`, the bounded worker
queue, `GRPC_MAX_MESSAGE_BYTES` and the shedding path exist for that, and tuning them is
a deployment decision.

Also not in scope: vulnerabilities in Horse itself. Report those to
[HashLoad/horse](https://github.com/HashLoad/horse). If you are unsure whether an issue
is Horse's or this provider's, report here and it will be routed.

## Supported versions

Only the **latest release** receives security fixes.

| Version | Supported |
|---|---|
| 1.8.x | Yes |
| < 1.8.0 | No — depends on a `Delphi-nghttp2` older than 1.8.0, which contains two memory-safety defects in the protobuf and gRPC parsers |

Note that the provider's version alone does not determine your exposure: what matters is
the `Delphi-nghttp2` version Boss resolved. The 1.8.0 floor (`>=1.8.0`) exists precisely
so a fresh install cannot land on a vulnerable library.
