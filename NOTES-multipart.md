# NOTES: multipart (issue #16)

## (a) CHANGELOG bullet
- `http/multipart` (multipart.ei): `multipart/form-data` request bodies (RFC 7578/2046) as a stream. A pure
  incremental `Parser` (same result for any chunking), a `Form` over a `stream.Reader` (a streamed
  `Request.stream`: `next_part`, `read` in chunks, nothing buffered), and `collect`/`parse_request` (text in
  memory, files in memory up to `max_memory`, then a 0600 temp file under `spill_dir`). Boundary handling
  (quoted, 70 chars, split across reads, boundary-like content, preamble/epilogue), `filename*` (RFC 5987/2231),
  limits (parts, header bytes, part bytes, total bytes, fields) with typed errors mapped to 400/413/415
  problem+json, `safe_filename`/`header_safe`, and a `Builder` writer with a random boundary. Interop tests
  against `curl -F` and Python's email/http stdlib. docs/multipart.md.

## (b) README module-table rows
| `http/multipart` | `multipart/form-data` parser: streaming parts with limits, 400/413/415 problem+json, filename sanitising, and a body builder | docs/multipart.md |

## (c) Test files that use threads (TSan list)
- tests/multipart_test.ei (loopback server part)

## (d) Not done / notes
- `scripts/test.sh`: I added an interop block (tests/multipart_interop.sh, after the h2 one) and did NOT touch the TSAN list.
- The server's body limit applies underneath (`http.Plan.max_body`): its 413 reaches the form as `InvalidData` "body too large", mapped to `TotalTooLarge`.
- `%22` in quoted names/filenames (what curl and browsers write for `"`) is not decoded; documented. The writer escapes with a backslash and never writes `filename*` (RFC 7578 4.2).
- Python's `email.get_filename` prefers `filename` over `filename*` when both are present, which is why the writer does not emit both.
- Only CRLF line ends are accepted in multipart bodies and part headers.
- A header-limit failure is `HeaderTooLarge` (413), not 431, to keep to 400/413/415.
- The TSan build of tests/multipart_test.ei was not run: this machine's TSan probe skipped (glibc), as for the other tests.
