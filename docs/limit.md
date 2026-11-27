# http/limit: concurrency limits, load shedding, timeouts and client retries

`limit.ei` holds tower-style layers: each takes an `http.Handler` and returns one (see
`middleware.ei`), so they nest with the rest and apply to a whole service or to one route.
The server caps connections; these cap work.

```eider
let m = metrics.new()
let render = limit.limiter(8, limit.queue(32, time.millis(500))).named("render")
render.expose(m, "render")                                 // counters on /metrics
r.post("/render", limit.middleware(render, render_handler)) // 8 at once on this route
let app = limit.concurrency(256, limit.shed(), router.handler(r)) // 256 overall, shed at once
```

## Concurrency limit

`limiter(n, policy)` caps the requests running the wrapped handler at `n`. Over the cap:

- `limit.shed()`: answer at once.
- `limit.queue(len, wait)`: wait in a FIFO queue of at most `len`, at most `wait` each, and never
  past the request's own `deadline` (`Request.deadline`).

A refusal is `503 Service Unavailable` as problem+json with `Retry-After` (1 s; change it with
`policy.retry_after_secs(n)`). The three causes (no queue or queue full, a queue that is too old,
a wait that ran out) have different `detail` text.

Fairness and the cap: a freed slot is handed straight to the oldest waiter, so a newcomer cannot
overtake the queue and the number running never exceeds `n` even for an instant (the counter
`in_flight_max` is the high-water mark). The slot is released when the handler returns, or traps
(the trap is answered 500 with `Connection: close`, as `middleware.recover` does, without a log
record). A streamed response body is sent after the handler returns and is not counted.

Per key: `.by(f)` gives each key `f(request)` (a tenant, an API key) its own cap of `n` and its
own queue. Memory is bounded by the requests in flight and queued (a key is dropped when it has
neither); keys are cut at 128 bytes. `.except(f)` lets requests (health checks) bypass the limit.
Per route: wrap that route's handler, as above.

Manual use: `lim.acquire(key, deadline)` returns 0 (admitted: call `lim.release(key)`), 2 (full or
no queue), 3 (queue too old), 5 (waited and ran out of time).

## Adaptive: `shedder`, `load_shed`

`limit.adaptive(min, max, target)` is an AIMD cap on the handler's latency: `limit` completions
at or under `target` (and not 5xx) raise it by one; a slow or failed one cuts it by a tenth, at
most once per `target`. A request that would queue behind a head that has waited longer than
`max_queue_age` (default `target` * 10) is refused at once: a standing queue only adds latency.
Starts at `max`. With `.by`, each key runs under the shared adaptive number.

## Timeout

`limit.timeout(d, pool, h)` (or `limit.timeouts().wrap(...)` to keep the counters) runs `h` on a
worker of `pool` and answers `504 Gateway Timeout` (problem+json, `Connection: close`) if it is not
done after `d` (or the request's deadline if earlier, which it sets in `req.deadline`). A pool
queue that stays full is `503` + `Retry-After` and counted as `rejected`, not as a timeout. A
trapping handler is `500`.

What the server already offers: `read_timeout`, `write_timeout`, `idle_timeout` bound the
connection, not the handler. `middleware.timeout` bounds the handler too but answers 503 and
counts nothing; this one answers 504 and counts.

Semantics: nothing in this runtime can interrupt a running handler and the server has no
per-request cancel token. So the response is sent at the deadline, and the handler runs to its end
on its pool worker with its result discarded. A handler that waits on something should wait until
`req.deadline`. A pool of its own per route bounds how many workers slow handlers hold.

Layer order: `timeout(d, pool, limit.middleware(lim, h))`. Then the slot is held until the handler
really ends. The other way round (`limit.middleware(lim, timeout(...))`) frees the slot at the 504
while the late handler still runs, and the cap bounds waiting clients, not work.

## Client retry

```eider
let rt = limit.retry().attempts(4).backoff(time.millis(100), time.seconds(2))
let resp = rt.fetch_host("api.internal", 8080, req, time.after_ms(5000))   // or rt.fetch(addr, ...)
```

`Retry.send(f, req, dl)` takes any `fn(Request, Deadline) -> Result[Response, String]`; `fetch`
and `fetch_host` use `client.fetch` / `client.fetch_host`. Defaults:

- 3 attempts in all; the last outcome is returned (a final 503 is an `Ok`).
- Retries on errors (no connection, deadline) and on 429, 502, 503, 504 (`on_statuses`).
- Only idempotent methods (GET HEAD OPTIONS TRACE PUT DELETE) or a request with an
  `Idempotency-Key` header; `any_method()` removes the rule.
- Backoff 100 ms doubled per retry up to 5 s, with equal jitter (a random value in [b/2, b)).
- `Retry-After` in seconds is honoured (the wait is the larger of it and the backoff), up to 30 s: a
  server that asks for more is not retried (`retry_after(honor, longest)`). The HTTP-date form is
  not parsed; it falls back to the backoff.
- A retry is not made when its wait would pass the deadline.
- Budget: 10 retries to start, 20% of a retry earned per request, at most 100 saved
  (`with_budget(initial, ratio_pct, cap)`), so a failing dependency sees a bounded retry rate.

`with_clock(sleep, jitter)` replaces the sleeper and the jitter for tests.

## Metrics

`lim.expose(m, name)` adds, to `m`'s `/metrics`: counters `http_limit_<name>_admitted_total`,
`_queued_total`, `_shed_total`, `_expired_total` (a part of shed: waited and ran out) and gauges
`_in_flight`, `_waiting`, `_in_flight_max`, `_limit`. `timeouts.expose(m, name)`:
`http_timeout_<name>_started_total`, `_timed_out_total`, `_rejected_total`, `_trapped_total`.
`retry.expose(m)`: `http_client_retry_requests_total`, `_retries_total`,
`_budget_exhausted_total`, `_gave_up_total`. Names are one series per limiter (the text helpers
take no labels), so give each limiter its own name. The same numbers are in `lim.counts()`.

## Threads

State is one `sync.Lock` per limiter; a waiter parks on a `sync.Parker` it registered under the
lock, and the releasing thread hands over the slot and unparks it under the lock; a waiter whose
time is up leaves the queue under the same lock, so a grant and a timeout cannot both happen.
Tests: `tests/limit_test.ei` (FIFO order, the cap under 16 threads with an atomic high-water mark,
exact shed counts behind a barrier, adaptive steps on a fixed clock, 504 and 503, retries).
