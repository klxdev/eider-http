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
| `http/middleware` | `request_id`, `access_log`, `access_log_with` (a `logging` Logger), `errors`, `problems`, `body_limit`, `timeout`, `cors`, `bearer`, `basic`, `recover`, `chain` | none; `io, clock` for `access_log`, `timeout` and `recover`, `io` for `random_ids` |
| `http/metrics` | request counters, an in-flight gauge and a latency histogram, in the Prometheus text format; `by_route` labels both with the route (or operation id) | `clock` for `wrap` |
| `http/trace` | W3C Trace Context: `traceparent` in, a span per request to a sink (`log_sink`, `collect`), `inject` for outgoing calls | `io, clock` for `wrap` and `inject` |
| `http/compress` | `Content-Encoding` both ways: `responses(options, h)` (gzip/deflate, opt-in zstd; `Accept-Encoding` negotiation, allow-list, size floor, `Vary`, weak ETags, streamed bodies), `requests(limits, h)` (decoding under `compression.Limits`), `never(resp)`, `except(f)`; the server and the client use `decode_request` / `decode_response` | none |
| `http/static` | serves a directory for a rest route: media types, ETag/`If-None-Match`, cache rules for hashed names, index files, SPA fallback, strict path checks | `fs` |
| `http/health` | `/healthz` (liveness), `/readyz` (readiness with checks, 503 while draining), the drain flag | none |
| `http/service` | production defaults: `handler(router, options)` stacks request ids, trusted-proxy peer, access log, metrics, rate limit, trap containment, problem+json and mounts the probes and `/metrics`; `serve`/`run` drain on SIGTERM | `net, io, clock, threads, fs` |
| `http/proxy` | the client address behind trusted proxies: `trust_none().allow("10.0.0.0/8")`, `.use_forwarded()`, `middleware(trust, h)`, strict IP and CIDR parsing | none |
| `http/ratelimit` | GCRA rate limiting per client address (or any key), a bounded table, 429 + `Retry-After` | `clock` for `middleware` |
| `http/sse` | server-sent events over a chunked response: `response(run)`, `Stream.event/data/comment/retry`, `format_event` | none |
| `http/ws` | WebSockets (RFC 6455): `accept` (the handshake and the upgrade), `Conn.recv/send_text/send_binary/ping/close`, the frame codec, SHA-1, a test client (`dial`, `dial_conn` over any `client.Conn`, so wss) | `clock` for `recv`, `dial` needs `net, io, clock` |
| `http/transport` | the bytes under a connection, plain or TLS: `Transport`, `Secure`, `Acceptor`, `Connector`; every read, write, wait and close of the server, the client and `ws.Client` goes through it. Imports no TLS | `net, io, clock` |
| `http/secure` | https: `server_from_files/pem/der(...)` + `with_client_auth_pem`, `with_handshake_timeout`, `with_max_handshakes`, `acceptor()`, `reload`; `client_system()`, `client_roots_pem(pem)`, `client_insecure_skip_verify_for_tests()`, `connect_host`, `connect_url`, `get_url`, `dial_ws` (`wss://`); the only module that imports eider-tls (docs "TLS") | `net, io, clock, fs` |
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

**Server** (`server.ei`), the concurrency model (C41). One accepting task (the caller of
`serve`) and one lightweight task per connection (eider-lang C830). Each accepted connection
gets a task that serves it request after request with blocking-style code, parking when it waits: wait (with a
deadline) on the connection and the stop signal, read, feed the parser, call the handler,
write the response before its deadline. No shared mutable state except one Lock of counters, and the handler is ordinary code. A
connection waits for its socket and the server's stop signal together (`fd.wait_ready2`, so
there is no poller per connection); tens of thousands of connections are tens of thousands of
parked tasks. `workers` is the number of connections served at once (default 10,000) and
`queue` the number that may wait for a slot; a handler that computes without waiting occupies
a scheduler thread.

- *Back-pressure:* connections wait for a slot (one of `workers`), at most `queue` of them; when that is
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
  the token wakes a waker that is never drained, so every wait that watches it (the
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
a deadline for the whole exchange (non-blocking connect, send, response). `connect_host`, `get_host`, `post_host`
and `fetch_host` take a host name (eider-lang#59): it is resolved with `net.lookup_by` before the
deadline, an address literal skips the resolver, the addresses are tried in turn with an equal share of
the time left, a `Conn` made from a name resolves again when it reconnects, and a name that could not
be a host (control bytes, spaces, `/`, `@`, `#`, `?`, `%`, non-ASCII) is refused before anything is
resolved or sent. It skips 1xx
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
  headers (`Allow`, `Retry-After`). A handler's own text is left alone.
- **Traps become 500s** (N5, eider-lang#54). `recover(lg, h)` runs `h` under `task.catch`
  (eider-lang C803): a panic, overflow, out-of-bounds index or failed assert is answered `500
  Internal Server Error` (the standard text; nothing of the trap reaches the client), logged to
  `lg` (method, path cut at 200 bytes, the trap's text with file and line) and the connection is
  closed after the response. Put it inside the access log and `metrics.wrap` so they see the 500
  (a trap that unwinds through `metrics.wrap` would leave its in-flight gauge raised). Without it
  `http/server` does the same around every handler as a last resort (`Config.log`, `Stats.traps`).
  `timeout`'s pool worker contains a trap too and the layer answers 500 at once instead of 503 at
  the deadline. What is safe afterwards: no drops run for what the handler was building (a
  leak, bounded by one request), a `sync.Lock` it held in `modify` stays empty (so a handler that
  traps inside a lock shared with other requests takes that lock's value; keep such state out of
  reach of code that can trap, or check before computing), a stack overflow is not contained.
- **Body limits per route** (C86). `body_limit(n, h)` answers 413 above `n` bytes, after the
  server has read the body (up to `Limits.max_body`, the server-wide ceiling). To refuse
  before reading, give the route a plan: `r.route_with("POST", "/upload", http.Plan(4096,
  false), h)` and `cfg.plan = r.planner()` (see "Streaming bodies" below).
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
| A decoded request body (`Transfer-Encoding: gzip, chunked`) | the route's body limit, and 1100 times the compressed size above 4 MiB | `Config.decode_max` (0: the route's limit) | 413 (bomb), 400 (corrupt, cut short), 501 (other codings) |
| Empty lines before a request line | 4 | parse.ei | 400 |
| TLS handshake (https) | 10 s from taking a worker slot; 128 at once | `ServerTls.with_handshake_timeout`, `with_max_handshakes` | closed, `Stats.tls_failed` |
| Idle connection | 5 s | `Config.idle_timeout` | closed |
| Reading one request | 10 s from its first byte | `Config.read_timeout` | 408, closed |
| Writing one response | 10 s | `Config.write_timeout` | dropped |
| Requests per connection | 1000 | `Config.max_requests` | `Connection: close` |
| Connections served at once | 10,000 | `Config.workers` | queued |
| Connections queued | 64 | `Config.queue` | 503 |

## Security posture

- **TLS: in the process (`http/secure`, section "TLS" below) or at a proxy.** The server speaks
  plain HTTP unless it is given an acceptor (`service.options().with_tls(...)`); then it serves
  https only on that port, TLS 1.3, by eider-tls. Either is a supported deployment: terminate at a
  proxy (nginx, HAProxy, Envoy, a cloud load balancer; bind the server to loopback or a private
  interface) or in the process; the section "TLS" says who terminates what and how it meets the
  forwarded headers. The server does not interpret `Forwarded` / `X-Forwarded-*` by itself:
  `Request.peer` is the connection's address (over TLS too: the TCP peer). `http/proxy` (below) replaces it with the client's
  from those headers, only for connections from proxies the service lists.
- **Request smuggling** (C42). The parser refuses, with 400: Content-Length together with
  Transfer-Encoding; two Content-Length fields (even equal), or one that isn't only digits;
  two Transfer-Encoding fields; Transfer-Encoding in HTTP/1.0; a final coding other than
  chunked; obs-fold; a bare CR or LF anywhere in the head or a chunk line; whitespace between
  a field name and its colon; an HTTP/1.1 request without exactly one Host. One of gzip,
  deflate or zstd in front of `chunked` is decoded (below, "Compression"); any other coding
  is 501. Conflicting framing is refused in responses
  too, also where the body is ignored (HEAD, 304). After any framing error the connection is
  closed, never reused.
- **Header injection.** Framing headers (Content-Length, Transfer-Encoding, Connection) are
  written by the package from the actual body and keep-alive decision; a handler's are
  dropped. Header names must be tokens and values may not contain CR, LF, NUL or other
  controls; a response that breaks this is replaced by 500, a client request is refused
  with Err.
- **Forwarded headers** (eider-http#3). *Nothing is trusted by default*: a service that does
  nothing keeps the connection's address and ignores `X-Forwarded-For`, `Forwarded` and
  every `X-Forwarded-*`. `proxy.middleware(trust, h)` believes a header only when the connection
  comes from an address in a CIDR range given to `allow` (a `/0` range is refused; unix-socket
  proxies need `allow_unix()`), reads only the one header the operator names (`X-Forwarded-For`, or
  `Forwarded` after `use_forwarded()`: a client's copy of the other one, passed through by a
  proxy that doesn't strip it, is not read), and walks the list from the right, skipping trusted
  proxies, so what a client put at the left of the list never counts. The input is bounded
  (2 KiB of header text in all lines, 16 elements) and strict: an element the walk reads that is
  not an IP address literal (names, `unknown`, `_hidden`, octal-looking `010.0.0.1`, zone ids, a
  port over 65535, an unterminated quote, control bytes) makes the whole header ignored, and
  the peer stays the proxy. The new `peer` is rebuilt from the parsed address bytes, so nothing the
  header held can reach logs or other headers, and addresses are canonical (IPv4-mapped IPv6 is
  IPv4). The proxy must set or append to the header; one that passes a client's header
  through unchanged makes the *rightmost* element, the proxy's own appended one, the client.
- **Decompression bombs.** Every decoder runs under `compression.Limits`: the output may not pass
  the body limit (`max_output`, set to what the route accepts) nor 1100 times the input read (above
  4 MiB), and a zstd frame may not ask for a window over 8 MiB; the limit is checked before the
  bytes are produced, so a few kilobytes cannot become gigabytes in memory. A bomb is 413, an
  unsupported coding 415, bad data 400, none of them a trap (the compression tests alter every
  byte of their vectors). Bodies are decoded after the framing limits, so the compressed size is
  already bounded by `max_body`.
- **BREACH.** A compressed response that holds a secret and text the attacker controls and the
  response reflects leaks the secret through its size. `http/service` compresses the allow-listed
  types by default (see "Compression"); exempt such responses with `compress.never`, `except`, or
  `no_compression()`, and mask secrets per response.
- **Rate limiting** (eider-http#3). `ratelimit.middleware` limits per client address (IPv6 per
  /64) with the generic cell rate algorithm; put `proxy.middleware` outside it behind a proxy, or
  all clients share the proxy's bucket. The table is bounded (`max_keys`, 10,000; beyond that new
  clients share one bucket, so spraying addresses throttles the sprayer) and a key is cut at 128
  bytes. 429 carries `Retry-After`. `except` skips health checks.
- **Static files** (eider-http#7). `http/static` refuses with 404 every request path with an
  empty segment (so no absolute path, no `//`), a `.` or `..` segment, a segment starting with a
  dot (dot files and directories are never served; `.well-known` only on request), bytes below
  0x20, DEL, `\\` or NUL, invalid UTF-8, or more than 4096 bytes; all after the router's single
  percent-decoding, so `%2e%2e`, `..%2f`, `%00` and overlong UTF-8 are checked as what they
  decode to, and `%252e%252e` is only a file literally named `%2e%2e`. The resolved path
  (`fs.canonical`, symlinks followed) must lie inside the canonical root by path components, so a
  symlink out of the root, or to a sibling directory with the same prefix, is 404 and one inside
  works; the target must be a regular file. Directories are never listed; an index that is a
  link out of the root is refused too. The `/dir` redirect is built from the validated request
  path (starting with exactly one `/`), so it can't become `//host`. Left open: a link swapped
  between the check and the read by someone who can write in the root; do not make the root
  writable by untrusted users. Files are read whole (default limit 16 MiB).
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
  overflow, out-of-bounds) is contained at the handler call: 500, logged, connection closed; the
  leak of what it was building is bounded by one request (see "Traps become 500s"), but a stack
  overflow still ends the process.

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
- `trap_test`: handlers that panic, overflow and index out of bounds are answered 500 with the
  standard text and nothing of the trap (checked for the secret in the panic message, the file
  name), the connection is closed after the 500 (also with a pipelined request behind), a trap
  while a streamed request body is half read and in a streamed response's producer do not leak the
  connection, 40 traps mixed with good requests leave the counts right (`Stats.traps`), and
  `recover` under `metrics.wrap` shows the 500 and an in-flight gauge of 0.
- `static_test`: a fixture tree under `target/` (rebuilt every run) with a secret outside the
  root and symlinks to it (a file, a directory, a sibling sharing the root's prefix, an absolute
  target, a dangling link, an index that links out): about 80 traversal and hostile paths (`..`,
  `%2e%2e`, `..%2f`, `..%5c`, overlong UTF-8, `%00`, control bytes, `//`, absolute, dot files, double
  encoding, `.well-known`), each checked to be 404 and never to leak the secret, including `..` that
  would have stayed inside the root; media types, hashed-name caching, ETag and `If-None-Match`
  (list, `*`, weak), HEAD and method checks, the directory rules and redirect (with a hostile
  `//host` path), the SPA fallback (which does not mask a missing asset or a refused path), size
  limit, options and root errors, a root reached through a symlink.
- `client_host_test`: a client that connects by name (`localhost`, an IPv4 literal, an IPv6
  literal with nothing listening), the `Host` header, a name's `Conn` reconnecting on a new connection,
  16 invalid host names (CR/LF, spaces, `/`, `@`, `#`, `?`, `%`, brackets, non-ASCII...) refused before
  resolution, bad ports, and deadlines on a name that does not resolve.
- `proxy_test`: the default trusts nothing; spoofed `X-Forwarded-For`/`Forwarded` from untrusted
  peers (also just outside a range, or from garbage peers); the walk from the right (forged left
  sides, trusted hops, every hop trusted); about 30 malformed addresses (octal, short, long, ports,
  zone ids, brackets, names, `unknown`, `_hidden`); header injection (CR, LF, NUL, DEL, controls,
  non-ASCII) with the new peer shown to be rebuilt from bytes; sizes (16 and 17 elements, 2 KiB and
  over, a megabyte of commas, 5000 header lines, a 200-digit address); canonical spellings
  (IPv4-mapped IPv6 as IPv4, one spelling per IPv6 host); `Forwarded` quoting; the header the
  operator did not choose is never read; unix peers; CIDR parsing and range boundaries.
- `ratelimit_test`: the algorithm on a fixed clock (burst, refill, refusals cost nothing, a clock
  going backwards, a long quiet time), the keys (ports, mapped IPv6, /64, long keys), a table
  that stays at `max_keys` under 10,000 distinct keys, 8 threads on one key getting exactly the
  burst, the middleware (429, `Retry-After`, `except`, `by`), and the pair with `proxy`: forged
  headers from a direct client or forged left sides behind a proxy buy no extra bucket.
- `service_test`: liveness and readiness (checks that fail or trap are named, error text is
  not sent, `no-store`, draining flips readiness only), the default stack (request ids,
  problem+json 404, metrics by route, profiler endpoints absent), forwarded headers ignored from
  untrusted peers and honoured from a trusted one, the limiter exempting the probes, a real server
  whose readiness turns 503 on the stop token while `/hello` and `/healthz` still answer through
  the delay, then refuses connections.
- `observe_test`: `add_source`, the server's and the rate limiter's series on a live `/metrics`
  next to per-route series with a contained trap (500), a 404 and rate-limited 429s; the profiling
  endpoints in a build without `--profile` (404 when not mounted, 501) and `is_local` (including
  `127.evil.example`). `tests/profiled/profiling_test` runs with `--profile=cpu,mem`: the endpoints
  answer a profile (version 1 header, the program's files), 403 for remote peers, 400 for bad
  `seconds`.
- `server_test`: a server on 127.0.0.1 on an ephemeral port: routing, keep-alive,
  pipelining, chunked bodies, `Expect: 100-continue`, refused smuggling, the read and idle
  deadlines, `max_requests`, back-pressure (503 and keep-alive given up), graceful shutdown
  with a request in flight.
- `compress_test`: negotiation (q-values, `*`, `q=0`, case, two fields, malformed), the allow-list,
  the size floor, HEAD/Range/204/206/304/101, encoded and `no-transform` responses, ETags and `Vary`,
  streamed responses (and `text/event-stream` decodable after every event), request bodies in all
  four codings, 415/413/400 including bombs (gzip, zstd, deflate, ratio), every truncation and every
  flipped byte of a gzip body, a streamed request body, `Transfer-Encoding: gzip, chunked` and the
  client's decoding over loopback, `http/service`'s defaults, and precompressed static files.
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
| ~~N5~~ | Containing a trap: a handler's panic or overflow ends the process | server | done: `task.catch` (eider-lang C803) around every handler in `http/server`, and `middleware.recover` |
| N6 | Stackless tasks (C4) | thread per connection being served | a fixed pool; `serve` keeps its API when tasks arrive |
| N7 | References (8.6): reading a List out of a record copies it | the request path copies heads and bodies a few times | fine at these sizes, measured nothing yet |
| N8 | Comptime reflection and derive (P0.9, P0.10) | typed JSON-RPC parameters and results | decoder and encoder functions per type (`add_typed`) |
| ~~N9~~ | Iterating a Map's keys | kvstore's `kv.keys` | done (eider-lang's docs/compiler.md "C8.20"): http/metrics and eider-openapi's examples/todo iterate their Maps; eider-rpc's kvstore keeps its key list, since `kv.keys` promises insertion order (C102) |
| ~~N10~~ | Calling a function stored in a field (`(self.h)(x)`) | router | done: `self.h(x)`; a method of the same name wins (eider-lang's docs/compiler.md "C8.19") |
| ~~N11~~ | Name resolution with a deadline | the client takes an `net.Addr` | done: `net.lookup_by` (Eider 0.7.1); `client.connect_host`, `get_host`, ... |
| ~~N12~~ | Connection information in the handler (peer address, TLS) | logging, rate limiting | done: `Request.peer`, and over https the request context `tls` (the cipher suite) and `tls_client_cert` (the client's leaf certificate, DER) |
| N13 | A method chain continued on the next line (a line starting with `.field(...)`, or ending with `.`; the first is done: eider-lang's docs/compiler.md "C8.25") | schema and operation builders | reassignments: `s = s.field(...)` |
| N14 | Grants checked per imported module, not against everything the program loads of a package | eider-openapi is pure but programs load http/server | openapi grants http `net, io, clock, threads` |
| N15 | Interrupting a handler (cancellation reaching blocked code; with N6) | `middleware.timeout` | 503 at the deadline; the handler finishes on its pool's worker, `req.deadline` for cooperation |
| ~~N16~~ | A per-route body limit before the body is read (the router consulted after the head) or streaming bodies | `middleware.body_limit` | done: `http.Plan`, `Router.planner`, streamed bodies (below); `body_limit` remains for handlers behind other layers |
| N17 | A List literal (`["a", "b"]` is a fixed array) and `if` as a call argument (E0103) | builders, tests | `push` loops and `let`s |
| N18 | `String` to `str` (`http.text(200, s)` takes a `str`; building a body from a String needs `http.respond(.., s.bytes())`) | tests, middleware | `String.bytes()` |
| N19 | Borrowing two fields of one record in a call (`s.d.feed(x, inout s.pending)` is E0301) | the streaming request decoder | copy the field out, call, store it back |
| N20 | eider-compression's README says it needs no capability, but `compression.streams` names `io` and `clock`, and the grant is per package (N14), so http grants it both | eider.toml | `uses = ["io", "clock"]` |
| N21 | Response compression happens at the handler (the whole body is held; deflate is 33 MB/s at level 6) | http/compress | `with_level(1)`; a cache or the proxy for hot responses; eider-compression's encoder has no way to hand out partial blocks early other than `flush` |
| N22 | A `String` to `str` conversion (N18), and a list literal for `List[u8]` | http/secure: URLs, paths and host names that a program builds at run time (an ephemeral port in a URL) cannot be passed to a `str` parameter | `connect_url`, `get_url`, `dial_ws` and `parse_url` take `List[u8]` (`url.bytes()`); `server_from_files` takes `String` paths like eider-tls |
| N23 | eider-tls: `identity_from_der`, a certificate chosen by SNI, an ALPN callback, a handshake that can be abandoned from outside, session resumption | http/secure | DER is re-encoded as PEM to reuse `identity_from_pem`'s key-matches-certificate check; one identity per server (`reload` swaps it); the stop signal cannot interrupt a handshake, so a shutdown waits at most `handshake_timeout` for the handshakes in flight; every reconnect is a full handshake |
| N24 | A dependency that is only loaded by one module (eider-lang#60 again: eider-pkg resolves and grants per package) | http depends on eider-tls and the toolchain's crypto | a program that never imports `http.secure` still fetches eider-tls and needs Eider 0.7.6 (for `packages/crypto`); it loads, links and is granted nothing for them (the TLS section) |

## Next steps toward OpenAPI

1. **Middleware and observability:** done in a first form (above). Panics turned into 500: done
   (`recover`, and the server's last resort). A `Forwarded`-aware peer address behind
   configured proxies (`http/proxy`) and rate limiting (`http/ratelimit`): done. Tracing (W3C
   `traceparent`, carried like the request id): done (below).
2. **Streaming:** done: request bodies as readers, chunked responses from a producer, per-route
   limits before the body (see "Streaming bodies"); not done: streaming *client* bodies.
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
6. **TLS 1.3 in Eider** (P1.4): done (`http/secure`, section "TLS"). Then HTTP/2 (P1.7) for gRPC: the ALPN list is where `h2` would go.


## Production defaults (`http/health`, `http/service`)

`service.handler(router, options())` is the stack a service would write by hand, in the order that
makes the numbers right (module comment of service.ei): request id, trusted-proxy peer, access log,
metrics, problem+json, response compression, rate limit, trap containment, request decoding, router; and it mounts `/healthz`, `/readyz`,
`/metrics` and (opt-in) the profiler's endpoints. `service.run(addr, router, options)` also binds,
installs the SIGTERM/SIGINT watcher (std/service) and drains: readiness turns 503 at once, the
server keeps serving for `drain_delay` (5 s: time for a load balancer to notice), then shuts down
gracefully with the server's per-connection deadlines as the bound.

Defaults that matter: nothing is trusted in forwarded headers; rate limiting is **on**, 1000
requests a second per address with bursts of 2000, and exempts the probes and `/metrics` (so
a balancer's health checks are never limited); behind a load balancer all clients share one
bucket until `with_trust` names the balancer; profiling endpoints are off; readiness failures
name the failed checks and never their error text.

## TLS (`http/secure`, `http/transport`)

https for the server, the client and WebSockets, TLS 1.3 by [eider-tls](https://github.com/klxdev/eider-tls)
over the toolchain's `crypto` package (AWS-LC). Written for eider-lang#223 / #29.

### Shape

`http/transport` is the layer under every connection: a `Transport` is a socket and, for https, a `Secure` (five
functions over the TLS session). `http/server` (every read, write, wait and close, about 25 call sites), `http/client`
and `http/ws`'s client use only it, so the plain path is the same code as before (one `match` on an `Option`) and
**nothing outside `http/secure` imports eider-tls**. `Config.secure` and `service.Options.with_tls` take an
`Acceptor` (`ServerTls.acceptor()`), the client takes a `Connector`; both are function values, which is what lets
`http/server` stay free of TLS.

### Server

```eider,ignore
let tls = secure.server_from_files(String.from("chain.pem"), String.from("key.pem")).unwrap()
    .with_client_auth_pem(ca_pem, true).unwrap()                       // optional: mTLS
    .with_handshake_timeout(time.seconds(5)).with_max_handshakes(64)
let acc = tls.acceptor()
let o = service.options().with_tls(acc)                                // or: let mut cfg = server.config(); cfg.secure = Some(acc)
service.run(net.ipv4(0, 0, 0, 0, 8443), router, o)
```

- **Certificate and key**: a chain (leaf first) and a private key from PEM files or text, or from DER
  (`server_from_der(chain, key_der)`). Ed25519, P-256, P-384 and RSA (2048 to 8192 bits; PKCS#8, SEC1, PKCS#1) keys. The key
  must belong to the first certificate or the call is an Err. One identity per server (no choice by SNI).
- **Protocol**: TLS 1.3 only (eider-tls refuses 1.2 and below with `protocol_version`; there is no setting to lower it),
  ALPN `http/1.1` (a client that offers ALPN without it is refused with `no_application_protocol`; one that does not offer ALPN
  is served HTTP/1.1), suites AES-128-GCM, AES-256-GCM and ChaCha20-Poly1305, X25519, P-256 and P-384.
- **Client certificates**: `with_client_auth_pem(ca_pem, required)`: asked for (`required` false: a client may send none) or
  required (none: the handshake fails). The chain is verified against the CA roots; **authorization is the application's**: the
  handler sees the leaf certificate as the request context `tls_client_cert` (DER) and decides who it is.
- **What a handler sees**: `Request.peer` is the TCP peer, as over plain HTTP. `q.get_ctx("tls")` is the cipher suite name (absent
  over plain HTTP: the way to tell https from http, for `Secure` cookies and redirects), `tls_client_cert` the above.
- **Handshake deadline and bound** (slowloris): a connection takes a worker slot (`workers`) as before, then runs the handshake
  *in its own task* before `handshake_timeout` (10 s) measured from that moment; at most `max_handshakes` (128) run at once and
  the others wait for a place within the same deadline. A handshake that is stalled, trickled byte by byte, malformed or refused is
  closed at the latest at the deadline (immediately for garbage, an oversized record, a plain-HTTP request or a closed
  connection: eider-tls answers with an alert and the server closes) and counted in `Stats.tls_failed` /
  `http_server_tls_handshake_failures_total`; it holds its worker and its handshake place no longer than that. The acceptor never
  blocks the accepting task. A shutdown does not interrupt a handshake: it waits at most `handshake_timeout` for those in flight.
  When the queue is full a plain port answers `503`; a TLS port just closes (the client expects a ServerHello, not an HTTP
  response). `idle_timeout`, `read_timeout` (a stalled request after the handshake is answered `408`), `write_timeout` and
  `max_requests` apply as before, counted from the end of the handshake.
- **Closing**: a close after a response is a TLS `close_notify`, then the half-close and drain of a lingering close; an idle
  keep-alive connection closed by a shutdown gets a `close_notify` too, so the client sees a clean end of stream. A client that
  vanishes without one is a read error on the server (the connection is dropped) and `Truncated` on a client.
- **Keep-alive, chunked and streamed responses, SSE, request bodies and WebSocket (wss)** work as over TCP: they are written
  against the transport. A WebSocket handler may send from one thread while another receives: the session is behind a lock held only
  for one send or one non-blocking read.
- **Reload without restart**: `secure.reload(acc, chain_pem, key_pem)` or `reload_files(acc, chain_path, key_path)` swap the
  identity for the connections accepted afterwards (open connections keep theirs); a pair that does not go together is an Err
  and changes nothing. Triggering it (SIGHUP, a timer on the file's mtime) is the program's.
- **Also**: the metrics source gains the failure counter; `server.Stats` the field.

### Client

```eider,ignore
let tls = secure.client_system().unwrap()                              // the OS CA bundle, read once
let mut c = secure.connect_url("https://example.org/".bytes(), tls, dl).unwrap()
let r = c.request(http.request("GET", "/".bytes()), dl)               // keep-alive, content decoding: as over http
```

- **Verification is on**: `client_system()` (the system bundle by the path discovery of eider-tls: `/etc/pki/tls/certs/ca-bundle.crt`,
  `/etc/ssl/certs/ca-certificates.crt`, `/etc/ssl/cert.pem`, ...) or `client_roots_pem(pem)` (exactly those roots). The chain, its
  validity, key usage and the host name (SAN `dNSName` with a leading `*` label, or `iPAddress`; **no** CN fallback) are checked for the
  host of the URL, which is also the SNI. RSA (PKCS#1 v1.5 and PSS) and P-384 chains verify; SHA-1 signed chains do not.
  `client_insecure_skip_verify_for_tests()` verifies nothing and is the only way to turn it off; `with_identity(id)` sends a client
  certificate when the server asks.
- `connect_host`, `connect_host_with(.., limits, ..)`, `connect_url` (`http`, `https`, `ws`, `wss`; ports default to 80/443; IPv6 as
  `[::1]`), `get_url`, `dial_ws` (a `ws.Client` over TLS for `wss`). The returned `client.Conn` is the same type: it reconnects
  and **runs the handshake again** whenever the connection ended, the `Host` header omits port 443, `with_decoding(...)` works
  unchanged, and `c.alpn()` says what was negotiated. One `Conn` is one host: reuse is keep-alive on it (there is no pool).
- **Redirects are not followed** (the client follows none, to http or https); a `3xx` is returned as it is.
- Time: the deadline you pass covers the TCP connection and the handshake together.

### Who terminates what, and the proxy

With `with_tls`, **this process terminates TLS** (eider-tls, in Eider; the primitives are AWS-LC); the parser, the handlers and the
middleware see plaintext only after decryption, and nothing in the stack changes. Behind a proxy there are two layouts:

1. The proxy terminates TLS and speaks plain HTTP to the service (`with_tls` unused): `Request.peer` is the proxy,
   `http/proxy` (`with_trust`) recovers the client from `X-Forwarded-For` / `Forwarded`. The service does not read
   `X-Forwarded-Proto`; `get_ctx("tls")` is absent (it describes this hop, not the client's).
2. The proxy re-encrypts to the service (`with_tls`): the same, over TLS; the proxy's address is the peer and trust applies as in 1. Do
   not require client certificates from the end user in this layout (the proxy holds the connection).

Without a proxy `Request.peer` is the client and the rate limiter keys on it as before. TLS does not make the forwarded headers
trustworthy: a client that reaches the service directly can still send `X-Forwarded-For`; `with_trust` names the proxies for that
reason, and the service should not be reachable by clients except through them.

### Security notes

- eider-tls has had no outside audit (its README: "Not done"); secrets live in ordinary lists and are not zeroed; no resumption, no 0-RTT
  (a reconnect is a full handshake: the CPU cost of a handshake is the case for `max_handshakes`), no OCSP or CRL, no certificate
  transparency, no name constraints.
- The server sends no `Strict-Transport-Security`; add it in a middleware if you want it.
- The handshake runs in the connection's task: the bound on its CPU is `max_handshakes` and `workers`, not a rate. Put a rate
  limit at the network edge for floods of connections.
- `client_insecure_skip_verify_for_tests()` accepts anyone, including a man in the middle. Its name is the warning; nothing else
  reaches it.

### Capabilities and dependencies

`eider.toml` declares `[deps.tls]` (eider-tls, granted `net io clock fs`) and `[deps.crypto] toolchain = true` (granted `io`). A
program that never imports `http.secure` (`http.server`, `http.client`, `http.service`, ... are TLS-free: `http.transport` has no TLS)
loads no TLS or crypto code, links no crypto backend and needs **no grant for tls or crypto and no new grant for http**. It still has them in
its lock (eider-pkg resolves per package, N24) and so needs Eider 0.7.6 or later, whose toolchain ships `packages/crypto`. A program that imports
`http.secure` needs nothing more either: http's own grants to tls and crypto are in http's manifest; it grants http what
`secure.ei` uses, `net io clock fs`, which are the capabilities http already needed (`fs` for `http/profiling` and `http/service`).
Tested with a program that depends on http by path and imports `http.service` with and without `http.secure`: no E0204, and the
backend is linked only with it.

### Tests

`tests/tls_test.ei` (also under TSan): the happy paths above over TLS (3 MB response, 1.5 MB request body, chunked stream, keep-alive,
`Connection: close` and reconnect, wss with 60 KB frames), a client whose records reach the server a byte at a time, a connection cut
without `close_notify`, the clean end after a stop, the refusals (host name, untrusted root, expired, a plain client on a TLS port and the
reverse, required client certificate missing), reload, hostile clients (garbage, plain HTTP, an oversized record, a bad ClientHello,
a partial record, a stalled handshake behind `workers = 1`, two stalled handshakes under `max_handshakes = 1`, a stalled request after the
handshake), `service.Options.with_tls` with the metrics. `tests/tls_interop.sh` (in `scripts/test.sh`): `openssl s_client`
(ALPN, a request in two records, keep-alive, chunked stream, TLS 1.2 and the wrong ALPN refused, RSA and P-384 certificates, client
certificates), `curl --cacert` (when installed) and the Eider client against `openssl s_server -www` (Ed25519, P-256, RSA, P-384 leaves,
name, IP, wrong name, wrong root, expired, EKU, TLS 1.2-only, client certificates). The PKI is `tests/pki` (copied from eider-tls,
valid to 2036).

## Tracing and per-route metrics

`trace.wrap(tracer, h)` joins the trace in a request's `traceparent` header (strictly parsed) or
starts one, gives the request a span id, and puts `trace_id`, `span_id`, `traceparent` and
`tracestate` in the request's context like the request id; the response carries `traceresponse`.
When `h` returns, the span (name `METHOD route`, start, duration, status, parent) goes to the
sink if the trace is sampled: `trace.log_sink(logger)` writes it as a `logging` record,
`trace.collect(lock)` collects them. `tracer.inject(req, out)` puts a `traceparent` for a new child
span on a request this service sends, so the trace continues downstream. The access record
(`middleware.access_fields`) carries `trace_id`, which ties a log line to its span.

The router puts the matched pattern in the request's context and in the response's (`route`), and
`metrics.by_route(m)` labels `http_requests_total` with `route` and keeps a latency histogram per
route: `{route="/todos/:id",le="0.005"}`. A handler or layer that sets the response context
`operation` (an OpenAPI operation id) is labelled by that instead; requests no route took are
`unmatched`, so the label set is bounded by the routes. `metrics.new()` without `by_route` writes the
series as before. Sampling profiles of a running service are `http/profiling` with eider-profiler.

**Other components on `/metrics`.** `Metrics.add_source(f)` appends the text `f` writes
(`metrics.counter_text`, `metrics.gauge_text`) after the built-in series on every render.
`srv.expose(m)` adds the server's counters (`http_server_connections_total`,
`..._connections_rejected_total`, `..._requests_handled_total`, `..._bad_requests_total`,
`..._timeouts_total`, `..._handler_traps_total`, the gauge `..._connections_waiting`; `srv.stats()`
reads the same numbers live), and `lim.expose(m)` the rate limiter's (`http_ratelimit_allowed_total`,
`..._limited_total`, `http_ratelimit_tracked_keys`). Order the layers so the 429s and 500s are
counted: `metrics.wrap` outside `ratelimit.middleware` and `recover`.

**Profiling endpoints.** `profiling.mount` is opt-in (`enabled`), answers 501 in a build without
`--profile`, 403 to peers other than the local host (an IP literal in 127.0.0.0/8 or `::1`; text that
only begins with `127.` is not local) unless `remote`. Behind a proxy on the same host every visitor
is the proxy, hence local: put `proxy.middleware` (with the proxy trusted) outside, or
`middleware.bearer` in front of the endpoints.


## Streaming bodies and per-route limits

**Plans.** After a request's head is parsed and before any body byte is read, the parser asks a
`http.Planner` (`fn(method, path) -> http.Plan`, `Config.plan`) what the body may be:
`Plan { max_body, stream }`. `max_body` is the route's own limit (0: `Limits.max_body`): a
`Content-Length` above it is answered 413 from the head alone, a chunked body is cut off the moment
its total passes it. `router.planner()` is the planner of a router's routes, which are given plans
with `route_with(method, pattern, plan, h)` (the most specific matching route, as for dispatch;
HEAD takes GET's); `cfg.plan = r.planner()` connects it. Routes added with `get`/`post`... have the
server's limit and are buffered.

**Streamed request bodies.** A route whose plan says `stream: true` gets a request with an empty
`body` and `req.stream: Option[http.Body]`. `Body` implements `std/stream`'s `Reader`: `read(max)`
returns 1 to `max` bytes or none at the end of the body, `read_by(max, deadline)` waits no longer
than the deadline; each wait is bounded by `read_timeout` too (the gap between reads, not the whole
body, so a slow upload that keeps moving is fine). A body over its limit, malformed, or cut short
by the client is an `Err` (`InvalidData`, `UnexpectedEof`, `TimedOut`); `Expect: 100-continue` is
answered at the first read. What the handler leaves unread is read and dropped after it returns
(if that fails the connection is closed after the response). Handlers that read need `uses io` on
the function that builds them. The parser's side is `Parser.set_plan` and `body_next(max)`
(`Data`, `End`, `Wait`, `Broken`).

**Streamed responses.** A response with `stream: Some(http.Stream(run, false))` is sent chunked:
the server writes the head (`Transfer-Encoding: chunked`), calls `run` with an `http.Duplex` on
the worker, each `write` is one flushed chunk (bounded by `write_timeout`), and the terminating
chunk is written when `run` returns; the connection then serves the next request. `is_stopping()`
tells a long stream the server is shutting down. A `raw` stream is an upgrade (http/ws).

## Compression (`http/compress`)

eider-compression supplies the codecs (deflate/zlib/gzip/zstd, hard `Limits`, never a trap on
hostile input); http/compress is where they meet the protocol (module comment of compress.ei).

**Responses.** `responses(options, h)`: the coding is `codec.negotiate(Accept-Encoding, [gzip,
deflate])` (zstd first after `with_zstd`: its encoder has no Huffman literal coding, so the ratio
is 3.07 against gzip's 3.72 at about the same speed, and it is off unless asked for); no usable
header means the body as it is. A response is compressed unless: its status is 1xx, 204, 205, 206
or 304; it has `Content-Range`; the request is HEAD or has `Range` (the server serves no ranges);
it is encoded already or has `Cache-Control: no-transform`; its type is not on the allow-list
(`text/*`, `application/json`, `application/*+json`, `application/xml`, `application/*+xml`,
`application/javascript`, `image/svg+xml`); a buffered body is under 1024 bytes or does not shrink;
`compress.never(resp)` or `except(f)` says no. `Vary: Accept-Encoding` goes on every response that
could be compressed (so also on the ones sent as they are), a strong ETag becomes weak, and the
framing headers are rebuilt from the compressed body. A streamed (chunked) response is
compressed piece by piece as the producer `send`s, with the trailer when `run` returns; nothing
but the encoder's block is buffered, and `text/event-stream` is flushed after each send. HEAD
is passed through with `Vary`; its `Content-Length` is the identity one (a deviation: RFC 9110
wants HEAD to match GET).

**CPU.** Eider's deflate encodes at 33 MB/s at level 6 and 77 MB/s at level 1 (eider-compression's
bench): a 1 MiB response is 30 ms of a worker at the default; `with_level(1)` trades a tenth of
the ratio for twice the speed. Put a cache in front of expensive hot responses or compress at the
proxy.

**Requests.** `requests(limits, h)` decodes `Content-Encoding: gzip|x-gzip|deflate|zstd`
(case-insensitive; `identity` is nothing) before the handler: 415 for another coding or a list of
two, 413 for a bomb (`TooLarge`, `RatioExceeded`), 400 for corrupt, truncated or checksum-failing
data. The handler gets the plain body, no `Content-Encoding`, the decoded `Content-Length` and
`ctx["content_encoding"]`. A streamed request body is decoded as it is read (errors are `stream.Error`s
whose text starts with the status). `http/server` does the same for `Transfer-Encoding: gzip,
chunked` before the handler (`Config.decode_max`; the parser still answers 501 for any other
coding and 400 for a final coding that is not chunked).

**Client.** `Conn.with_decoding(limits)` sends `Accept-Encoding: gzip, deflate, zstd` (unless the
request has its own) and decodes the response under `limits`, closing the connection on failure;
off by default.

**Static files.** `static.options().with_precompressed()` serves `file.gz` for `file` to a client
that accepts gzip, with the file's `Content-Type`, `Content-Encoding: gzip`, its own ETag and
`Vary`; the sibling goes through the same root and symlink checks. Nothing is compressed at
request time; put `compress.responses` outside `static` for that.

**http/service.** Both directions are on: responses for the allow-list (a production service is
expected to compress; the risk, BREACH, is confined to bodies mixing a secret with reflected input and is
documented, with `no_compression()` and `compress.never` as the exits), request decoding up to the
server's `limits.max_body` (hard limits make it safe, and a handler would otherwise get bytes it
cannot use; `with_request_decoding(n)` raises the cap for routes with a larger plan,
`no_request_decoding()` hands the bytes over). Layers: ... problem+json > response compression >
rate limit > trap containment > request decoding > router.

## Server-sent events and WebSockets

Both ride on `Response.stream` (above).

**`http/sse`.** `sse.response(run)` is a `200 text/event-stream` response (`Cache-Control: no-cache`)
whose chunked body `run` writes through an `sse.Stream`: `event(name, data, id)`, `data(text)`,
`retry(ms)` and `comment(text)` (the keep-alive), each flushed at once. Fields are checked: a line
break in a name or id is `InvalidInput`, and each line of the data becomes a `data:` line so it can't
start another field. A failed write means the client went away: return. `is_stopping()` tells the
server is shutting down. `last_event_id(req)` is a reconnecting client's `Last-Event-ID`.

**`http/ws`.** `ws.accept(req, opts, run)` validates the handshake (GET, HTTP/1.1, `Upgrade` and
`Connection`, a 16-byte base64 `Sec-WebSocket-Key`, version 13 (426 with `Sec-WebSocket-Version` if
not), the `Origin` against `opts.origins`, a subprotocol from `opts.protocols`) and returns `101` with a
raw stream: the server writes the head, calls `run(Conn)` on the worker, and closes the connection when
`run` returns. `Conn.recv()` returns `Text`, `Binary` (fragments joined) or `Closed(code, reason)`;
it answers pings, skips pongs, echoes a close, and closes with the right code on a violation: 1002
(an unmasked client frame, reserved bits, a malformed control frame, an unknown opcode, a stray
continuation), 1007 (text that isn't UTF-8), 1009 (a frame over `max_frame` or a message over
`max_message`, refused from the header), 1001 (idle past `opts.idle`, or the server stopping).
Sends are whole frames under a lock, so several threads may send. The codec (`encode_frame`,
`Decoder`), SHA-1 and the accept key are public and tested against the RFC's examples and FIPS 180's
vectors; SHA-1 is written here (a few lines, no dependency on packages/crypto, which would need a
libcrypto at link time). Handlers that call `recv` need `uses clock` on the function that builds them.
`ws.dial` is a masking client for tests and tools; `ws.dial_conn(c, ...)` does the handshake over a `client.Conn`
that is already connected, which is how `secure.dial_ws("wss://...")` works. The server side needs
nothing for wss: a handler's `Duplex` is the connection's transport, plain or TLS. Not done: permessage-deflate and
other extensions, backpressure beyond the write deadline.
