# NOTES: typed extractors (issue #13)

## (a) CHANGELOG bullet
- `http/extract`: typed extractors `json[T]`, `query[T]`, `form[T]`, `path[T]` (and `json_with`, `form_with`, `read_body`, `json_bytes`) that read a request into a `@[derive(Deserialize)]` type through std/serial and eider-json, with a typed `Rejection` that becomes problem+json: 400 malformed, 415 wrong Content-Type, 413 over the limit (streamed bodies are cut off at the limit), 422 invalid with every `@[check]` violation and its field place (JSON pointer for bodies, name for query and path). Queries and forms handle repeated keys (`List` fields), `Option`, percent-decoding and numbers and bools from text. `respond_json[T]` writes a value as a JSON response. docs/extract.md.

## (b) README module-table rows
| `http/extract` | Typed extractors: `json`, `query`, `form`, `path` into `@[derive(Deserialize)]` types, `Rejection` to problem+json (400/413/415/422), `respond_json` | docs/extract.md |

## (c) Tests using threads (TSan list)
None: tests/extract_test.ei is single-threaded (it uses a `sync.lock` only to drive a fake body stream).

## (d) Not done / caveats
- No real-socket test of a streamed body: the stream path is tested with a hand-made `http.Body` pull function (pieces, over the limit, truncated), and the router paths through `http/testing`. A real server with `http.Plan(max, true)` was not exercised by this test.
- Methods like `req.json[T]()` are not possible (a module cannot add methods to `http.Request`), so the functions are `extract.json[T](req)`.
- `multipart/form-data` is not supported (415). Nested keys (`a[b]=1`) in query/form are not read.
- Only the first type error of a record is reported (std/serial's derive returns at the first); `@[check]` violations are all reported.
- No interop check (curl/python) added: the extractors are pure functions of a Request; the Eider-only tests cover them.
