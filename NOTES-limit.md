# NOTES: http/limit (issue #18)

## (a) CHANGELOG bullet
- `http/limit`: tower-style layers. `limiter`/`concurrency`: a shared in-flight cap (global, per
  route, or per key with `by`) that queues (bounded length and wait, FIFO hand-off) or sheds with
  `503` + `Retry-After` problem+json; `shedder`/`load_shed`: an adaptive (AIMD on latency, queue
  age) cap; `timeout`/`timeouts`: handler timeout answering `504` with counters; `retry`: a client
  helper over `client.fetch`/`fetch_host` with a retry budget, exponential backoff with jitter,
  idempotent-methods-only default and `Retry-After`. Counters via `expose(metrics)`.

## (b) README module-table rows
| `limit.ei` | Concurrency limits (queue or shed, per route/key, adaptive), handler timeout (504), client retry with budget | docs/limit.md |

## (c) Tests that use threads (TSan list)
tests/limit_test.ei  (note: it contains handlers that trap on purpose, as middleware_test does)

## (d) Not done / caveats
- A handler cannot be cancelled mid-flight (no per-request cancel token in server.ei, none in the
  runtime): `timeout` sends 504 at the deadline and discards the late result; documented.
- `Retry-After` HTTP-date is not parsed (seconds only).
- Metric names carry the limiter name (the existing text helpers have no labels).
- `limit.middleware` converts a handler trap into a 500 without a log record (as `recover(None, ..)`).
- Streamed response bodies are sent after the slot is released.
- Under `tsan` on this machine the probe fails (glibc longjmp), so the suite skips TSan; I ran the
  test under TSan with the trap lines swapped out: no reports.
- `middleware.timeout` (503) is untouched; `limit.timeout` is the 504 form.
