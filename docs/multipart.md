# multipart/form-data (`http/multipart`)

`import http.multipart` parses `multipart/form-data` request bodies (RFC 7578 on RFC 2046) as a
stream, the way axum's `Multipart` does, and builds them for clients and tests. It is one module
(`multipart.ei`); nothing in it reads a socket by itself, so it works the same on a streamed
request body, a buffered one, a file or a test's list of chunks.

## Quick start

A route that wants a form (text fields and small files, big files spilled to disk):

```
let mut cfg = multipart.config()
cfg.spill_dir = sys.lit("/var/tmp/uploads")          // empty: files over max_memory are refused

r.route_with("POST", "/upload", http.Plan(0, true), |q: http.Request| -> http.Response {
    match multipart.parse_request(q, cfg) {
        Ok(form) => {
            let title = form.text("title").unwrap_or(sys.lit(""))
            // form.get("file") -> Field { part, data, path, size }
            ...
        }
        Err(e) => e.response()            // problem+json: 400, 413 or 415
    }
})
```

`http.Plan(0, true)` makes the server hand the handler the body as a stream (`Request.stream`);
`parse_request` uses it, or the buffered `Request.body` on a route that does not stream. Use
`Plan.max_body` to cap the whole upload before it is read (a body over it ends the read with
`TotalTooLarge`, 413). `Collected.cleanup()` deletes spilled files; a failed `collect` deletes
its own.

## Streaming a part at a time

Nothing is buffered but the chunk being parsed:

```
let mut f = multipart.from_request(q, multipart.limits())?     // 415 / 400 on a bad Content-Type
let mut body = q.stream.unwrap()
while true {
    match f.next_part(inout body)? {
        Some(part) => {
            // part.name, part.filename, part.content_type, part.headers
            while true {
                let chunk = f.read(inout body, 65536)?          // empty: the part is over
                if chunk.len() == 0 { break }
                ...                                              // write it to disk, hash it, ...
            }
        }
        None => break
    }
}
```

`next_part` skips what is left of the current part, so a handler may stop reading a part
early. `Form` works over any `stream.Reader` (`http.Body`, `stream.reader(bytes)`, ...).
Below it, `Parser` (`feed(bytes)`, `finish()`, `next() -> Event`) is the pure state machine;
the parse does not depend on how the input is split into `feed`s (tests/multipart_test.ei
checks this with random and exhaustive splits, boundaries cut anywhere included).

## What is accepted

- The boundary comes from `Content-Type` (`boundary_of`): token or quoted string, 1 to 70
  characters from RFC 2046's set, not ending in a space. Another media type is `NotMultipart`
  (415); a missing, empty, too long or ill-formed boundary is `BadBoundary` (400).
- A delimiter is CRLF `--boundary` followed by optional blanks and CRLF, or by `--`. The same
  characters followed by anything else are content, so a part may contain a line that merely
  starts with the boundary text. The preamble and epilogue are skipped. The first delimiter
  needs no CRLF before it. Only CRLF line ends are accepted.
- A body that ends before the closing delimiter is `Truncated` (400).
- Part headers: `name: value` lines (token names, no folding, no NUL or bare CR/LF in values).
  Exactly one `Content-Disposition: form-data` with a `name` is required. `filename*`
  (RFC 5987/2231, `UTF-8''...` or `ISO-8859-1''...`) wins over `filename`; a `filename*` that
  does not decode is ignored. Parameters may be quoted (`\"` and `\\` are the escapes) and may
  contain `;`. Names and filenames are otherwise given as sent: a `%22` (what curl and browsers
  write for a quote) stays `%22`.
- `Part.content_type` is the header as sent, `text/plain` for a field and
  `application/octet-stream` for a file without one. All headers are in `Part.headers`
  (`part.header("x-foo")`).

## Limits and errors

`Limits` (`multipart.limits()`: 100 parts, 8 KiB of headers per part, 10 MiB per part, 32 MiB in
all, 100 non-file fields): `max_parts`, `max_header_bytes`, `max_part_bytes`, `max_total_bytes`
(the input up to the closing delimiter, preamble included), `max_fields`. `Config` adds
`max_field_bytes` (64 KiB, text fields in `collect`) and `max_memory` (1 MiB, then spill).
A limit of 0 means none, except `max_parts` and `max_fields`, where it refuses every part.

| `Kind` | status |
|---|---|
| `NotMultipart` | 415 |
| `TooManyParts`, `TooManyFields`, `HeaderTooLarge`, `PartTooLarge`, `TotalTooLarge` | 413 |
| `BadBoundary`, `Malformed`, `Truncated`, `Io`, `Unsafe` | 400 |

`Error.status()`, `Error.problem()` (an `http/problem` `ApiError`) and `Error.response()`
(`application/problem+json`) turn one into the answer.

## Filenames and header injection

`safe_filename(raw)` returns the part after the last `/` or `\`, and `None` for a name with NUL
or any control character (a CR or LF would split a header you copy it into), an empty name, `.`,
`..` or over 255 bytes. `Part.safe_name()` applies it to the part's filename. It does not choose
a name for you: store uploads under a name you generate and keep the client's only as data.
`header_safe(v)` says whether a value can be written into a header. The spill files of
`collect` get a random name in `spill_dir` (mode 0600) and never use the client's.

## Writing a body

```
let mut b = multipart.builder()                          // boundary "----eider" + 32 random hex digits
b.field(sys.lit("title"), sys.lit("hello"))?
b.file(sys.lit("up"), sys.lit("a.txt"), sys.lit("text/plain"), data)?
let body = b.finish()
let content_type = b.content_type()                      // multipart/form-data; boundary=...
```

`part(headers, data)` writes a part with headers of your own. The builder refuses (`Unsafe`) a
NUL in a name, a CR or LF in a header value, a header name that is not a token, and content that
contains the boundary (it cannot happen with the random one). `builder_with(boundary)` takes a
fixed boundary. Names are written the way browsers do (RFC 7578 5.1.1): UTF-8 as it is,
`"` and `\` escaped with a backslash, CR and LF as `%0D` and `%0A`; `filename*` is never written
(RFC 7578 4.2 forbids it in form-data).

## Interoperability

`tests/multipart_interop.sh` runs an Eider server (tests/multipart_interop_server.ei, streaming)
against `curl -F` (fields, typed and renamed files, stdin, a 300 KB binary file, UTF-8
filenames, a body that is not multipart, a cut body) and against Python's standard library
(`email.mime` builds bodies, with quoted boundaries and RFC 2231 filenames, that Eider parses;
`email.parser` parses a body the Eider builder wrote). Each part `skip`s when the tool is missing.
`scripts/test.sh` runs it.
