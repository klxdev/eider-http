# Services on eider-http

What a networked Eider service is built from: HTTP/1.1 in this package (eider-http), on std's
sockets, deadlines, tokens and thread pool (eider-lang's docs/runtime.md), and eider-json,
with middleware (request ids, access logs, metrics, CORS, authentication, limits and
timeouts per route) here too. JSON-RPC 2.0 on top of it is
[eider-rpc](https://github.com/klxdev/eider-rpc) (its docs/jsonrpc.md), OpenAPI 3.1
services [eider-openapi](https://github.com/klxdev/eider-openapi) (its docs/openapi.md).
This was the first piece of Eider's services layer (eider-lang's docs/design/roadmap.md,
P0.12 and the first milestone of P1.1); the decisions are C40 to C51 and C80 onwards in
eider-lang's docs/decisions.md, which also records the move into this repository (U19).

```
import std.net
import std.task
import http                   // Request, Response, headers, limits, writing messages
import http.server
import http.router

fn main() uses io, net, clock, threads {
    let mut r = router.new()
    r.get("/users/:id", |q: http.Request| -> http.Response {
        http.respond(200, "text/plain", q.param("id").unwrap())
    })
    let srv = server.listen(net.ipv4(127, 0, 0, 1, 8080), server.config()).unwrap()
    let tok = task.root()                       // cancel it (e.g. on SIGTERM) to shut down
    let stats = srv.serve(router.handler(r), tok).unwrap()
}
```

eider-rpc's `examples/kvstore` is a complete service (a key-value store and a calculator
over JSON-RPC, a REST route, graceful shutdown on SIGTERM), with an end-to-end test.
eider-openapi's `examples/todo` is a REST service described by OpenAPI (CRUD, validation,
bearer tokens, `/openapi.json`, `/metrics`, the middleware below), with an end-to-end test
that also checks the served description against a recorded golden. eider-lang's site has
the step-by-step guide to both ("Building services").

## Modules

| Module | What | Capabilities |
|---|---|---|
| `http` (http.ei) | `Request`, `Response`, `Header`, `Limits`; header lookup (case-insensitive), query parameters, percent-decoding; `write_request`, `write_response`, `chunked`; status reasons; IMF-fixdate | none |
| `http/parse` | the incremental parser for requests and responses | none |
| `http/server` | `listen`, `Server.serve(handler, token)`, `Config`, `Stats` | `net, io, clock, threads` |
| `http/client` | `connect`, `Conn.request`, `fetch`, `get`, `post` | `net, io, clock` |
| `http/router` | method + path patterns with parameters, 404/405 | none |
| `http/problem` | `ApiError`: errors as values, written as RFC 9457 problem+json | none |
| `http/middleware` | `request_id`, `access_log`, `access_log_with` (a `std/log` Logger), `errors`, `problems`, `body_limit`, `timeout`, `cors`, `bearer`, `basic`, `chain` | none; `io, clock` for `access_log` and `timeout`, `io` for `random_ids` |
| `http/metrics` | request counters, an in-flight gauge and a latency histogram, in the Prometheus text format; `by_route` labels both with the route (or operation id) | `clock` for `wrap` |
| `http/trace` | W3C Trace Context: `traceparent` in, a span per request to a sink (`log_sink`, `collect`), `inject` for outgoing calls | `io, clock` for `wrap` and `inject` |
| `http/sock` | sending before a deadline, lingering close | `net, io, clock` |
| `http/profiling` | profiler labels per route, `/debug/profile` and `/debug/heap` (eider-lang's docs/site/tooling/profiler.md) | `fs, clock` for the endpoints |

A handler is a value of type `http.Handler`, `fn(http.Request) -> http.Response`, and a
middleware an `http.Middleware`, `fn(Handler) -> Handler` (a closure takes the
capabilities of the function that writes it, so a handler can do what its author can). Besides
the message, a Request carries `peer` (the client's address, from the server), `deadline` (when
the answer is due, set by `middleware.timeout`) and `ctx` (named values middleware hands
inward: `request_id`, `principal`); a Response's `ctx` (never sent) carries values back out
to the layers around the handler. The
package's eider.toml grants its dependency nothing (json is pure); a program that uses it
grants it `net, io, clock, threads` (and `fs` with `http/profiling`'s endpoints; eider-rpc's
examples/kvstore/eider.toml).

## Architecture

**Parser** (`parse.ei`). A state machine fed bytes as they arrive: head (scanned once, byte
by byte, so every limit is checked before the head is complete), then a Content-Length
body, chunked body (size line, data, CRLF, trailers) or, for responses, a body read until
close. `next()` returns `More`, `Done(msg)` or `Bad(status, why)`; bytes after a message stay
for the next one, so pipelined requests come out one per call. After `Bad` the parser stays
failed: the connection's framing is lost and it must be closed. The tests check that every
input gives the same steps whether fed whole, byte by byte or in random pieces.

**Server** (`server.ei`), the concurrency model (C41). One accepting thread (the caller of
`serve`) and a fixed pool of worker threads (`std/task.Pool`). Each accepted connection is
a job; a worker serves it request after request with blocking-style code: wait (with a
deadline) on the connection and the stop signal, read, feed the parser, call the handler,
write the response before its deadline. It is the simplest sound model while there are no
stackless tasks (C4): no shared mutable state except one Lock of counters, a fixed number
of threads, and the handler is ordinary code. Its cost is an OS thread per connection being
served, so `workers` bounds concurrency. When the compiler makes stackless tasks, `serve`
keeps its signature and the worker loop runs as a task per connection on the event loop.

- *Back-pressure:* connections wait for a worker in the pool's bounded queue; when it is
  full, the acceptor answers `503` (`Retry-After: 1`) and closes. While any connection
  waits, a worker gives up keep-alive after its current response, so idle keep-alive
  clients can't starve new ones.
- *Deadlines (C45):* `idle_timeout` while no request is under way (a new connection, or
  between keep-alive requests: the connection is closed silently); `read_timeout` from a
  request's first byte to its last (then `408`); `write_timeout` per response (then the
  connection is dropped); `max_requests` per connection (then `Connection: close`).
- *Errors:* a request the parser refuses is answered with its status and the connection is
  closed. A response with a header that can't be written (a CR or LF in a value, a name
  that isn't a token) becomes `500`. Closing after a response is a lingering close: half
  close, drain what the client still sends (up to 1 s or 64 KiB), close, so the client reads
  the response instead of a reset.
- *Graceful shutdown (C49):* cancel the token passed to `serve`. A watcher thread blocked on
  the token wakes a waker that is never drained, so every poller watching it (the
  acceptor's and each connection's) sees the stop from then on. The acceptor takes what is
  already in the listen backlog and closes the listener; every worker finishes the request
  it is reading or handling and answers it with `Connection: close` (the stop is checked
  again when the response is written, so a request whose last bytes came after it is
  included: C105); idle connections close
  at once; a queued connection is served only if its request has already arrived. `serve`
  returns the counts when every worker is done. There is no overall drain deadline: each
  connection is bounded by its own deadlines (and handlers must not block forever).

**Client** (`client.ei`). One connection at a time to one address, kept alive while the
server allows it and opened again by the next request when it was closed. Every call takes
a deadline for the whole exchange (non-blocking connect, send, response). It skips 1xx
interim responses, knows that a response to HEAD has no body, and reads bodies by length,
chunked or until close, with the same parser and limits.

**Router** (`router.ei`). Patterns of literal segments, `:name` and a final `*rest`. The path
is split at `/` before each segment is percent-decoded, so `%2F` stays in its segment. The
most specific route wins (literal over parameter over rest, segment by segment); routes
that match the path but not the method give `405` with `Allow`; HEAD falls back to GET.
Trailing slashes are significant.

## Middleware (`http/middleware`, `http/metrics`, `http/problem`)

A middleware is a function from a handler (and its configuration) to a handler (C80). Layers
compose by nesting, outermost first. A layer applies to a whole service when it wraps the
router's handler, and to one route when it wraps that route's handler:

```eider
let m = metrics.new()
r.get("/metrics", m.handler())
r.post("/upload", middleware.body_limit(4096, middleware.bearer("api", tokens, upload)))
r.get("/report", middleware.timeout(time.seconds(2), report_pool, report))
let inner = middleware.problems(middleware.cors(cors, router.handler(r)))
let app = middleware.request_id(ids, middleware.access_log(log, m.wrap(inner)))
```

(`middleware.chain(h, layers)` applies a List of layers instead.) What each one does:

- **Request ids** (C83). A client's `X-Request-Id` is kept when it is 1 to 128 bytes of
  letters, digits and `-._:`; otherwise the id is `<prefix>-<n>`. `random_ids()` makes a
  random 8-byte prefix; `ids("t")` makes a fixed one for tests. The id is in
  `req.get_ctx("request_id")` and in the response's `X-Request-Id`.
- **Access log** (C84). One JSON line per request, written after the response is made, to any
  `stream.Writer` held in a `sync.Lock` (so lines from different workers stay whole). A line
  holds `time` (RFC 3339 UTC, ms), `id`, `peer`, `method`, `path`, `query`, `status`, `bytes`,
  `duration_us`, and `principal` when a layer inside authenticated the request. It never
  holds headers or bodies, which can carry secrets. A line that can't be written is dropped.
- **Errors as values** (C82). `errors(h)` takes a handler that returns
  `Result[http.Response, problem.ApiError]` and answers an Err with its problem+json.
  `problems(h)` rewrites exactly the package's plain-text error responses
  (`http.error_response`, such as the router's 404 and 405) as problem+json and keeps their
  headers (`Allow`, `Retry-After`). A handler's own text is left alone. Turning a *trap* into
  a 500 still needs N5.
- **Body limits per route** (C86). `body_limit(n, h)` answers 413 above `n` bytes. The
  check comes after the server has read the body (up to `Limits.max_body`, the server-wide
  ceiling), because bodies are not streams yet (N16).
- **Timeouts per route** (C85). `timeout(d, pool, h)` runs `h` on a worker of `pool` and
  sets `req.deadline`. If the answer isn't there by the deadline, the response is 503
  (problem+json, `Connection: close`). A late handler can't be interrupted (N15): it runs
  to its end on its worker and its answer is dropped. A pool of its own per slow route
  bounds the threads such handlers hold, and a handler that waits on something should wait
  only until `req.deadline`.
- **CORS** (C87). Nothing is allowed by default: `cors_config().allow_origin(o)` or
  `.allow_any_origin()`, `.allow_header`, `.expose_header`, `.with_credentials()`. A preflight
  is answered by the layer before routing: 204 with the allowed methods, the requested
  headers and `Max-Age` when the origin, the method and every requested header are allowed,
  otherwise 403. Other responses to an allowed origin get `Access-Control-Allow-Origin`
  (`*` only without credentials; otherwise the origin is echoed with `Vary: Origin`).
- **Authentication hooks** (C88). `bearer(realm, check, h)` (RFC 6750): `check(token)` returns
  the principal. `basic(realm, check, h)` (RFC 7617): `check(user, password)` returns a bool.
  A failure is 401 with `WWW-Authenticate`, with `error="invalid_token"` for a token that was
  refused. The principal is put in the request's `ctx` for the handler and in the response's
  for the layers outside. `token_table` checks a fixed table with `http.eq_ct` (constant
  time). Basic auth only belongs behind TLS (C51).
- **Metrics** (C89). `Metrics.wrap(h)` counts `http_requests_total{method, code}` (methods
  other than the seven standard ones are `OTHER`, so clients can't create series),
  `http_requests_in_flight` and the histogram `http_request_duration_seconds`, with
  Prometheus's default buckets (5 ms to 10 s) or `with_buckets`. `handler()` serves the text
  format (0.0.4), sorted for stable output. Copies share one Lock, so every worker counts
  into the same numbers.

## Limits and defaults

| What | Default | Where | Over it |
|---|---|---|---|
| Line length (request line, status line, a header, a chunk-size line) | 8 KiB | `Limits.max_line` | 414 for the request line, 431 for a header, 400 for a chunk line |
| Header fields (trailers count too) | 100 | `Limits.max_headers` | 431 |
| Whole head | 64 KiB | `Limits.max_head` | 431 |
| Body after chunked decoding | 1 MiB | `Limits.max_body` | 413 (a Content-Length above it is refused before reading) |
| Chunk size | 15 hex digits | parse.ei | 400 |
| Empty lines before a request line | 4 | parse.ei | 400 |
| Idle connection | 5 s | `Config.idle_timeout` | closed |
| Reading one request | 10 s from its first byte | `Config.read_timeout` | 408, closed |
| Writing one response | 10 s | `Config.write_timeout` | dropped |
| Requests per connection | 1000 | `Config.max_requests` | `Connection: close` |
| Connections served at once | 16 | `Config.workers` | queued |
| Connections queued | 64 | `Config.queue` | 503 |

## Security posture

- **TLS: run behind a TLS-terminating proxy** (decision C3). The server speaks plain HTTP;
  bind it to loopback or a private interface and let the proxy (nginx, HAProxy, Envoy, a
  cloud load balancer) terminate TLS. TLS 1.3 written in Eider over the libcrypto backend is
  roadmap P1.4. The server does not interpret `Forwarded` / `X-Forwarded-*`: a handler that
  trusts them must know its proxy sets them.
- **Request smuggling** (C42). The parser refuses, with 400: Content-Length together with
  Transfer-Encoding; two Content-Length fields (even equal), or one that isn't only digits;
  two Transfer-Encoding fields; Transfer-Encoding in HTTP/1.0; a final coding other than
  chunked; obs-fold; a bare CR or LF anywhere in the head or a chunk line; whitespace between
  a field name and its colon; an HTTP/1.1 request without exactly one Host. Codings other
  than chunked are 501 (nothing decodes gzip). Conflicting framing is refused in responses
  too, also where the body is ignored (HEAD, 304). After any framing error the connection is
  closed, never reused.
- **Header injection.** Framing headers (Content-Length, Transfer-Encoding, Connection) are
  written by the package from the actual body and keep-alive decision; a handler's are
  dropped. Header names must be tokens and values may not contain CR, LF, NUL or other
  controls; a response that breaks this is replaced by 500, a client request is refused
  with Err.
- **Resource limits.** Every wait has a deadline; heads, bodies and batches have limits;
  threads and queued connections are bounded (503 beyond). A slow client can hold a worker
  for at most `read_timeout` (plus 1 s of lingering close).
- **Path handling.** Percent-decoding happens per segment after splitting (no `%2F` route
  confusion); the router does not resolve `..` (a handler serving files must). Fragments in
  a request-target are refused.
- **Authentication and CORS** are middleware (above): bearer tokens or Basic credentials
  checked by a function the service gives, secrets compared in constant time, CORS refused
  unless configured. eider-openapi applies the bearer check to the operations marked
  `secured`.
- **What can still go wrong.** A handler that blocks forever holds a worker forever
  (`middleware.timeout` bounds the answer, not the thread). A trap in a handler (panic,
  overflow, out-of-bounds) ends the process, as any trap does today (needs N5). eider-rpc's kvstore
  example checks arithmetic before doing it so a caller can't crash it. There is no rate
  limiting yet.

## Testing

`tests/` (run by `scripts/test.sh`; eider-lang's verify.sh runs it too, through its
`scripts/check-tools.sh`, when this repository is next to its checkout):

- `parse_test`: valid messages, framing, pipelining, keep-alive, incremental input (each
  case is also fed byte by byte and in pieces of 2 to 7 bytes and must give the same), a
  corpus of 56 malformed and smuggling requests, every limit.
- `fuzz_test`: with a deterministic PRNG (tests/rng.ei, a fixed seed, so the output is
  fixed): 300 random valid requests and responses round-trip through the writer and parser,
  alone and pipelined three at a time, fed whole, byte by byte and in random pieces; 1500
  mutants (bytes flipped, inserted or deleted, framing headers added, CRLF turned into bare
  LF or CR, cut short, under default and tight limits) must parse identically however they
  are split, and every message the parser accepts must satisfy the framing invariants.
- `server_test`: a server on 127.0.0.1 on an ephemeral port: routing, keep-alive,
  pipelining, chunked bodies, `Expect: 100-continue`, refused smuggling, the read and idle
  deadlines, `max_requests`, back-pressure (503 and keep-alive given up), graceful shutdown
  with a request in flight.
- `middleware_test`: every middleware called directly. The timeout case uses a handler
  blocked on a channel that the test releases after the 503, so nothing sleeps. It also
  covers problem+json and the Prometheus text from fixed observations.

The threaded tests (server and middleware) are also run once under ThreadSanitizer by
scripts/test.sh. They use only loopback, never a fixed port, and never sleep to synchronise:
a server listens before its thread starts, each step waits (with a deadline) for the
response it needs, and a timeout test waits for the server to act and then checks how long
it took. eider-rpc and eider-openapi have the end-to-end tests of their examples.

## Needs (gaps found while building this)

Recorded rather than worked around; none blocks the design.

| # | Need | Where it showed | Today |
|---|---|---|---|
| ~~N1~~ | Type aliases (`type Handler = fn(Request) -> Response`) | every handler signature | done: `http.Handler`, `http.Middleware`, `jsonrpc.Method` (eider-lang's docs/compiler.md "C8.18"; C104) |
| ~~N2~~ | `\r`, `\xNN` and `\u{...}` string escapes, and literal concatenation | CRLF in messages, test corpora | done: messages are written with `\r\n` literals (eider-lang's docs/compiler.md "C8.17"); the tests keep `wire()`, where `\n` is CRLF, by choice (C104) |
| N3 | `std/net`: a send that reports would-block (`try_send`, like `try_recv`) | sock.send_by | wait for writability before every send (correct: one writer per socket) |
| N4 | Waiting on two descriptors with a deadline without a poller per connection (e.g. `fd.wait_any`, or one event.Loop per worker thread) | each connection waits on its socket and the stop signal | one epoll descriptor per connection (four system calls more per connection) |
| N5 | Containing a trap: a handler's panic or overflow ends the process | server | documented; validate input before arithmetic |
| N6 | Stackless tasks (C4) | thread per connection being served | a fixed pool; `serve` keeps its API when tasks arrive |
| N7 | References (8.6): reading a List out of a record copies it | the request path copies heads and bodies a few times | fine at these sizes, measured nothing yet |
| N8 | Comptime reflection and derive (P0.9, P0.10) | typed JSON-RPC parameters and results | decoder and encoder functions per type (`add_typed`) |
| ~~N9~~ | Iterating a Map's keys | kvstore's `kv.keys` | done (eider-lang's docs/compiler.md "C8.20"): http/metrics and eider-openapi's examples/todo iterate their Maps; eider-rpc's kvstore keeps its key list, since `kv.keys` promises insertion order (C102) |
| ~~N10~~ | Calling a function stored in a field (`(self.h)(x)`) | router | done: `self.h(x)`; a method of the same name wins (eider-lang's docs/compiler.md "C8.19") |
| N11 | Name resolution with a deadline | the client takes an `net.Addr` | `net.lookup` blocks; resolve first |
| N12 | Connection information in the handler (peer address, TLS later) | logging, rate limiting | done: `Request.peer` (TLS information later) |
| N13 | A method chain continued on the next line (a line starting with `.field(...)`, or ending with `.`; the first is done: eider-lang's docs/compiler.md "C8.25") | schema and operation builders | reassignments: `s = s.field(...)` |
| N14 | Grants checked per imported module, not against everything the program loads of a package | eider-openapi is pure but programs load http/server | openapi grants http `net, io, clock, threads` |
| N15 | Interrupting a handler (cancellation reaching blocked code; with N6) | `middleware.timeout` | 503 at the deadline; the handler finishes on its pool's worker, `req.deadline` for cooperation |
| N16 | A per-route body limit before the body is read (the router consulted after the head) or streaming bodies | `middleware.body_limit` | checked after reading, up to the server's `max_body` |
| N17 | A List literal (`["a", "b"]` is a fixed array) and `if` as a call argument (E0103) | builders, tests | `push` loops and `let`s |

## Next steps toward OpenAPI

1. **Middleware and observability:** done in a first form (above). Still to do: panics
   turned into 500 once traps can be contained (N5); a `Forwarded`-aware peer address behind
   a configured proxy; rate limiting;
   tracing (W3C `traceparent`, carried like the request id).
2. **Streaming:** request and response bodies as readers and writers (P0.4) instead of
   whole Lists, chunked responses, and `Content-Length` checked against a stream.
3. **Typed services (P1.1, eider-rpc):** with JSON derive (P0.10) and `dyn Trait` (P0.7), a service is a
   trait whose methods become `add_typed` entries and a client stub, generated from the
   types instead of written by hand; then Connect (HTTP + JSON) as the second wire format.
4. **OpenAPI (P1.2):** done in a first form in eider-openapi (its docs/openapi.md). One
   operation value drives the route, request validation and `/openapi.json`; typed handlers
   are decode / `fn(T) -> Result[U, ApiError]` / encode, with schemas written by hand. Next:
   derive the schemas, decoders and encoders from T and U (P0.9, P0.10), validate responses
   in tests, generate clients from the document, and describe JSON-RPC methods the same way
   (OpenRPC).
5. **Concurrency:** move the worker loop onto stackless tasks over std/event when the
   compiler has them (C4), keeping `serve` and the handler type; per-connection pollers go
   away (N4).
6. **TLS 1.3 in Eider** (P1.4), then HTTP/2 (P1.7) for gRPC.


## Tracing and per-route metrics

`trace.wrap(tracer, h)` joins the trace in a request's `traceparent` header (strictly parsed) or
starts one, gives the request a span id, and puts `trace_id`, `span_id`, `traceparent` and
`tracestate` in the request's context like the request id; the response carries `traceresponse`.
When `h` returns, the span (name `METHOD route`, start, duration, status, parent) goes to the
sink if the trace is sampled: `trace.log_sink(logger)` writes it as a `std/log` record,
`trace.collect(lock)` collects them. `tracer.inject(req, out)` puts a `traceparent` for a new child
span on a request this service sends, so the trace continues downstream. The access record
(`middleware.access_fields`) carries `trace_id`, which ties a log line to its span.

The router puts the matched pattern in the request's context and in the response's (`route`), and
`metrics.by_route(m)` labels `http_requests_total` with `route` and keeps a latency histogram per
route: `{route="/todos/:id",le="0.005"}`. A handler or layer that sets the response context
`operation` (an OpenAPI operation id) is labelled by that instead; requests no route took are
`unmatched`, so the label set is bounded by the routes. `metrics.new()` without `by_route` writes the
series as before. Sampling profiles of a running service are `http/profiling` with eider-profiler.
