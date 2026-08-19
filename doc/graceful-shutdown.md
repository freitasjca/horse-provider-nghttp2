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

- **IOCP event-loop driver**: graceful shutdown under load has not been re-validated with the nghttp witness gate. The old gate (`h2load started == succeeded`) measured the load generator's reaction to GOAWAY, not server delivery. Re-test with `verify-drain-delivery.sh --engine=iocp` before treating IOCP graceful shutdown as working.
- **epoll event-loop driver**: `build-fpc.sh` stage 6 reports 96/184 on the `eventloop` path. The thread driver (stage 6 default) is fully validated.
