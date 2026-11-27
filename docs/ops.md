# Operational plumbing: the PROXY protocol and Unix-domain sockets

Two things a service meets once it runs behind something else: a layer-4 load balancer that hides the client's
address behind its own (HAProxy's PROXY protocol), and a socket that is a file (the Docker Engine API, a sidecar, a
proxy on the same host). Both are plain additions: the server and the client are the ones in
`docs/services.md`, off unless asked for. (OpenAPI generation, also in issue 21, lives in
`klxdev/eider-openapi`, not here.)

## PROXY protocol: `http/proxyproto`

A TCP load balancer (HAProxy `send-proxy`, AWS NLB with proxy protocol v2, nginx `proxy_protocol on`) forwards bytes and
so the server sees the balancer's address. The balancer can say who the client was by writing a header first.
`http/proxyproto` reads versions 1 (text) and 2 (binary) of the HAProxy specification at the start of an accepted
connection, and writes them.

```
import http.proxy
import http.proxyproto
import http.server

let trust = proxy.trust_none().allow("10.0.0.0/8").unwrap()          // the balancers
let mut cfg = server.config()
cfg.proxy_protocol = Some(proxyproto.options(trust))                  // off (None) by default
let srv = server.listen(net.ipv4(0, 0, 0, 0, 8080), cfg).unwrap()
```

`Request.peer` is then the client ("203.0.113.7:51234"; an IPv4-mapped IPv6 address is the IPv4 one, a unix source is
`unix:/path`), so `ratelimit` keys on the client, the access log names the client, and `proxy.middleware` (for
`X-Forwarded-For`) still works on top. The rest of the header is in the request context: `proxy_peer` (the balancer's own
address), `proxy_dst`, `proxy_version`, and from a v2 header `proxy_alpn`, `proxy_authority`, `proxy_unique_id`,
`proxy_ssl`, `proxy_ssl_version`, `proxy_ssl_cn`, `proxy_ssl_cipher`, `proxy_ssl_verify` (`req.get_ctx("proxy_authority")`).
A header without an address (v1 `UNKNOWN`, v2 `LOCAL`: the balancer's own health checks, or `UNSPEC`) leaves `peer` as the
connection's own address and sets `proxy_version` only.

The header is read before anything else on the connection, so it composes with TLS (the balancer sends the header and then
the ClientHello: the header is read first) and with HTTP/2 prior knowledge. It is read with a peek and then taken
by exact length: no byte of the request is ever consumed, and a header sent a byte at a time works.

### Nothing is trusted silently

Anybody can write a PROXY header, so one means something only from a balancer you named. The allow-list is a
`proxy.Trust` (CIDR ranges and `allow_unix()`; an empty one trusts nothing, `0.0.0.0/0` is refused, as in
`http/proxy`). The rules:

| mode | from a trusted address | from any other address |
|---|---|---|
| `Required` (default) | must open with a header; no header or a bad one: connection dropped | dropped, whatever it sends |
| `Optional` (`.optional()`) | a header is used if present, none is fine (a direct client) | a header: dropped (`Refuse`, default) or skipped and not believed (`.ignore_untrusted()`); none is fine |

And in every mode: **a header that starts like one but does not parse is dropped**, never passed on as HTTP (the HAProxy
rule: a v1 `PROXY ` prefix or the v2 signature must be followed by a valid header). Bytes that are neither are just the
start of the request in `Optional` mode (`GET`, the HTTP/2 preface `PRI * ...`), and a drop in `Required`.
A dropped connection is closed without a response and logged at `warn` with `Config.log` (peer and reason).

Limits (all enforced before anything is allocated from the header's own claims): a v1 line is at most 107 bytes with its
CRLF (108 bytes are examined); a v2 header at most `max_v2` bytes in all (default 536, the size every receiver must accept,
`.with_max_v2(n)` up to 65551); the header must arrive within `timeout` (5 s; `.with_timeout(d)`); a CRC32c TLV is
verified (`.without_crc_check()` to skip it) and a wrong one is a drop.

### What is parsed

* v1: `PROXY TCP4|TCP6 src dst sport dport\r\n` (single spaces, an address of exactly that family, ports 0 to 65535 without
  leading zeros) and `PROXY UNKNOWN ...`.
* v2: the 12-byte signature, version 2, commands LOCAL and PROXY, families UNSPEC/INET/INET6/UNIX over UNSPEC/STREAM/DGRAM,
  everything else invalid. TLVs must tile the rest of the header exactly (a TLV that overruns is invalid): ALPN, authority,
  CRC32c (4 bytes), NOOP, unique id (at most 128 bytes), SSL with its version/CN/cipher/signature/key-algorithm sub-TLVs, and
  every other type (including the `0xE0`-`0xEF` application range and NETNS), which are kept in `Header.tlvs` and skipped.

`proxyproto.decode(buf, max_v2, verify_crc)` is the pure parser (`Found(header, bytes used)`, `NeedMore`, `Absent`,
`Invalid(why)`) for a program that owns its sockets; `accept_conn(fd, peer, options)` is what the server calls.

### Writing the header

For tests, for a client that must speak to a balancer-style server, and for a proxy you write:

```
let h = proxyproto.header(net.ipv4(198, 51, 100, 7, 4000), net.ipv4(192, 0, 2, 1, 443))
            .with_alpn(sys.lit("h2")).with_authority(sys.lit("shop.example"))
let wire = proxyproto.encode_v2(h, true).unwrap()                // true: add a CRC32c TLV
let c = proxyproto.connect(addr, wire, dl).unwrap()               // an http/client Conn, the header sent first
```

`encode_v1(src, dst)` (IPv4 or IPv6), `v1_unknown()`, `local()` (a v2 LOCAL), `.datagram()`, `.with_ssl(...)`, `.with_tlv(kind, bytes)`.
The header goes out on the connection that `connect` opens, not on a reconnect after the server closed it. `http/proxy`
is the `X-Forwarded-For` module, not an upstream client: it has no connections of its own to which to prepend a header, so a
reverse proxy built on `client.connect` sends one with `proxyproto.connect`.

## Unix-domain sockets: `http/unixsock`

`std/net` has AF_UNIX (`net.unix(path)`, `net.listener`, `net.connect`, `net.pair`), and `server.listen`, `Server.serve` and
`client.connect` take any `net.Addr`, so a unix socket was already servable; `http/unixsock` adds what a socket *file* needs.

```
let srv = unixsock.listen(sys.lit("/run/app/api.sock"), cfg, unixsock.options().with_mode(0o660)).unwrap()
let stats = srv.serve(handler, tok)
unixsock.remove(sys.lit("/run/app/api.sock"))             // closing a listener leaves the file

let r = unixsock.get(sys.lit("/var/run/docker.sock"), "/v1.43/containers/json", dl)    // Host: localhost
let mut c = unixsock.connect(path, dl).unwrap()            // keep-alive, reconnects: the same Conn as over TCP
let h2c = unixsock.connect_h2(path, h2.options(), dl)      // prior-knowledge HTTP/2 (the server sets Config.h2)
```

* **Stale files.** A killed server leaves its socket file and `bind` then fails. `listen` removes the path only if it is a
  socket **and nothing listens on it** (a probe connection is refused). A live server (the probe is accepted, or its queue
  is full), any other probe error (permission denied), or a file that is not a socket (a regular file, a directory, a
  symlink) is an error and is left alone. `.keep_stale()` turns removal off.
* **Permissions.** The socket file's mode is `0777` minus the umask, which this library cannot set, and the mode decides who
  can connect. `.with_mode(m)` creates the socket inside a fresh `0700` directory next to the path, `chmod`s it, and renames
  it into place: it is never reachable with a wider mode, not even for an instant. The rename replaces what is at the path
  then, so two servers starting on one path at the same moment race (use a lock file for that); the longer temporary
  path makes the 107-byte limit a little tighter.
* **Abstract sockets** (Linux): `abstract_addr(name)`, `listen_abstract(name, cfg)`, `connect_to(abstract_addr(name), host, dl)`:
  no file, no cleanup, no permissions (any process of the network namespace can connect).
* **The client** sends `Host: localhost` (what the Docker CLI sends; `connect_host(path, host, dl)` for another), since the
  text of a unix address is not a host name.
* **The server side.** A client's `Request.peer` is `unix:` (an unbound client socket has no name): `proxy.Trust.allow_unix()`
  trusts such a peer for `X-Forwarded-For`, and PROXY protocol with `allow_unix()` trusts a balancer on the same host
  (`tests/unixsock_test.ei`: the header's client replaces the `unix:` peer, `proxy_peer` keeps it). Without `allow_unix` a unix
  peer is untrusted and its header is refused. Rate limiting keys every unix peer as one client, so key on a header or a
  principal instead if you rate limit a unix listener at all.
* h2c, `Server.stats()`, graceful shutdown, deadlines and the worker limits are the ones of the TCP server; `Server.port()`
  is 0.

## Tests

* `tests/proxyproto_test.ei`: the parser and writer without a socket: the specification's examples (v1 and v2, all families,
  TCP and UDP), TLVs (ALPN, authority, unique id, SSL, CRC32c checked against an independent implementation's value),
  truncated, oversized and garbage input, the writer read back.
* `tests/proxyproto_server_test.ei`: through the server over loopback TCP: the trusted/untrusted matrix (required, optional,
  refuse, ignore, empty allow-list), headers sent a byte at a time, dropped connections, the handler's view
  (`peer`, rate-limit key, context), the `max_v2` cap, the client writer with keep-alive.
* `tests/unixsock_test.ei`: unix e2e in a directory under `/tmp`: serve and fetch, keep-alive, stale/live/non-socket paths,
  modes, abstract, h2c, PROXY over a unix listener.
* `tests/unixsock_interop.sh` (with `tests/unixsock_interop_server.ei`; part of `scripts/test.sh`): curl `--unix-socket`
  (GET, POST, 1 MiB, Host, h2c, the file's mode) and python3 as an independent PROXY v1/v2 writer; `skip` for a missing tool.
