# eider-http

HTTP/1.1 for [Eider](https://github.com/klxdev/eider-lang): a strict incremental parser, a
server with deadlines, back-pressure and graceful shutdown, a blocking client, a router,
middleware (request ids, access logs, errors as problem+json, body limits and timeouts per
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
| `http/server` | `listen`, `Server.serve(handler, token)`: a worker pool, deadlines, graceful shutdown |
| `http/client` | `connect`, `Conn.request`, `fetch`, `get`, `post` |
| `http/router` | method and path patterns with parameters, 404 and 405 |
| `http/middleware` | `request_id`, `access_log`, `access_log_with` (a `std/log` Logger), `errors`, `problems`, `body_limit`, `timeout`, `cors`, `bearer`, `basic`, `chain` |
| `http/metrics` | counters, an in-flight gauge and a latency histogram (Prometheus text), optionally per route |
| `http/sse` | server-sent events |
| `http/ws` | WebSockets (RFC 6455) with limits, a codec and a test client |
| `http/trace` | W3C traceparent propagation and a span per request |
| `http/problem` | `ApiError`, written as RFC 9457 problem+json |
| `http/profiling` | profiler labels per route, `/debug/profile`, `/debug/heap` |
| `http/sock` | sending before a deadline, lingering close |

[docs/services.md](docs/services.md) is the design: the concurrency model, every limit and
default, the security posture (run it behind a TLS-terminating proxy), the tests and the
known gaps. JSON-RPC 2.0 over this package is
[eider-rpc](https://github.com/klxdev/eider-rpc); OpenAPI 3.1 services are
[eider-openapi](https://github.com/klxdev/eider-openapi). eider-lang's site has the
step-by-step guide ("Building services").

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

The dependency, eider-json, is a git package. To build offline or against a checkout with
uncommitted changes, eider-pkg's `EIDER_PKG_OVERRIDE=json=<dir>` takes it from a local
directory; `scripts/env.sh` sets it for you to `$EIDER_JSON`, else `../eider-json` when that
checkout exists, else the pinned release `.vendor/json` of an eider-lang checkout used as the toolchain
(fetched there and hash-checked on first use by its `scripts/vendor.sh`), else its repository
(network). eider.lock keeps the git source either way (a library doesn't commit its lock).

eider-lang's `scripts/verify.sh` builds and tests this repository against its own checkout
when it is next to it (`scripts/check-tools.sh`).

## Versions

`VERSION` and `eider.toml` hold this package's version (semver). Before 1.0 its MAJOR.MINOR
follows the Eider toolchain it goes with (`eider = "0.1"`) and its PATCH is its own;
CHANGELOG.md lists the releases. A release is tagged `v<version>`.
