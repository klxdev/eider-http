# The high-level client (`http/pool`)

`http/client` is one connection to one address, and `Conn.request` follows nothing. `http/pool` is what a program that
calls services wants on top of it: a pool of keep-alive connections per authority, HTTP/2 multiplexing when the server
picks `h2`, redirects, a cookie jar, a base URL, default headers, a deadline per call and gzip.

```
import http.pool
import http.cookiejar

let c = pool.new()                                            // http:// only; pool.system() or .with_tls(..) for https
    .with_base("http://127.0.0.1:8080/api/".bytes())
    .with_header("Accept", "application/json".bytes())
    .with_cookies(cookiejar.new())
    .with_timeout(time.seconds(10))
let r = c.get("users/7".bytes())                              // Result[http.Response, String]
let r2 = c.send(pool.call("POST", "/login".bytes()).with_body("application/json", body).with_timeout(time.seconds(2)))
```

A `Client` is cheap to copy and all its copies share one pool (state is behind `sync.Lock`s); hand a copy to every task.
`Ok(response)` is any status; `Err(text)` is for what could not be done: a URL, a connection, a deadline, a response that
does not parse, a refused or endless redirect.

## Connections

- The pool is per authority (`scheme://host:port`). A call takes the newest idle HTTP/1.1 connection of its authority or opens a
  new one: the number of connections follows the calls in flight. `with_max_idle_per_host(n)` (8; 0 keeps none) is the number
  kept idle, `with_idle_timeout(d)` (90 s) how long. Expired ones are closed when the pool is next used; nothing runs in the background.
- A connection goes back only when the response was read to the end and neither side asked to close: `Connection: close` (also
  from a server that ends a connection after `max_requests`) and an HTTP/1.0 response without keep-alive close it.
- An idle connection is checked before it is used. One that the server closed, or that has bytes nobody asked for, is dropped
  (`Stats.reused` does not count it). A call that fails on a pooled connection before any response, because the server closed
  it in the same moment, is sent once more on a new connection when its method is idempotent (GET, HEAD, PUT, DELETE, OPTIONS,
  TRACE); a POST is not.
- `https`: the client offers ALPN `h2` and `http/1.1`. When the server picks `h2` the authority has one connection and
  every call is a stream on it (`Stats.h2_conns`), up to the server's `max_streams` at once; the others wait for a slot. A
  connection that ended (GOAWAY, an error, the idle limit of `with_idle_timeout`) is replaced by the next call. The first
  calls to an https authority whose protocol is not yet known wait for one another's handshake (one task dials at a time) so that
  a burst ends up on one h2 connection; after that nothing is serialized. `with_h2(false)` offers `http/1.1` only.
  `with_h2_options(..)` sets the windows and limits of the h2 connections.
- Trust: `pool.system()` reads the CA bundle of the operating system (needs `fs`); `with_tls(secure.client_roots_pem(..))` trusts
  exactly your roots; without either, an https URL is an `Err`. The certificate and the host name are verified (`http/secure`).
  Plain `http://` is HTTP/1.1 only: there is no h2c prior knowledge.
- Not here: streaming bodies (a response is read whole, up to `limits.max_body`, 16 MiB), proxies, a limit on the total number
  of connections per host (a burst of N calls opens N connections), `Retry-After`, a DNS cache (a name is resolved per new
  connection).

## Redirects

`with_max_redirects(n)` (10; per call: `Call.with_max_redirects`; 0 returns the 3xx as it is).

| status | next request |
|---|---|
| 301, 302 | GET and no body when the method was POST; the same method and body otherwise |
| 303 | GET and no body, unless the method was HEAD |
| 307, 308 | the same method and body |
| 300, 304, others, or no `Location` | the response is returned as it is |

When the method turns into GET, the `Content-*` headers go with the body. `Location` is resolved against the URL it came from (RFC
3986: absolute, `//host/p`, `/p`, `?q`, `p`, `../p`, dot segments removed; a fragment is dropped); any scheme but http(s) is an
`Err`. When the target is another origin (scheme, host or port differ), `Authorization`, `Proxy-Authorization`, `Cookie` and `Host`
are dropped from that hop on, whether the call or the client's defaults set them; the jar picks its cookies again for each URL.
A redirect from `https` to `http` is an `Err` unless `with_allow_downgrade(true)` (the other direction is followed). More redirects
than the limit, a loop included, is an `Err` ("too many redirects"). The returned response has the context values `url` (the
final URL) and `redirects` (how many were followed): `resp.get_ctx("url")`.

## URLs, headers, deadline, decoding

- `with_base(url)` makes a relative call URL resolve against it the way a browser resolves a link: `users/7` goes below the base
  path (which should end in `/`), `/users/7` replaces it. A relative URL with no base, or a bad base, is an `Err`.
- `with_header(name, value)` on the client is sent with every call unless the call has a header of the same name;
  `Call.with_header` adds one. Headers are checked as the HTTP/1.1 writer does (no line breaks), also for h2.
- One deadline covers a call, redirects, connecting and TLS included: the client's `with_timeout` (30 s) or the call's.
- Compressed responses are decoded (gzip, deflate, zstd) with an `Accept-Encoding` sent when the call set none, within
  `compression.limits()`; `with_decoding(None)` leaves them as they came.
- `Stats` (`c.stats()`): `requests` (one per hop), `opened`, `reused`, `redirects`, `idle`, `h2_conns`.
- `c.close()` closes the idle and h2 connections; the client keeps working afterwards.
- Response `version` is 10 or 11 over HTTP/1.x and 20 over h2.

## Cookies

With `with_cookies(jar)` every response's `Set-Cookie` headers go to the jar and every request gets the jar's `Cookie` header (added
to a `Cookie` header the call sets itself). Rules and limits of the jar: [cookie.md](cookie.md).

## Tests

`tests/pool_test.ei` (plain http: reuse counted by the server's accepted connections, `Connection: close`, the idle limits on
both sides, a pooled connection the server closed, a pooled connection that dies under a GET and under a POST, eight calls that
wait for each other, redirect statuses, chains, loops and limits, credentials across origins, cookies, base URL, default
headers, deadlines, gzip) and `tests/pool_tls_test.ei` (https: h2 multiplexing with calls that wait for each other, bodies, HEAD,
body limit, redirects and cookies over h2, replacement of the h2 connection, HTTP/1.1 over TLS, `with_h2(false)`, verification
failures, the https to http downgrade).
