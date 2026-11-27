# NOTES: ops (issue 21: PROXY protocol, Unix-domain sockets)

## (a) CHANGELOG bullet
- `http/proxyproto`: HAProxy PROXY protocol v1 and v2 at the start of an accepted connection (all address families, TCP/UDP, LOCAL and PROXY, TLVs: ALPN, authority, SSL, unique id, CRC32c checked; strict limits: 107-byte v1 line, 536-byte v2 header by default), a trusted-proxies allow-list (`proxy.Trust`), modes `Required` and `Optional` and refuse-or-ignore for an untrusted sender (a header that is recognised but invalid always drops the connection), a writer (`encode_v1`, `encode_v2`, `connect`), and `server.Config.proxy_protocol` (default `None`) so `Request.peer` and the rate-limit key are the real client. `http/unixsock`: serving and dialling Unix-domain sockets: `listen` (stale socket files removed only when nothing listens, an optional permission mode applied before the socket is reachable, abstract sockets), `connect`/`fetch`/`get` with `Host: localhost` (the Docker Engine API), h2c over a unix socket. docs/ops.md.

## (b) README module-table rows
| `http/proxyproto` | HAProxy PROXY protocol v1/v2: parser, writer, trusted-proxy allow-list, `server.Config.proxy_protocol` |
| `http/unixsock` | HTTP over Unix-domain sockets: listen (stale files, mode, abstract), connect/fetch with `Host: localhost`, h2c |

## (c) Test files that use threads (TSan list)
tests/proxyproto_server_test.ei, tests/unixsock_test.ei. (tests/proxyproto_test.ei is pure.) Not run under TSan by me.

## (d) Not done / caveats
- `http/proxy.ei` has no upstream connections (it is the X-Forwarded-For module, not a reverse proxy), so there is nothing in it to prepend a v2 header to; `proxyproto.connect` (a client `Conn` with the header sent first) is the building block instead.
- std.net has AF_UNIX (so nothing is missing there), but no `umask`, no `unlink` (fs.remove_all is used: it removes a socket file) and no way to bind with a mode: the mode option uses a private 0700 directory + chmod + rename. The rename replaces whatever is at the path at that instant (a two-servers-at-once race is not closed).
- A dropped PROXY connection is logged at warn (`Config.log`) but not counted in `server.Stats` (adding a field would change a record other workers construct).
- Only the connection's first header is read; the PROXY header is not re-sent on a client reconnect.
- scripts/test.sh: I added an interop block (unixsock_interop.sh) beside the h2 one; the TSAN list is untouched.
- `server.Config` gained a last field `proxy_protocol` (positional constructor in `config()` updated); another worker adding a Config field will conflict textually there.
