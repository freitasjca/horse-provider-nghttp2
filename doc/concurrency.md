# Concurrency & worker pool

Route handlers run on a worker pool, not on the connection's I/O thread. This matters because HTTP/2 multiplexes: a client can have 100 streams open on one TCP connection, and running them on the pump thread means a single slow route stalls every other stream on that connection.

Measured on one connection with 50 concurrent streams against a route that sleeps 50 ms, 28-core host:

| Dispatch | Throughput | Mean latency |
|---|---|---|
| Inline (pre-2026-08) | 15.90 req/s | 2.95 s |
| Worker pool (28 threads) | **354.00 req/s** | **128 ms** |

Inline sits at the arithmetic floor — 50 ms per request, one at a time. For routes that return instantly the two are indistinguishable (~1 100 req/s either way); the pool costs a thread handoff and buys nothing when there is nothing to overlap.

## Sizing

`IoThreads` on `THorseCrossSocketConfig` sizes the pool. **0 = pick for me**, which here means one worker per core.

```pascal
var Cfg := THorseCrossSocketConfig.Default;
Cfg.IoThreads := 64;          // IO-bound routes: well above core count
THorse.ListenWithConfig(9000, Cfg);
```

CPU-bound handlers want roughly core count; handlers that mostly wait on a database or an upstream service want considerably more, since those threads are parked rather than burning CPU.

For an explicit override — including turning the pool off entirely, which is the control case when benchmarking — set it before `Listen`:

```pascal
THorseProviderNghttp2.WorkerThreads := 16;                     // pinned
THorseProviderNghttp2.WorkerThreads := WORKER_THREADS_INLINE;  // no pool
```

## Queue saturation & inline fallback (`FALLBACK-1`)

When the queue is full the provider normally answers `503` with `Retry-After` rather than stalling the connection thread (which would penalise every other stream on that connection). With `FALLBACK-1`, up to `MaxInlineFallback` slots (default: `ProcessorCount div 4`) can be served inline before falling back to 503. This rescued ~84% of overload 5xx in benchmarks at c=10 000 on `/ping`.

Monitor saturation:

```pascal
WriteLn(THorseProviderNghttp2.SheddedRequests);  // total 503s issued since Listen
```

Or via the test server's `/metrics/shed` route.

## Handler constraints

Two consequences of pool dispatch worth knowing:

- **`Req.Body` is a non-owning reference** into the transport's buffer. Never free it, and copy it before handing it to anything that outlives the handler.
- **No COM initialisation.** Handlers touching MSXML, ADO or OLE must wrap their body in `CoInitialize`/`CoUninitialize`.
