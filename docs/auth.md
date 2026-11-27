# Authentication and CSRF: http/auth, http/jwt, http/csrf

Three modules, each a layer over the same `http.Handler` shape as `middleware.cors`
(see `docs/services.md`), all on the toolchain's `crypto` package:

| module | what it does |
| --- | --- |
| `http/auth` | `Authorization` parsing (Basic, Bearer), verifiers, middleware with 401/403/400 challenges, scopes |
| `http/jwt` | JWS/JWT verification and signing, key sets and JWKS, claim checks |
| `http/csrf` | signed double-submit tokens, `Origin` and `Sec-Fetch-Site` checks, a small cookie helper |

`middleware.basic` and `middleware.bearer` stay as they were; `http/auth` is the fuller
version of the same idea (verdicts, optional mode, JWT, scopes).

## Basic

```
import http.auth

let users = auth.basic_table(List[(lit("ada"), lit("pa:ss"))])
let app = auth.basic(auth.config("admin"), users, router.handler(r))
```

`parse_basic` follows RFC 7617: the scheme is case-insensitive; the credentials are
standard, padded base64 of UTF-8 text `user:password`; the user is what precedes the first
colon (so passwords may contain colons); a user with control characters, text that is not
UTF-8, bad or unpadded base64, and a missing colon are all errors. A request with several
`Authorization` headers is refused. The challenge is `Basic realm="..", charset="UTF-8"`.

The check is a `BasicVerifier`, `fn(user, password) -> Option[principal]`: yours (look the
user up, verify a salted slow hash). `basic_table` is for fixed tables: it hashes both sides
and compares every entry in constant time, so neither the existence of a user, nor how much
of a password was right, nor its length shows in the time taken. Basic sends the password in
the clear: serve it over TLS only.

## Bearer

```
let api = auth.bearer(auth.config("api"), verify, handler)        // verify: fn(token) -> Verdict
```

`Verdict` is `Granted(principal, scope, claims)`, `Denied` or `Forbidden(scope)`. The
responses follow RFC 6750 section 3:

| situation | status | `WWW-Authenticate` |
| --- | --- | --- |
| no credentials, or another scheme | 401 | `Bearer realm=".."` (no error code) |
| `Denied` | 401 | `Bearer realm="..", error="invalid_token"` |
| `Forbidden("read")` | 403 | `Bearer realm="..", error="insufficient_scope", scope="read"` |
| malformed header (not a token68, several `Authorization` headers) | 400 | `Bearer realm="..", error="invalid_request"` |

Bodies are problem+json with fixed text; nothing about why a token failed reaches the
client. `auth.optional(realm)` lets requests with no `Authorization` header through
anonymously (bad credentials are still refused).

### What the handler sees

`auth.principal(req)` (also `req.get_ctx("principal")`), `auth.scheme_of(req)`,
`req.get_ctx("scope")` (space-separated) and `req.get_ctx("claims")` (a JWT's payload as
JSON; empty for opaque tokens). The principal is also in the response's `ctx`, so the access
log (`middleware.access_log`) records it, including for 403s. These names are written only
by this middleware: whatever a request carries under them when it arrives is dropped first.

`auth.require_scope(cfg, "write", handler)` goes inside `bearer`/`jwt_bearer` and answers
403 `insufficient_scope` for a token without that scope (401 when unauthenticated):

```
r.get("/items", auth.require_scope(cfg, "read", list_items))
r.post("/items", auth.require_scope(cfg, "write", add_item))
```

## JWT

```
import http.jwt

let keys = jwt.keyset().add("k1", jwt.Secret(secret))        // or parse_jwks(...)
let mut v = jwt.validation(List[jwt.HS256])                     // the allow-list: required
v.issuer = Some(lit("https://issuer.example"))
v.audience = Some(lit("my-api"))
v.leeway = 30                                                // seconds of clock skew
let api = auth.jwt_bearer(auth.config("api"), v, keys, handler)
```

(or `jwt.verify(v, keys, token)` directly: `Ok(claims)` with `claims.subject()`,
`claims.str("x")`, `claims.int("x")`, `claims.scopes()`; `Err(jwt.Error)` with
`jwt.error_text` for your log.)

Algorithms: HS256/384/512, RS256/384/512 (PKCS#1 v1.5), PS256/384/512 (PSS), ES256 (P-256),
ES384 (P-384) and EdDSA (Ed25519). Signing: `jwt.sign(alg, key, kid, payload_json)` with
`SecretKey`, `RsaPrivate`, `EcPrivate`, `Ed25519Seed`; `jwt.claims().str(..).int(..).strs(..).json()`
builds the payload.

What is refused, and the reasoning:

* **`alg` is not trusted.** It must be in `Validation.algs` and fit the type of the key
  chosen: an HMAC `Secret` only takes HS*, an RSA key RS*/PS* (2048 bits or more), a P-256
  key ES256, a P-384 key ES384, an Ed25519 key EdDSA. That closes the classic confusion where
  an RSA public key is used as an HMAC secret. `none` is not an algorithm here at all
  (nor is anything unknown, such as ES512). A key set entry can pin its own `alg`
  (`add_for`, or a JWK's `alg`).
* **Keys by `kid`.** A token naming a `kid` the set lacks is refused (no fall back to
  "try them all"); a token without one needs a set of exactly one key.
* **Order.** Size, shape, header, allow-list, key, signature, and only then is the payload
  parsed. Signatures and MACs are compared in constant time (the crypto package).
* **Strict encoding.** base64url without padding, exactly three non-empty parts, duplicate
  members in header or payload refused (two parsers reading one document two ways is an
  attack), `crit` refused (this code honours no extension), tokens over `max_size` (8192)
  refused.
* **Claims.** `exp` is required unless `require_exp = false`, and a token is expired at
  `now >= exp + leeway` (RFC 7519: "on or after"); `nbf` must not be in the future beyond
  the leeway; `iat` must not be in the future, and with `max_age > 0` must exist and not be
  older; `iss` must equal the expected issuer; `aud` (a string or an array) must contain the
  expected audience. NumericDates are non-negative JSON numbers, fractions are cut off.
  With `audience = None` no audience is required: set it for anything with more than one
  audience in the world.
* HMAC secrets: `Secret(bytes)` takes any non-empty length; `jwt.secret_strong(bytes)`
  insists on 32 or more.

### JWKS

`jwt.parse_jwks(document, allow_oct)` reads `{"keys":[...]}` (RFC 7517): `RSA`, `EC` (P-256,
P-384) and `OKP` (Ed25519) keys, with `kid` and `alg` kept; keys marked `"use":"enc"` and
other key types or curves are skipped, malformed ones are an error, and `oct` (symmetric)
keys are only read with `allow_oct = true`, since a JWKS fetched from an issuer has no
business holding one. Fetching and refreshing the JWKS (a client request, a cache, rotation on
an unknown `kid`) is the application's; give `verify` the current `KeySet`.

## CSRF

For services whose browsers authenticate with a cookie. (Bearer tokens in a header you set
yourself are not ambient credentials and need none of this.)

```
import http.csrf

let cfg = csrf.new(key, csrf.session_cookie("sid")).unwrap()   // key: 32+ secret bytes
let app = csrf.protect(cfg, router.handler(r))
```

On safe requests (GET, HEAD, OPTIONS, TRACE) the middleware makes sure the browser has a
token cookie (`__Host-csrf`; Secure, Path=/, SameSite=Lax, readable by scripts) and gives the
handler the same token as `req.get_ctx("csrf_token")` to put in forms or a `<meta>` tag.
A token is `nonce.issued_at.mac` with `mac = HMAC-SHA256(key, session id, nonce, time)`. On
every other method all of these must hold, else 403 (generic problem+json):

1. **Origin check.** `Origin`, when present, is one of `cfg.origins` or (none configured) has
   the request's own `Host`; `Origin: null` never passes. With no `Origin`, `Sec-Fetch-Site`
   must be `same-origin` or `none` (`same-site` too with `allow_same_site`). With neither
   header the step passes unless `require_origin` is set (old clients; the token still applies).
2. **Cookie.** Exactly one cookie of the token's name (two means someone planted one from a
   sibling domain: refused), whose token is valid for this request's session and not older
   than `max_age` (a day).
3. **Submission.** The same token in `X-CSRF-Token`, compared in constant time.

A token is bound to the session id `cfg.session` returns (`session_cookie("sid")`; no
session means the empty session, for login forms). Because the MAC covers the session, a
token an attacker can obtain (their own) is no use against a victim's session, and a cookie
planted from a subdomain cannot fit it. Rotate sessions on login and the token follows
(it is reissued on the next GET).

Forms: `protect_form(cfg, handler)` checks origin and cookie and leaves the token to the
handler, which calls `csrf.check_form_token(cfg, req, field)` with the field it read.
`protect_logged(cfg, log, h)` tells `log` why each request was refused (`reject_reason`).

For `__Host-` cookies browsers need HTTPS; for plain-HTTP development set `cfg.cookie =
lit("csrf")` and `cfg.cookie_opts.secure = false`.

### Cookie helper

`csrf.set_cookie(name, value, opts)` builds a `Set-Cookie` value and `csrf.cookie_value(req,
name)` reads one (None for none or for duplicates). It is deliberately small, written here
because there is no http/cookie yet: names must be tokens, values cookie-octets, attributes
cannot carry `;` or control characters, `__Host-` needs Secure, Path=/ and no Domain,
`__Secure-` needs Secure, `SameSite=None` needs Secure. `cookie_opts()` is
`Path=/; Secure; SameSite=Lax`.

## Not here

ES512 (the crypto package has P-256 and P-384, not P-521), JWE, nested JWTs, OAuth/OIDC
flows (authorization code, discovery, token endpoints), a JWKS fetcher, password hashing,
sessions. The tests: `tests/auth_test.ei`, `tests/jwt_test.ei` (RFC 7515 A.1, jwt.io's HS256
example, tokens signed by OpenSSL and python), `tests/csrf_test.ei`, and the optional
`tests/jwt_interop.sh` (python3's hmac against HS256/384/512, both directions).
