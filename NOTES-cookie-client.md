# NOTES for the lead: cookie-client (issues #15 cookies, #14 high-level client)

Branch `feat/cookie-client`. New modules: `cookie.ei` (`http/cookie`), `cookiejar.ei` (`http/cookiejar`, the client's cookie
store, split out of pool.ei so it is testable on its own), `pool.ei` (`http/pool`). Docs: `docs/cookie.md`, `docs/pool.md`.

## (a) CHANGELOG bullets

- **`http/cookie`** (#15): the `Cookie` header, `Set-Cookie` built and parsed (Path, Domain, Max-Age, Expires, Secure, HttpOnly,
  SameSite, Partitioned) with the RFC 6265bis rules (name and value validity, no header injection, size limits, `__Host-` and
  `__Secure-` prefixes, lenient RFC 6265 date parsing), a signed jar (HMAC-SHA-256 over name and value, constant-time verify, a list
  of keys for rotation) and a private jar (AES-256-GCM, the name as associated data, rotation). Docs: docs/cookie.md. Tests:
  `tests/cookie_test.ei`.
- **`http/cookiejar`**: a client cookie store (domain and path matching, expiry, Secure, "leave Secure cookies alone", limits).
  Test: `tests/cookiejar_test.ei`.
- **`http/pool`** (#14): a high-level client: a pool of keep-alive HTTP/1.1 connections per authority (max idle per host, idle timeout,
  stale-connection detection, one retry of an idempotent call), HTTP/2 multiplexing over one connection when ALPN selects `h2`,
  redirects (301/302/303/307/308 method and body rules, a limit, credentials dropped across origins, https to http refused by default),
  a cookie jar, a base URL, default headers, one deadline per call, gzip/deflate/zstd decoding. Thread-safe (state behind `sync.Lock`s).
  Docs: docs/pool.md. Tests: `tests/pool_test.ei`, `tests/pool_tls_test.ei`.
- **`http/h2`**: a client stream of a HEAD request no longer fails with PROTOCOL_ERROR when the response's `content-length` is not
  followed by a body (also 204 and 304); found by the pool's HEAD test. (5 lines in h2.ei: a `head_req` field of `Strm`.)

## (b) README module-table rows

| `http/cookie` | `Cookie`/`Set-Cookie` parsing and building (RFC 6265bis rules, prefixes, no header injection), signed (HMAC) and private (AES-GCM) jars with key rotation |
| `http/cookiejar` | a client cookie store: domain/path matching, expiry, Secure |
| `http/pool` | a high-level client: per-authority connection pool, h2 multiplexing, redirects, cookie jar, base URL, default headers, deadlines, gzip |

Also link docs/cookie.md and docs/pool.md from README/services.md.

## (c) Tests that use threads (for the TSan list in scripts/test.sh)

`tests/pool_test.ei`, `tests/pool_tls_test.ei` (`tests/cookie_test.ei` and `tests/cookiejar_test.ei` are single-threaded).
I could NOT run them under TSan: this machine's `cc` cannot build a `-fsanitize=thread` program (`scripts/test.sh` printed its skip line).

Optional interop, not hooked into scripts/test.sh (that file is yours): `tests/pool_interop.sh <dir>` with the built
`tests/pool_interop.ei` as `<dir>/pool_interop` (python3 `http.cookies` reads our Set-Cookie lines; our client against python's
`http.server`: redirects, cookies, 307, one keep-alive connection). It skips without python3. Build and run like the h2 interop:
`ei build tests/pool_interop.ei -o $B/pool_interop && sh tests/pool_interop.sh $B`. I ran it by hand: all 3 checks ok.

## (d) Not done, and why

- No public suffix list: `cookiejar` refuses single-label `Domain`s only (documented).
- No streaming request or response bodies, no proxy support, no h2c prior knowledge (plain `http://` is HTTP/1.1), no cap on the
  total connections per host (only on idle ones), no `Retry-After`, no DNS cache: out of scope of the issue's list, documented in docs/pool.md.
- `SameSite` and `HttpOnly` are parsed and written but not enforced by the jar (a client that is not a browser cannot know the site context).
- The first calls to an https authority whose protocol is not yet known take a per-authority gate while one of them dials (so a
  burst lands on one h2 connection); a black-holed host therefore delays the calls queued behind the first until its deadline.
- Redirect credential stripping is permanent for the rest of a call's chain (a chain that comes back to the first origin does not
  get `Authorization` again).
- The pool only takes `List[u8]` URLs (there is no `String` to `str` conversion; `"...".bytes()` for literals).
- `tests/pool_test.ei` has a few sleeps (idle timeouts of 150 to 800 ms) and a 1.5 s handler for the deadline case; they are margins, not
  asserted timings, and 6 runs of each test gave identical output.
