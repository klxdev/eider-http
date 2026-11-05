# Changelog

eider-http's versions (semver). Before 1.0 the MAJOR.MINOR is the Eider toolchain's it goes
with (`eider` in eider.toml), the PATCH its own.

## 0.7.2

- **`Content-Encoding` with eider-compression** (eider-lang#37; for Eider 0.7.3). `[deps.compression]` (eider-compression 0.7.0, granted `io` and `clock`: its `streams` module names them, see docs/services.md N20) and a new module `http/compress`:
  - **Response compression**, `compress.responses(options, h)`: `Accept-Encoding` negotiated with q-values among gzip and deflate (zstd only after `with_zstd(level)`: eider-compression's encoder has no Huffman literal coding, so its ratio, 3.07 at level 3, is below gzip's 3.72 at similar speed), `Vary: Accept-Encoding`, a 1024-byte floor, an allow-list of media types (`text/*`, JSON, XML, JavaScript, SVG; `with_type`), strong ETags made weak, no double encoding, nothing for HEAD, 1xx/204/205/206/304, `Content-Range`, `Range` requests, `Cache-Control: no-transform`, `compress.never(resp)` or `except(f)`; a body that does not shrink is sent as it is; streamed (chunked) responses are compressed piece by piece (flushed per event for `text/event-stream`); `with_level`.
  - **Request decoding**, `compress.requests(limits, h)`: `Content-Encoding: gzip|x-gzip|deflate|zstd` bodies (buffered or streamed) are decoded under `compression.Limits`; 413 on a bomb (output or ratio), 415 for an unsupported coding or a list of two, 400 for corrupt or truncated data.
  - **The server no longer answers 501 for `Transfer-Encoding: gzip, chunked`** (also deflate, zstd): it decodes before the handler under the route's body limit (`Config.decode_max`, a new last field of `Config`: **breaking for code that builds it by position**); other codings stay 501.
  - **Client**: `Conn.with_decoding(limits)` (off by default; `Conn` has a new last field `decode`, **breaking for code that builds it by position**) sends `Accept-Encoding: gzip, deflate, zstd` and decodes gzip/deflate/zstd responses under the same kind of limits.
  - **`http/static`**: `with_precompressed()` serves `file.gz` siblings to clients that accept gzip (`Options` has a new last field).
  - **`http/service`**: both directions are on by default (`Options` has two new last fields): response compression for the allow-listed types, and request decoding up to the server's `limits.max_body`. Decision: request decoding is on because hard limits bound it and a handler could not use the raw bytes anyway; response compression is on because a production service is expected to compress and the allow-list excludes already-compressed types. The risk is BREACH (a body mixing a secret with reflected input), documented in http/compress and docs/services.md; `no_compression()`, `compress.never(resp)` and `except(f)` are the exits, `no_request_decoding()` and `with_request_decoding(n)` the others. HEAD responses are passed through without a coding (their `Content-Length` is the identity one). Rate limiting, proxies and the other layers are unchanged.

- **Logging is eider-logging, not `std/log`** (eider-lang#216, for Eider 0.7.3): `Config.log`, `Options.with_logger`, `middleware.access_log_with`, `middleware.recover`, `trace.log_sink` take a `logging.Logger`; `import logging` replaces `import std.log`. eider.toml has a `[deps.logging]` table (granted `io` and `clock`), so a package that builds a `Logger` for http depends on eider-logging too. The access record carries the logger's context fields (`Logger.with_context`) as well as its base fields.

## 0.7.1

For Eider 0.7 (`eider = "0.7"`).

- **A trap in a handler is a 500** (eider-lang#54): `http/server` runs every handler (and the
  producer of a streamed response) under `task.catch`: the client gets the standard `500 Internal
  Server Error` and nothing of the trap, the trap is logged (`Config.log`, a `std/log` Logger,
  error level to stderr by default; `None` turns it off), `Stats.traps` counts it, the connection
  is closed after the response, and the server carries on. `middleware.recover(lg, h)` does the
  same inside the access log and `metrics.wrap` so they record the 500; `middleware.timeout` answers a
  trapped handler 500 at once (it was 503 at the deadline). **Breaking for code that builds the
  records by position:** `Config` has a new last field (`log`) and `Stats` has `traps`.

- **`http/proxy`: the client address behind a proxy, with nothing trusted by default** (eider-http#3).
  `proxy.trust_none().allow("10.0.0.0/8")` lists the proxies (CIDR ranges; `/0` is refused;
  `allow_unix()` for unix-socket proxies); `proxy.middleware(trust, h)` then sets `Request.peer`
  to the client from `X-Forwarded-For` (or `Forwarded` after `use_forwarded()`; only the one
  header named is read) when the connection is from such a proxy, and puts the proxy in the
  request context as `proxy_peer`. The list is walked from the right, skipping trusted proxies; it
  is bounded (2 KiB, 16 elements) and strict (anything but an IP literal that the walk reads makes
  the header ignored); addresses are canonical.
- **`http/ratelimit`** (eider-http#3): `ratelimit.new(requests, per, burst)`, `middleware(lim, h)`
  (429 with `Retry-After`), keyed by client address (IPv6 by /64) or `by(f)`, `except(f)`, a table
  bounded by `with_max_keys`, `allow_at` for tests.
  Not done (eider-http#3): `X-Forwarded-Proto` / `-Host` (the scheme and host of the original
  request), the PROXY protocol, a rate limit shared between processes. Per-route limits: wrap
  that route's handler in its own limiter.

- **Observability** (eider-http#5, the criteria left open): `Metrics.add_source(f)` with
  `metrics.counter_text` / `gauge_text` puts other components on `/metrics`; `Server.expose(m)`
  adds the server's counters (connections, rejected, handled, bad, timeouts, handler traps, the
  waiting gauge), `Limiter.expose(m)` the rate limiter's; `Server.stats()` and `waiting()` read them
  live (`Server` has a new last field, `sh`: **breaking** for code that builds it by position, which
  only `listen` should). `Metrics` has a new last field (`sources`), likewise. Tracing (`traceparent`) and
  metrics by route/operation were done in 0.5.0; the sampling profiler for services is
  `http/profiling` (eider-profiler reads its files), now tested in both a plain and a `--profile`
  build. `profiling.is_local` accepts IP literals only (it took any text starting with `127.`).

- **Production defaults** (eider-http#6): `http/health` (`/healthz`, `/readyz` with named checks,
  `drain()`), `http/service`: `service.options()`, `service.handler(router, o)` (request ids,
  trusted-proxy peer, access log, metrics, problem+json, rate limit, trap containment, probes,
  `/metrics`, opt-in profiling) and `service.serve` / `service.run` (drain on SIGTERM: readiness
  503, `drain_delay`, graceful stop). Rate limiting is on by default (1000/s, burst 2000 per
  address); nothing is trusted in forwarded headers until `with_trust`.
  Not done (eider-http#6): the pprof-compatible profile export. It needs a converter from the
  profile file (JSON lines, docs/runtime.md "Profile format") to pprof's `profile.proto`; that
  belongs in eider-profiler (`eider-profiler pprof`), after which `/debug/pprof/profile` here is a
  few lines. `service.run`'s signal path (`std/service.cancel_on_term`) has no test of its own;
  `serve` with a token is tested.

- **`http/static`** (eider-http#7): `static.mount(inout router, "/assets", "web/dist", static.options())`
  or `static.dir(root, opts).handler("path")` for a `/*path` route. Media types by extension
  (`application/wasm` included), a strong `ETag` and `If-None-Match` (304), `Cache-Control`
  `immutable` for content-hashed file names and `no-cache` for the rest, `index.html` for directories
  (never a listing; `/dir` redirects to `/dir/`), an optional SPA fallback (`with_spa`), dot files
  never served (`with_well_known` for `.well-known`), and path checks after decoding: no empty, `.`,
  `..`, dot, control, `\\`, NUL or non-UTF-8 segments, and the canonical path must be inside the
  canonical root (symlinks out are 404). The only module here that uses `fs` besides profiling.
  Not done (eider-http#7): `Last-Modified` and `Range` (std/fs has no file times, sizes or partial
  reads), streaming large files (files are read whole, 16 MiB by default), precompressed
  (`.gz`/`.br`) variants.

- **The client takes a host name with a deadline** (eider-lang#59, with Eider 0.7.1's
  `net.lookup_by`): `client.connect_host(name, port, dl)`, `connect_host_with`, `fetch_host`, `get_host`,
  `post_host`, `client.resolve`, `client.valid_host`. Names are resolved before the deadline, address literals
  never reach the resolver, the addresses are tried in turn (each with an equal share of the
  remaining time), a `Conn` made from a name resolves again to reconnect, `Host` is the name, and
  names that could not be hosts are refused before any lookup. **Breaking for code that builds a `Conn`
  by position:** it has two new last fields (`name`, `port`). `ws.dial` still takes an address.
  Not done: happy-eyeballs (parallel attempts), a resolver cache, `ws.dial` by name.

## 0.7.0

For Eider 0.7 (`eider = "0.7"`). Requires eider-json 0.7.0. Nothing else changed.

## 0.6.0

For Eider 0.6 (`eider = "0.6"`).

- **`http/server` serves a task per connection** (eider-lang#14, decision C830): `serve` keeps its
  signature and its behaviour (deadlines, back-pressure with `queue` and 503, graceful shutdown,
  lingering close). A connection waits for its socket and the stop signal with one
  `fd.wait_ready2` and parks, so there is no thread and no poller per connection; the default
  `Config.workers` is now 10,000 connections served at once (it was 16 threads), `queue` stays 64.
  A handler that computes for long without waiting occupies a scheduler thread. Needs Eider 0.6. Requires eider-json 0.6.0.

## 0.5.0

For Eider 0.5 (`eider = "0.5"`). Requires eider-json 0.5.0.

**Breaking:** `Request` and `Response` have a new last field (`stream`), `Msg` has `streaming` and `Config` has `plan`: code that builds these records by position must be updated (build them with field names). Without a plan or a stream, parsing and responses behave as before. eider-http#5 (tracing) is partly done and stays open.

- `http/testing` (eider-lang#30): an in-process test client, `testing.client(handler)` with `get`,
  `post`, `put`, `delete`, `post_json`, `send`, default headers (`with_header`) and a peer address
  (`from_peer`); no socket or thread. Requests are validated as `write_request` does and the
  handler's response is serialized with `write_response`, so a response the server would refuse to
  send fails the test. `testing.text`, `header`, `is` read the response.

- `middleware.access_log_with(logger, h)`, `access_fields` and `access_line`: the access record
  through a `std/log` Logger (typed fields, the logger's level and base fields) (eider-http#8).
  `access_log(out, h)` is unchanged.

- http/trace (eider-http#5): W3C `traceparent` propagation (`wrap`, `inject`, `parse`), request spans
  to a sink (`log_sink`, `collect`), `trace_id` in access records; the router sets the matched route
  in the request and response context; `metrics.by_route`: `route` label on the counters and one
  histogram per route (`observe_route`; the label is the pattern, or the `operation` context an
  OpenAPI layer sets). Without `by_route` the exposition is unchanged.

- Streaming bodies and per-route limits before the body (eider-http#2): `http.Plan` / `Planner`
  (`Config.plan`, `Router.route_with`, `Router.planner`, `Parser.set_plan`); `Request.stream`, an
  `http.Body` that is a `stream.Reader`; `Response.stream`, chunked responses from a producer
  (`http.Stream`, `Duplex`). **Breaking for code that builds the records by position:**
  `Request` and `Response` have a new last field (`stream`), `Msg` has `streaming`, `Config` has
  `plan`, the parser has the `body_next` side. Parsing and responses without a plan are unchanged.

- WebSockets and server-sent events (eider-http#4): `http/ws` (handshake, framing, close handshake and
  limits, pure SHA-1, `dial` client) and `http/sse`, on `Response.stream`. `write_request` keeps a
  `Connection: Upgrade` header on upgrade requests.

## 0.4.0

For Eider 0.4 (`eider = "0.4"`). Requires eider-json 0.4.0. Nothing else changed.

## 0.3.0

For Eider 0.3 (`eider = "0.3"`): every plain string literal interpolates (eider-lang U29), so
the literals with braces here are raw strings or have their braces doubled. Requires eider-json 0.3.0. Nothing else changed.

With eider-lang's automatic grants (#135, #141) a depender's grant covers every module of this
package: `clock, fs, io, net, threads` (`fs` for `http.profiling`).

## 0.2.0

For Eider 0.2 (`eider = "0.2"`): eider-lang's 0.2 builds programs only through LLVM (clang
17 or newer; U23) and bootstraps the compiler from a WebAssembly seed (seed/eiderc.wasm; U24).
scripts/env.sh recognises such a checkout (seed/eiderc.wasm, or seed/eiderc.c before).
Nothing else changed.

## 0.1.3

The scripts find the Eider toolchain through `eider` (eider-lang#133) instead of a fixed
eider-lang checkout: scripts/env.sh takes `$EIDER_TOOLCHAIN` (a toolchain directory or an
eider-lang checkout; eider-lang's scripts/check-tools.sh sets it to its checkout), else the
toolchain `eider toolchain show --json` names for this repository's `eider = "0.1"` (the
newest installed 0.1 release), else stops with exit 2 and says to install `eider`
(install.sh). eiderc and eider-pkg run through `eider` with that toolchain (`eider eiderc`,
`eider eider-pkg`), or directly when `eider` is not on the PATH. `EIDER_ROOT` and
`EIDER_LANG` no longer choose the toolchain, and `../eider-lang` is no longer the default.
The pinned `.vendor/<name>` fallback for a dependency applies when the toolchain is an
eider-lang checkout. Tested with the released Eider 0.1.0 and with eider-lang main. No
change to the library's code.

## 0.1.2

scripts/env.sh takes a dependency that has no `EIDER_<NAME>` and no sibling checkout from the
toolchain's pinned release in `$EIDER_ROOT/.vendor/<name>` when eider-lang's `vendor.lock`
pins it (its `scripts/vendor.sh fetch <name>` fetches and hash-checks it on first use), else
from its repository. The toolchain's old `vendor/` is no longer looked at (eider-lang #130 and
#124; no backwards compatibility). No change to the library's code.

Needs an Eider 0.1 toolchain; the pinned copy needs one with `vendor.lock` (eider-lang #122),
and without one a dependency comes from a sibling checkout or the network.

## 0.1.1

Imports in the dotted form (eider-lang C8.26, issue #91): `import std.net`, `import json`,
and this package's own modules by its name (`import http`, `import http.parse` instead of
`import "http.ei"`, `import "../parse.ei"`), in the code, the tests, the README,
docs/services.md and the program scripts/build.sh generates to check every module.

Needs an Eider 0.1 toolchain whose compiler knows dotted imports (the eider-lang commit after
the next seed); an older 0.1 compiler stops at the first dotted import (E0001).

Also since 0.1.0: server, metrics and access_log change their shared state in place with
`sync.Lock.modify` (eider-lang C320, issue #90), so this release also needs a std with
`Lock.modify`.

## 0.1.0

The first release as a repository of its own, for Eider 0.1. The code is eider-lang's
`packages/http` as of the split (its history is kept), without JSON-RPC:

- Moved out: `http/jsonrpc` is eider-rpc's `rpc/jsonrpc` (with its test); the examples
  went with the frameworks that use them (examples/kvstore to eider-rpc, examples/todo to
  eider-openapi); docs/services.md came along without the JSON-RPC parts.
- json is a git dependency (eider-json 0.1.0); the fuzz test carries its PRNG
  (tests/rng.ei) instead of depending on eider-lang's packages/fuzz.
- `VERSION`, `eider = "0.1"`, `scripts/build.sh` and `scripts/test.sh` against an eider-lang
  checkout (`EIDER_ROOT`), refusing a toolchain of another MAJOR.MINOR, with
  `EIDER_PKG_OVERRIDE` set for sibling checkouts (scripts/env.sh).
- `scripts/version.sh` (`check`, `sync`): eider.toml agrees with VERSION; eider-lang's
  `scripts/version.sh check-siblings` and `bump` drive it.
