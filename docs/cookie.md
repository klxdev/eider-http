# Cookies (`http/cookie`, `http/cookiejar`)

`http/cookie` reads the `Cookie` header, builds and parses `Set-Cookie`, and signs or encrypts cookie
values with a key (or a list of keys, for rotation). It follows RFC 6265 and the stricter rules of
6265bis. `http/cookiejar` is the cookie store of a client (it is what `http/pool` keeps when you give it a
jar, see [pool.md](pool.md)).

## The `Cookie` header

```
import http.cookie

let pairs = cookie.request_cookies(q)                 // [(name, value)] of every Cookie header, in order
let sid = cookie.request_cookie(q, "SID")             // the first one called SID (browsers send the most specific first)
let line = cookie.cookie_header(pairs).unwrap()       // "a=1; b=2" (a client's header)
```

`parse_cookie_header` splits on `;`, trims spaces, and skips a pair that has no `=`, an empty or non-token name,
a control byte, or more than 4096 bytes. A value keeps its quotes (6265bis). `cookie_header` refuses a name that is
not a token and a value that has a byte outside the cookie-octet set (`;` among them), so it cannot be used to add a cookie.

## `Set-Cookie`

```
let c = cookie.text("session", "u42").path("/").secure().http_only().same_site(cookie.SsLax).max_age(3600)
let mut resp = http.text(200, "ok")
cookie.add(inout resp, c).unwrap()         // Set-Cookie: session=u42; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax
```

`cookie.build(c)` is the header value; `cookie.add` puts it on a response (call it once per cookie: a response may
carry many `Set-Cookie`). `c.removal()` is the cookie that deletes `c` (same name, `Path` and `Domain`, empty
value, `Max-Age=0`, `Expires` in 1970). `Cookie.expires` is Unix seconds, written as an HTTP date.

What `build` refuses (an `Err` and no header):

- a name that is not a token, a value with a byte outside `cookie-octet` (space, `"` inside the value, `,`, `;`, `\`,
  controls, non-ASCII): header injection is impossible. Quote or encode a value that needs those, or use a jar below;
- `Path` or `Domain` with a control byte, a `;` or a byte over 126, `Domain` that is not host characters;
- `name=value` over 4096 bytes;
- the prefix rules: `__Secure-` needs `Secure`; `__Host-` needs `Secure`, `Path=/` and no `Domain` (the prefix is
  matched without regard to case, as 6265bis says);
- `SameSite=None` or `Partitioned` without `Secure`.

`cookie.parse_set_cookie(line)` is the other direction (what a client does): it follows 6265 section 5.2, so
unknown or malformed attributes are skipped, the last `Path`/`Domain`/`Max-Age` wins, `Domain`'s leading dot is
dropped and the name lowercased, `Max-Age` accepts a negative number, `Expires` is read with the lenient date algorithm of
5.1.1 (`cookie.parse_date`: `Sun, 06 Nov 1994 08:49:37 GMT`, `Sunday, 06-Nov-94 08:49:37 GMT` and `Sun Nov  6 08:49:37 1994`
all give 784111777; two-digit years pivot at 70). It returns an `Err` for a control byte, a line with no `=`, an
empty or non-token name, `name=value` over 4096 bytes (an attribute value over 1024 bytes is ignored), and a broken
`__Secure-`/`__Host-` prefix. `parse_set_cookies(headers)` does every `Set-Cookie` of a response.

## Signed cookies

```
let jar = cookie.signed_jar(List[new_key, old_key]).unwrap()      // 32 bytes or more each; the first signs
let c = jar.sign(cookie.text("session", "u42").http_only().secure()).unwrap()
...
match jar.get(q, "session") {              // an Opened { value, key_index, current }, or None
    Some(s) => { ... }                     // None: absent, forged, altered, truncated, another cookie's, or unsigned
    None => {}
}
```

The value is `value.<tag>`: the tag is HMAC-SHA-256 over `name=value` under the first key, as 43 base64url characters. It
protects the value from change (the client can still read it). The cookie's name is part of what is signed, so a value
copied to another cookie does not verify. Verification tries every key (the comparison is constant time, from the
crypto package) and accepts exactly one spelling of the tag (a base64 string that decodes to the same tag but ends in
other padding bits is refused). `Opened.current` is false when an older key made the cookie: set it again
to move the client to the newest. Rotation: put the new key first, keep the old one until the cookies it signed have expired.

## Private (encrypted) cookies

```
let jar = cookie.private_jar(List[key]).unwrap()                  // 32 bytes each (AES-256)
let c = jar.encrypt(cookie.text("cart", "item=1; qty=2")).unwrap()   // any bytes may be the value
let v = jar.get(q, "cart")
```

AES-256-GCM from the toolchain's crypto package with a fresh random 96-bit nonce per cookie; the cookie name is the
associated data. The value is `base64url(nonce || ciphertext || tag)`, about 37 % larger than the plain value
plus 28 bytes: keep the 4096-byte limit in mind. `private_jar` is an `Err` when the crypto backend has no AES-GCM.
Encrypting needs `io` (it reads the system's randomness); decrypting does not.

## The client's jar (`http/cookiejar`)

`cookiejar.new()` is a store shared by its copies. `jar.store(host, path, secure, response_headers, now)` handles the
`Set-Cookie` headers of a response, `jar.header_for(host, path, secure, now)` gives the `Cookie` header value for a request.
Times are Unix seconds, passed in. The rules:

- no `Domain`: the cookie goes to exactly that host; with `Domain`: that domain and its subdomains, only when the
  host that set it is inside the domain. An IP address host only sets host-only cookies;
- there is no public suffix list, so a `Domain` of a single label (`com`) is refused and anything with a dot is allowed
  (a host under `co.uk` can set a cookie for `co.uk`); use a real list in front if that matters;
- `Path` defaults to the directory of the request path; matching follows 5.1.4; longer paths and older cookies come first;
- `Max-Age` outranks `Expires`; a time in the past deletes the cookie; lifetimes are capped at 400 days; no `Max-Age` and
  no `Expires` means the cookie lives as long as the jar;
- `Secure` cookies are stored only from https and sent only over https, and an http response cannot replace or delete one
  that an https response set (6265bis "leave Secure cookies alone");
- the prefix rules are those of `parse_set_cookie`; at most 50 cookies per domain and 3000 in all, the oldest dropped first;
- `SameSite` and `HttpOnly` are not applied: they depend on the page that makes a request, and this is not a browser.

## Tests

`tests/cookie_test.ei` (the RFC 6265 examples, the limits, prefixes, injection attempts, dates, signed and private
jars with every tamper case and rotation), `tests/cookiejar_test.ei` (the store), and the cookie round trips of
`tests/pool_test.ei`.
