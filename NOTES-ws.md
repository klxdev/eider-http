# NOTES: ws (issue #19)

## (a) CHANGELOG bullet

- WebSocket: permessage-deflate (RFC 7692) in `http/ws` (new module `http/wsext`): `Options.with_deflate()` /
  `deflate_with(level, min, takeover)` on the server, `ws.dial_with`/`DialOptions` on the client, `Client.recv_message`;
  negotiates `Sec-WebSocket-Extensions` (`*_no_context_takeover`, `client_max_window_bits`), RSV1 on a compressed
  message's first frame, the `00 00 ff ff` tail, context takeover, and caps what a message inflates to at `max_message`
  (a bomb closes with 1009); off by default. WebSocket over HTTP/2 (RFC 8441): `h2.Options.connect_protocol`
  advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL` and `h2.handler` hands an extended CONNECT to the handler, where
  `ws.accept` answers 200 and runs the same `Conn` over the stream's DATA; `ws.dial_h2(h2.Client, ...)` is the client.
  `h2.Conn.open` refuses `:protocol` until the peer advertised the setting. Docs: docs/ws-extensions.md.

## (b) README module-table rows

| `http/wsext` | permessage-deflate (RFC 7692): the `Sec-WebSocket-Extensions` negotiation and the per-message codec (docs/ws-extensions.md) |

(and extend the `http/ws` row: "permessage-deflate, WebSocket over HTTP/2 (RFC 8441)").

## (c) Tests that use threads (TSan list)

- tests/ws_deflate_test.ei (server + client threads over loopback)
- tests/ws_h2_test.ei (h2 connection tasks, three concurrent WebSocket tasks)

Interop script (not in scripts/test.sh; the lead should add it next to the hpack/h2 interop stanzas):

    B=$(mktemp -d)
    if ei build tests/ws_interop_server.ei -o "$B/wssrv" > "$B/log" 2>&1; then
      sh tests/ws_deflate_interop.sh "$B" || fail=1
    else
      echo "FAIL ws deflate interop: build"; cat "$B/log"; fail=1
    fi
    rm -rf "$B"

(`tests/ws_deflate_interop.sh` skips without python3; it uses python's zlib as an independent DEFLATE.)

## (d) Not done / caveats

- eider-compression's `Deflater` has no window-size parameter (always 32 KiB): an offer needing
  `server_max_window_bits` < 15 is declined (not an error: the server just does not echo that offer), the client
  never offers `client_max_window_bits`, and a server answer carrying `client_max_window_bits` is a handshake
  error. Nothing else was missing: raw DEFLATE, sync flush (`Deflater.flush`), chunked `Inflater` with an output
  cap (`Limits.max_output`, set per message), `reset` and `set_dictionary` were all there. The sibling was not edited.
  A `window_bits` parameter on `deflater` would remove the limitation.
- Without context takeover a new `Deflater` (about 130 KB of tables) is built per message (no `Deflater.reset`).
- No Autobahn run (not available offline); Python `websockets`, Go gorilla/coder not available; curl cannot do WS.
  Interop is by python3 stdlib + zlib for the DEFLATE side only, over HTTP/1.1. WebSocket over h2 was tested only
  Eider to Eider (client against server through a socket pair, plus hand-made HEADERS for refusals), not against a
  browser or another h2 stack.
- Messages are sent as one frame each (no automatic fragmentation on send).
- `ws.Client.send_text`/`send_binary` now take `inout self` (to keep the deflater's window); callers need a `let mut` client
  (existing tests already do). `ws.Client` gained fields (`h2s`, `tx`, `rx`, `extensions`, `max_message`) and
  `drop_connection` now `uses io, clock`. `ws.Frame` gained `rsv1`; `ws.Options` gained 4 fields (use `ws.options()`);
  `ws.Decoder` gained `rsv1_ok`; `h2.Options` gained `connect_protocol` (use `h2.options()`).
- h2.ei edits (all additive): `Options.connect_protocol`, `Core.peer_connect`, SETTINGS 0x8 sent/recorded,
  `check_fields` allows extended CONNECT and refuses `:protocol` elsewhere, `process_block` refuses `:protocol` when
  not advertised, `Conn.open` refuses `:protocol` until the peer advertised, `Conn.wait_connect_protocol`,
  `handler`/`send_response` for the extended CONNECT (a raw `http.Stream` with status 200 runs on the stream).
  server.ei was not touched (`server.Config.h2` takes the same `h2.Options`).
- ws.ei imports `http.h2` (as `h2x`: the SHA-1 code has a local named `h2`), so programs importing http.ws now load h2.
