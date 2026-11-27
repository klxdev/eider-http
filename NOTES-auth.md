# NOTES: auth (issue #17)

## (a) CHANGELOG bullet

- **http/auth, http/jwt, http/csrf** (docs/auth.md): the `Authorization` header (Basic per RFC 7617 with UTF-8 and colons in passwords, Bearer per RFC 6750) with verifiers, constant-time tables and `basic`, `bearer`, `jwt_bearer`, `require_scope` middleware (401 `invalid_token`, 403 `insufficient_scope`, 400 `invalid_request`, the principal, scopes and claims in the request context); JWT/JWS verification and signing (HS256/384/512, RS256/384/512, PS256/384/512, ES256, ES384, EdDSA) with a strict allow-list bound to the key type (no `none`, no algorithm confusion), `kid` key sets and JWKS parsing, `exp`/`nbf`/`iat` with leeway, `iss`/`aud`, size limits; CSRF protection with signed double-submit tokens bound to the session, `Origin`/`Sec-Fetch-Site` checks and a small SameSite cookie helper. Tests include RFC 7515 A.1, jwt.io's HS256 vector, OpenSSL- and python-made tokens.

## (b) README module-table rows

| `http/auth` | `Authorization` parsing (Basic, Bearer), verifiers, Basic/Bearer/JWT middleware with RFC 6750 challenges and scopes (docs/auth.md) |
| `http/jwt` | JWS/JWT verification and signing, key sets, JWKS, claim checks (docs/auth.md) |
| `http/csrf` | signed double-submit CSRF tokens, Origin/Sec-Fetch-Site checks, SameSite cookie helper (docs/auth.md) |

## (c) tests that use threads (TSan list)

None: tests/auth_test.ei, tests/jwt_test.ei and tests/csrf_test.ei call handlers directly and use no threads.

## (d) not done / caveats

- Interop: `tests/jwt_interop.sh` (+ `tests/jwt_interop_prog.ei`) is run from a block I added to `scripts/test.sh` just before the TSan section (additive; the lead may need to merge it with other workers' blocks). It `skip`s without python3.
- ES512 (P-521) is not implemented: the crypto package has P-256 and P-384 only. `none` and unknown algs are refused by design.
- RFC 7515 Appendix A.2 (RS256) and A.3 (ES256) vectors are not included (I did not have them to hand and would not reproduce key material from memory); RS256/PS256/RS384/ES256/ES384/EdDSA are instead checked with tokens signed by the OpenSSL CLI (independent implementation, embedded in tests/jwt_test.ei) plus sign/verify round trips. A.1 (HS256) and jwt.io's HS256 example are exact vectors.
- csrf.ei carries its own minimal cookie helper (`set_cookie`, `cookie_value`, `SameSite`, `CookieOpts`) because http/cookie does not exist in main; if a http/cookie lands, csrf should switch to it.
- `middleware.basic`/`middleware.bearer` are unchanged; http.ei, server.ei and middleware.ei are untouched.
- No JWKS fetching (network refresh policy is left to the application); no JWE, no OIDC.
- `jwt.verify` with `audience = None` requires no audience (documented).
