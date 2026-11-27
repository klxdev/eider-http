# WebSocket extensions: permessage-deflate and WebSocket over HTTP/2

Two additions to `http/ws`, both off by default: compression of messages (RFC 7692) and WebSockets
carried by an HTTP/2 stream (RFC 8441). Existing code and existing connections behave as before.

## permessage-deflate (RFC 7692)

Server: ask for it in the options handed to `ws.accept`.

```
let opts = ws.options().with_deflate()                       // level 6, messages of 32 bytes or more, context takeover
let opts2 = ws.options().deflate_with(9, 0, false)           // level, minimum size, takeover: false = no context takeover
```

`accept` reads every `Sec-WebSocket-Extensions` header of the request (`wsext.extension_items`) and takes
the first `permessage-deflate` offer it can honour (`wsext.negotiate_server`); the answer carries the
chosen parameters, and `Conn.extensions()` returns it. A client that did not offer the extension gets plain
frames, as does one whose offers are all declined. An offer is declined (not echoed, the next one is tried)
when it has an unknown or repeated parameter, a value on `server_no_context_takeover` or
`client_no_context_takeover`, a window size outside 8 to 15, or `server_max_window_bits` under 15.
`deflate_takeover = false` makes the server answer with both `*_no_context_takeover` parameters, which the
client must then follow.

Client: `ws.dial_with(addr, target, protocols, opts, dl)` (and `dial_conn_with`, `dial_h2`) take a
`ws.DialOptions` (`ws.dial_options()` has the extension off):

```
let mut o = ws.dial_options()
o.deflate = true          // offer permessage-deflate
o.no_takeover = false     // true: client_no_context_takeover; server_no_context_takeover
o.max_message = 4194304   // what recv_message may return, and what one compressed message may inflate to
let mut c = ws.dial_with(addr, "/chat", protos, o, dl)?
c.send_text(s, dl)?                 // compressed (RSV1) when negotiated and not shorter than o.min
match c.recv_message(dl)? { ... }   // fragments joined, inflated; Closed when the server closed
```

`Client.recv_frame` still returns frames as they are on the wire (`rsv1` set on a compressed message's first
frame, the payload compressed); `recv_message` is the call that decompresses. `Client.extensions` is what
the server accepted. The client sends plain `permessage-deflate` (it does not offer `client_max_window_bits`).

### What is on the wire

* A data message is compressed as raw DEFLATE, flushed with a sync flush, the final `00 00 ff ff` removed,
  and sent in one frame with RSV1 set. Control frames (ping, pong, close) are never compressed. A message
  shorter than the minimum (and an empty one) is sent as it is; it does not enter the compression window.
* A received message gets `00 00 ff ff` appended and is inflated. A peer that ends its message with a BFINAL
  block is understood too (the window carries over to the next message).
* Context takeover: the 32 KiB window stays between messages in each direction; with `*_no_context_takeover`
  that side starts every message with an empty window.
* Frames: RSV1 is accepted only on the first frame of a text or binary message, and only on a connection that
  negotiated the extension; RSV1 on a control frame or a continuation frame, RSV2 or RSV3, or RSV1 without the
  extension, close with 1002. Invalid DEFLATE data, or a compressed text message that inflates to invalid UTF-8,
  closes with 1007.

### Decompression bombs

`Options.max_message` is the limit of a message after inflating as well as before. The inflater
(eider-compression's `Inflater`) is given an absolute output cap per message and refuses before producing more
than `max_message` bytes, so a bomb of a few kilobytes that would inflate to gigabytes allocates at most
`max_message` bytes and closes the connection with 1009. The compressed bytes of one message are capped at
`max_message` plus a small allowance for DEFLATE's own overhead on incompressible data. The same holds
in the client (`DialOptions.max_message`). `Options.max_frame` still bounds each frame's (compressed) payload.

### Limits of this implementation

* The window of the encoder is fixed at 32 KiB (eider-compression's `Deflater` has no window-size parameter), so a
  client offer that needs `server_max_window_bits` under 15 is declined, and the client never offers
  `client_max_window_bits`; a server's `client_max_window_bits=N` in an answer is an error. The decoder accepts any
  window up to 32 KiB, so `client_max_window_bits` in an offer is fine (echoed when it came with a value).
* Without context takeover, a new `Deflater` is built for each message (about 130 KB of tables): use a minimum
  size (`deflate_min`) so small messages skip it.
* Messages are sent as one frame each (a message over `max_frame` is therefore refused by the peer's decoder);
  split large messages in the application.

Interoperability: `tests/ws_deflate_interop.sh` runs an Eider server against a stdlib-only python3 client that
compresses and inflates with python's zlib (an independent DEFLATE), with and without context takeover and
with a BFINAL message. `skip`ped without python3. Python's `websockets` package, Autobahn and the Go libraries
were not available offline, so no conformance-suite run was made.

## WebSocket over HTTP/2 (RFC 8441)

A server opts in with `h2.Options.connect_protocol = true`: it then advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL`
(0x8) and accepts an extended CONNECT: `:method CONNECT` with `:protocol`, `:scheme`, `:path` and `:authority`.
Without the option, a request with `:protocol` is a stream error (`PROTOCOL_ERROR`), as the RFC requires, and a
`:protocol` on a method other than CONNECT always is.

```
var opt = h2.options()
opt.connect_protocol = true
h2.serve(wire, opt, h2.handler(router_handler, peer, ctx))        // or server.Config.h2 = Some(opt)
```

`h2.handler` hands an extended CONNECT to the handler at once, without waiting for a request body (the DATA is the
tunnel): `req.method` is `CONNECT`, `req.target` the `:path`, `req.get_ctx("h2_protocol")` the `:protocol`. The same
handler as over HTTP/1.1 works: `ws.accept(req, opts, run)` sees the context, skips the Upgrade/Key checks that do
not exist in HTTP/2 (it still needs `Sec-WebSocket-Version: 13`, applies `origins`, picks a subprotocol and negotiates
permessage-deflate), and answers **200** with no `Upgrade`, `Connection` or `Sec-WebSocket-Accept`. `h2.handler`
runs `run` on the stream: reads are the stream's DATA, writes are DATA frames under the stream's flow control,
and a `Conn` is the same frame codec as before (`recv`, `send_text`, `close`, ...). When `run` returns the stream's
sending side ends and what is unread is reset. A route registered with `router.get` only matches GET: for
extended CONNECT use a handler that looks at `req.method` (as the tests do); the router's own `get` routes do not match CONNECT.
`ws.accept` answers 501 for another `:protocol`.

Client: `ws.dial_h2(hc, target, protocols, opts, dl)` with an `h2.Client` waits for the server's SETTINGS
(`Conn.wait_connect_protocol(dl)` is the check), opens the extended CONNECT stream (`h2.Conn.open` refuses
`:protocol` until the peer advertised the setting), expects `200` and returns a `ws.Client` whose frames travel
in the stream's DATA; its `send_...`, `recv_frame`, `recv_message`, `close` and `drop_connection` (reset
the stream; the h2 connection stays the caller's) work as over a socket. Several WebSockets, and ordinary requests,
share one h2 connection. Over https, build the `h2.Client` as for any h2 request (`secure.connect_h2`).

Tests: `tests/ws_deflate_test.ei` (negotiation, RFC 7692 7.2.3's byte examples, takeover, the bomb and its cap,
RSV rules, a loopback server and client) and `tests/ws_h2_test.ei` (an Eider client against an Eider server
through h2 over a socket pair, plus hand-made HEADERS for the refusals).
