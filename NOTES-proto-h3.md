# NOTES: HTTP/3 (issue #20), branch feat/proto-h3

## (a) CHANGELOG bullet

- **HTTP/3 building blocks (issue #20): `http/h3frame`, `http/qpack`, `http/h3`.** RFC 9000 varints and RFC 9114 frames
  with an incremental decoder that streams DATA and skips grease frames; QPACK (RFC 9204) with static and dynamic tables,
  encoder and decoder streams and blocked streams (RFC 9204 appendix B reproduced byte for byte, checked against libnghttp3 in
  both directions); and a sans-IO HTTP/3 connection (control stream, SETTINGS, requests, responses, trailers, interim
  responses, GOAWAY, every error code of RFC 9114) that runs over any set of streams, tested Eider to Eider over in-memory
  ones. The QUIC transport itself is not included: it is blocked on header protection primitives in `crypto`, a message-level
  handshake API with `quic_transport_parameters` in eider-tls, and (for quality) UDP ancillary data in `std.net`;
  `docs/h3.md` lists the exact asks.

## (b) README module-table rows

| `http/h3frame` | HTTP/3 frames and varints (RFC 9114, RFC 9000 section 16): an incremental decoder that streams DATA, skips reserved frames and refuses with the RFC's error codes; encoders; SETTINGS (docs/h3.md) |
| `http/qpack` | QPACK (RFC 9204): static and dynamic tables, encoder and decoder streams, blocked streams, limits; checked against libnghttp3 (docs/h3.md) |
| `http/h3` | HTTP/3 over any streams, sans-IO: control stream, SETTINGS, requests, responses, trailers, GOAWAY, errors; no QUIC transport yet (docs/h3.md) |

## (c) Tests that use threads (TSan list)

None: `tests/h3frame_test.ei`, `tests/qpack_test.ei` and `tests/h3_test.ei` are single-threaded and need no capability beyond `io`.

Optional line for `scripts/test.sh` (not added, the lead owns that file): after the hpack interop block,

    # http/qpack against libnghttp3, both directions (tests/qpack_interop.sh; `skip` without libnghttp3)
    B=$(mktemp -d)
    if ei build tests/qpack_interop.ei -o "$B/qpack_interop" > "$B/log" 2>&1; then
      sh tests/qpack_interop.sh "$B" || fail=1
    else
      echo "FAIL qpack interop: build"; cat "$B/log"; fail=1
    fi
    rm -rf "$B"

`tests/qpack_interop.sh` reads the static table dump from `tests/qpack_test.out`, so it must run after the suite's
.out files exist (they are checked in). It needs only `libnghttp3.so.9` (no header, the prototypes are in
`tests/qpack_oracle.c`); it passed here against libnghttp3 1.9.1 (4 table sizes x 5 seeds x 300 sections, both directions).

## (d) What was not done, and why

- **The QUIC transport (RFC 9000, 9001, 9002) is not implemented.** Dependencies, by repository (details in docs/h3.md):
  1. `eider-lang` `packages/crypto`: no raw AES block encryption and no raw ChaCha20 block, which QUIC header protection
     (RFC 9001 section 5.4) needs; `seal`/`open` cannot stand in. Ask: `aes_encrypt_block` and `chacha20_block`.
  2. `eider-tls`: no message-level handshake (client.ei/server.ei are tied to the record layer in `conn.Conn`, no traffic
     secret export per level) and no `quic_transport_parameters` extension 57 (the ClientHello/EncryptedExtensions extension
     set is fixed, and a client rejects unknown EncryptedExtensions). Ask: a `tls.quic` handshake state machine
     (`feed(level, bytes)` / `poll()` / secrets / peer transport params / ALPN). 0-RTT, resumption and tickets are absent from eider-tls
     but not needed for a 1-RTT QUIC.
  3. `eider-lang` `std/net.ei` (quality, not a blocker): UDP works (`send_to`/`recv_from`, non-blocking, pollable) but there is
     no ECN, no packet info (destination address), no DF bit, no `try_recv_from`, no GSO.
- Server push, extended CONNECT / WebTransport / datagrams, 0-RTT, RFC 9218 priorities: not in `http/h3` (listed in the module
  comment). `http/h3` has no `Server`/`Client` integration with `http.Handler` yet: that wants the transport first, and would
  be a thin adapter from `Headers`/`Data`/`Finished` events to `http.Request` and `send_headers`/`send_data` to `http.Response`.
- QPACK encoder: no draining index (RFC 9204 section 2.1.1.1) and an "index everything that is not a credential" policy.
- Interop of the HTTP/3 layer with another implementation is not possible without a transport; only QPACK was checked
  against libnghttp3 (whose HTTP/3 layer would need ngtcp2 and a QUIC transport of our own).
