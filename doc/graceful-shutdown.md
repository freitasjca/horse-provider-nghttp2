# Graceful shutdown

`THorse.StopListenGraceful(TimeoutMS)` performs a real HTTP/2 drain:

1. Stops accepting new connections and sends each peer a GOAWAY notice (`last_stream_id = 2^31-1`) — stop opening new streams, finish what you have.
2. Waits for in-flight work **and** for every queued response to reach the socket. Waiting only for handlers to return is not enough: a worker retires the active-request counter when its handler returns, which is *before* its response has been submitted or written.
3. Sends a second GOAWAY naming the last stream actually processed — the peer can then distinguish a request that was served from one it must replay elsewhere — then closes.

`THorse.IsShuttingDown` is `True` for the whole drain window. Use it in `/health` so a load balancer takes the instance out of rotation while it drains.

## Verification

`samples/tests/verify-drain-delivery.sh` holds requests in flight across the trigger in three shapes — 1 request, 4 requests on 4 connections, and 8 streams multiplexed on 1 connection — and asserts the complete response body, not just the status code.

```bash
bash samples/tests/verify-drain-delivery.sh
```

Uses `nghttp` as the witness client (not curl — see note below).

## ⚠ WSL2 mirrored networking

If you run the server under WSL2 with `networkingMode=mirrored`, in-flight replies are dropped roughly 50% of the time. **This is an environment artifact, not a provider defect.**

A packet capture shows the client receiving and ACKing the response HEADERS, then the mirrored stack injecting a `RST` at exactly those sequence numbers — while the server's socket continues writing DATA and FIN, unaware. The loss is a race between the DATA and the injected RST, which is why it looks like a ~50% server-side rate.

**Fix:** set `networkingMode=NAT` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown`. With NAT mode all three drain shapes pass — verified 9 consecutive runs, 27/27 cases.

Full investigation, packet evidence, and nine refuted hypotheses: `plans/HANDOFF-nghttp2-shutdown-2026-08-18.md`.

## ⚠ curl 7.81 and graceful GOAWAY

curl 7.81 mishandles the two-stage GOAWAY sequence, discarding responses the server delivered correctly. Do not use curl to verify graceful shutdown — use `nghttp` (`apt install nghttp2-client`). Head-to-head over 10 runs: `nghttp` 10/10 pass, `curl 7.81` 4/10 pass — the failure is the client, not the server.

## Open items

- **IOCP event-loop driver**: **VALIDATED 2026-08-22.** All three shapes delivered — `A 1/1`, `B 4/4`, `C 8/8` — with `[driver] RESOLVED: IOCP completion port` confirmed in every server log, so the run genuinely exercised IOCP rather than the silent thread-driver fallback.

  This had been open not because the server was suspect but because there was no client. `verify-drain-delivery.sh` drives its cases with `nghttp`, which the Windows nghttp2 distribution does not ship — `getting-nghttp2-windows.md` sources the DLL from a curl build carrying `curl.exe`, not the nghttp2 CLI tools. And the procedure this note used to prescribe, `verify-drain-delivery.sh --engine=iocp`, referenced a flag that did not exist until 2026-08-22.

  Now testable two ways. On Linux, `verify-drain-delivery.sh [--engine=thread|eventloop]`, which also asserts the resolved driver matches the request. On Windows, `verify-drain-delivery.bat [thread|eventloop]`, driving `HorseNghttp2DrainCheck` — a Pascal client speaking HTTP/2 through Delphi-nghttp2 itself, so there is no cross-boundary networking and none of the WSL2 mirrored-networking RST race that fails cases A and C ~100%.

  Case C needed `TNghttp2Client` to gain `BeginRequest`/`PumpAll`/`TakeResponse` (MULTISTREAM-1): the old one-shot API pumped each request to completion before returning, so N streams sharing one connection was inexpressible — and that is the only shape exercising GOAWAY's `last_stream_id` semantics. A driver covering only A and B would have validated the two easy cases and skipped the one that matters.

  Cross-checked: the Pascal driver and `nghttp` agree on the same Linux server (3/3 each), which is what licenses trusting the driver on Windows where `nghttp` is unavailable.
- **epoll event-loop driver**: `build-fpc.sh` stage 6 reports 96/184 on the `eventloop` path. The thread driver (stage 6 default) is fully validated.
