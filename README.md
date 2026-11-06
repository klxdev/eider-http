# eider-http

HTTP/1.1 for [Eider](https://github.com/klxdev/eider-lang): a strict incremental parser, a
server with deadlines, back-pressure and graceful shutdown, a blocking client, a router,
middleware (request ids, access logs, compression, errors as problem+json, traps as 500s, rate limiting, forwarded client addresses, body limits and timeouts per
route, CORS, bearer and Basic authentication), Prometheus metrics, and the profiler's
labels and debugging endpoints.

```eider,ignore
import std.net
import std.task
import http
import http.server
import http.router

fn main() uses io, net, clock, threads {
    let mut r = router.new()
    r.get("/users/:id", |q: http.Request| -> http.Response {
        http.respond(200, "text/plain", q.param("id").unwrap())
    })
    let srv = server.listen(net.ipv4(127, 0, 0, 1, 8080), server.config()).unwrap()
    let stats = srv.serve(router.handler(r), task.root()).unwrap()
}
```

| Module | What |
|---|---|
| `http` | `Request`, `Response`, headers, `Limits`, query strings, writing messages |
| `http/parse` | the incremental parser (requests and responses) |
| `http/server` | `listen`, `Server.serve(handler, token)`: a task per connection, deadlines, graceful shutdown |
| `http/client` | `connect`, `Conn.request`, `fetch`, `get`, `post` |
| `http/router` | method and path patterns with parameters, 404 and 405 |
| `http/middleware` | `request_id`, `access_log`, `access_log_with` (a `logging` Logger), `errors`, `problems`, `recover`, `body_limit`, `timeout`, `cors`, `bearer`, `basic`, `chain` |
| `http/compress` | `Content-Encoding`: response compression (gzip, deflate, opt-in zstd; `Accept-Encoding` q-values, allow-list, size floor, streamed bodies) and request decoding with hard limits (413 on a bomb, 415, 400) |
| `http/static` | static files from a directory (`static.mount`): media types, ETag, cache rules, index, SPA fallback, path-traversal checks, precompressed `.gz` siblings |
| `http/health` | liveness and readiness endpoints, the drain flag |
| `http/service` | production defaults in one call (probes, `/metrics`, request ids, rate limit, trusted proxies, traps as 500s) and a serve loop that drains on SIGTERM |
| `http/proxy` | the client address behind trusted proxies (`X-Forwarded-For`, `Forwarded`): an allow-list of proxy ranges, nothing trusted by default |
| `http/ratelimit` | rate limiting per client address (GCRA), 429 with `Retry-After`, bounded memory |
| `http/metrics` | counters, an in-flight gauge and a latency histogram (Prometheus text), optionally per route |
| `http/sse` | server-sent events |
| `http/ws` | WebSockets (RFC 6455) with limits, a codec and a test client |
| `http/trace` | W3C traceparent propagation and a span per request |
| `http/problem` | `ApiError`, written as RFC 9457 problem+json |
| `http/profiling` | profiler labels per route, `/debug/profile`, `/debug/heap` |
| `http/transport` | the bytes under a connection, plain or TLS (the server, the client and `ws` use only it; it imports no TLS) |
| `http/secure` | https: `server_from_files(...)`, `service.options().with_tls(tls.acceptor())`, `client_system()`, `connect_url("https://...")`, `dial_ws("wss://...")`, client certificates, certificate reload (eider-tls, TLS 1.3) |
| `http/sock` | sending before a deadline, lingering close |

[docs/services.md](docs/services.md) is the design: the concurrency model, every limit and
default, the security posture, TLS (in the process or behind a proxy), the tests and the
known gaps. JSON-RPC 2.0 over this package is
[eider-rpc](https://github.com/klxdev/eider-rpc); OpenAPI 3.1 services are
[eider-openapi](https://github.com/klxdev/eider-openapi). eider-lang's site has the
step-by-step guide ("Building services").

Compression is [eider-compression](https://github.com/klxdev/eider-compression) (a git
dependency, granted `io` and `clock` in this package's eider.toml). `compress.responses(compress.options(), h)`
compresses allow-listed responses (text, JSON, XML, JavaScript, SVG; at least 1 KiB) when the client
accepts gzip or deflate, `compress.requests(compression.limit_output(1048576), h)` decodes
`Content-Encoding` request bodies, and the server decodes `Transfer-Encoding: gzip, chunked` itself;
`http/service` has both on by default (docs/services.md "Compression"; read its BREACH note).
`client.Conn.with_decoding(limits)` asks for and decodes compressed responses.

## Using it

In your package's `eider.toml`:

```toml
[deps.http]
git = "https://github.com/klxdev/eider-http.git"
version = "0.1.0"
uses = ["net", "io", "clock", "threads"]   # add "fs" for http/profiling's endpoints
```

then `eider fetch` and `import http`,
`import http.server`, ... A program grants http what the modules it loads use (the
compiler checks it: E0204).

### https

```eider,ignore
import http.secure
import http.service

let tls = secure.server_from_files(String.from("chain.pem"), String.from("key.pem")).unwrap()
let stats = service.run(net.ipv4(0, 0, 0, 0, 8443), r, service.options().with_tls(tls.acceptor())).unwrap()
```

TLS 1.3 only, ALPN `http/1.1`, optional client certificates, a deadline and a bound on handshakes, certificate reload without a restart;
the client verifies against the system CA bundle (`secure.client_system()`) or explicit roots, with host name checks and SNI
(docs/services.md "TLS"). **Capabilities**: a program that never imports `http.secure` loads no TLS or crypto code and needs no grant for
them, and none beyond what http needed before; `http.secure` itself uses `net, io, clock, fs`, which http's grant already covers
(`fs` for `http/service`). The package depends on eider-tls and on the toolchain's `crypto`
(`[deps.crypto] toolchain = true`), so even a plain-HTTP program fetches eider-tls and needs Eider 0.7.6 or later (eider-pkg
resolves per package, eider-lang#60); it links the crypto backend only when it imports `http.secure`.

### Testing handlers

`http/testing` calls a handler (a router, or a router in middleware) in-process, with no port:

```eider,ignore
import http.router
import http.testing

test "user by id" {
    let c = testing.client(router.handler(app()))
    let r = c.get("/users/42")
    assert(testing.is(r, 200, "application/json"))
}
```

## Developing

```sh
sh scripts/build.sh     # fetch the dependencies, check every module
sh scripts/test.sh      # build, then run tests/*.ei against their .out files (and under TSan)
EIDER_TOOLCHAIN=../eider-lang sh scripts/test.sh   # the same, against an eider-lang checkout
```

The scripts use the toolchain [`eider`](https://github.com/klxdev/eider-lang/blob/main/docs/site/tooling/eider.md)
picks: `$EIDER_TOOLCHAIN` (an installed toolchain's directory, or an eider-lang checkout for
unreleased work), else the installed release for `eider.toml`'s `eider = "0.1"` (what
`eider toolchain show` prints here). Install `eider` and the latest toolchain with
eider-lang's `install.sh --toolchain` (from its latest release); without either, the
scripts stop with exit 2 and say so. The toolchain's `VERSION` must have this package's
MAJOR.MINOR (the `eider` field of `eider.toml`), else they stop with exit 2 and say which
release to use. eiderc and eider-pkg run through `eider` (`eider eiderc ...`, `eider eider-pkg
...`, with that toolchain), or directly when `eider` is not on the PATH.

The dependencies, eider-json, eider-logging, eider-compression and eider-tls (crypto is the toolchain's), are git packages. To build offline or against a checkout with
uncommitted changes, eider-pkg's `EIDER_PKG_OVERRIDE=json=<dir>` takes it from a local
directory; `scripts/env.sh` sets it for you to `$EIDER_JSON`, else `../eider-json` when that
checkout exists, else the pinned release `.vendor/json` of an eider-lang checkout used as the toolchain
(fetched there and hash-checked on first use by its `scripts/vendor.sh`), else its repository
(network). eider.lock keeps the git source either way (a library doesn't commit its lock). eider-tls is taken from `../eider-tls` until its
next release (the v0.7.1 tag does not yet have the toolchain's crypto in its manifest); `crypto` needs a toolchain of Eider 0.7.6 or later
(an eider-lang checkout with `packages/crypto` works). `scripts/test.sh` also runs `tests/tls_interop.sh` (openssl, curl; `skip` without them).

eider-lang's `scripts/verify.sh` builds and tests this repository against its own checkout
when it is next to it (`scripts/check-tools.sh`).

## Versions

`VERSION` and `eider.toml` hold this package's version (semver). Before 1.0 its MAJOR.MINOR
follows the Eider toolchain it goes with (`eider = "0.1"`) and its PATCH is its own;
CHANGELOG.md lists the releases. A release is tagged `v<version>`.
