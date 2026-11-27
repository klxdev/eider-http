# Typed extractors (`http/extract`)

`import http.extract` reads a request into a `@[derive(Deserialize)]` type, the way axum's
`Json<T>`, `Query<T>`, `Form<T>` and `Path<T>` do, and turns what is wrong with it into a
problem+json answer. The decoding is `std/serial` over eider-json's data model, so one type
and its attributes (`rename_all`, `name`, `default`, `skip`, `unknown`, `@[check(...)]`) work
for a JSON body, a query string, a form and path parameters.

```eider,ignore
@[derive(Serialize, Deserialize)]
type NewTodo = { @[check(min_len = 1, max_len = 80)] title: String, done: Option[bool] }

@[derive(Serialize, Deserialize)]
type Listing = { @[check(min = 1, max = 100)] limit: u32, @[serial(default)] tag: List[String] }

@[derive(Serialize, Deserialize)]
type TodoId = { id: u64 }

fn main() uses io, net, clock, threads {
    let mut r = router.new()
    r.post("/todos", |q: http.Request| -> http.Response {
        match extract.json[NewTodo](q) {
            Ok(t) => extract.respond_json(201, t)
            Err(e) => e.response()          // 400, 413, 415 or 422 as problem+json
        }
    })
    r.get("/todos", |q: http.Request| -> http.Response {      // /todos?limit=20&tag=a&tag=b
        match extract.query[Listing](q) { ... }
    })
    r.get("/todos/:id", |q: http.Request| -> http.Response {
        match extract.path[TodoId](q) { ... }
    })
}
```

## The extractors

Each gives `Result[T, extract.Rejection]`.

| Function | Reads | Content-Type |
|---|---|---|
| `json[T](req)`, `json_with[T](req, max)` | the JSON body | `application/json` or `+json` |
| `query[T](req)` | `req.query` | none |
| `form[T](req)`, `form_with[T](req, max)` | the body, urlencoded | `application/x-www-form-urlencoded` |
| `path[T](req)` | `req.params` (`:id`, `*rest`) | none |
| `read_body(req, max)` | the body as bytes, limit-aware | any |
| `json_bytes[T](text)` | a JSON text already in hand | none |
| `respond_json(status, x)` | writes `x` as an `application/json` response | |

The body limit is `extract.DEFAULT_MAX` (1 MiB) unless a `_with` variant says otherwise.
`read_body` takes the body from `Request.body`, or reads `Request.stream` (a route with
`http.Plan(max, true)`) in pieces and stops with 413 as soon as the limit is passed, so a large
body is never held whole. JSON is parsed within eider-json's limits for untrusted input
(8 MiB, depth 64, no repeated keys). `respond_json` answers a 500 problem if the value cannot
be written, never a panic.

## Rejections and statuses

`Rejection` is an enum (`Malformed`, `UnsupportedMedia`, `TooLarge`, `Failed`, `Invalid`).
`.status()`, `.problem()` (an `problem.ApiError`, for `middleware.errors` and typed handlers)
and `.response()` convert it.

| Status | When |
|---|---|
| 400 | not JSON (the position is in `detail`), empty JSON body, a bad percent escape or non-UTF-8 text in the query or form, more than `MAX_KEYS` (1000) keys, a body that cannot be read |
| 408 | the client is too slow sending a streamed body |
| 413 | the body is over the limit |
| 415 | the Content-Type is not the extractor's (also when there is none) |
| 422 | well formed but invalid: missing or unknown field, a wrong type, a number out of range, every `@[check]` violation |

A 422 carries one `errors` entry for each thing wrong. `"in"` is `"body"` (JSON and forms, with a
JSON pointer: `#/lines/1/qty`), `"query"` or `"path"` (with the parameter's `name`):

```json
{"type":"about:blank","title":"Unprocessable Content","status":422,"detail":"the request is not valid",
 "errors":[{"in":"body","pointer":"#/lines/1/qty","detail":"must be at least 1"},
           {"in":"body","pointer":"#/lines/2/qty","detail":"must be at most 99"}]}
```

A missing or unknown field is reported at the field itself (`#/customerName`), not at its
record. All `@[check]` violations of a record are reported together; a type error (wrong kind,
a missing field) stops at the first one, and `@[check]` runs only when the record's fields all
read.

## Query strings, forms and path parameters

Keys are flat (a `?a.b=1` is a field called `a.b`; nested records and maps are not read from
text) and every value is text, read as the field's type:

- integers and floats by their decimal text (range errors are 422: `limit=-1` for a `u32`);
- `true` and `false` for a `bool` (nothing else: a checkbox's `on` is a 422, read it as a
  `String`);
- an RFC 3339 text for a time, the text itself for a `String`;
- percent-decoding with `+` as a space, then UTF-8 validation;
- an empty value (`?q=`) is `None` for an `Option` field, and an empty string for a `String`;
- a repeated key (`?tag=a&tag=b`) is a `List` field's elements; a `List` field also takes a
  single value (`?tag=a`) as a list of one; a repeated key for any other field is a 422;
- an enum without fields is its variant's name (`sort=Desc`, or the `rename_all` form).

As in eider-json, a key no field takes is a 422 (`@[serial(unknown = "ignore")]` on the type
lets them through). `path[T]` is the exception: it ignores route parameters the type has no
field for, so one type can take part of `/orgs/:org/users/:id`. An absent query is an empty one.

`pairs(text)` (the decoded keys with their values) is public for code that wants the raw
grouping.

## With middleware

A handler that returns `Result[http.Response, problem.ApiError]` can use `?`-style code with
`.problem()` and `middleware.errors`:

```eider,ignore
r.post("/todos", middleware.errors(|q: http.Request| -> Result[http.Response, problem.ApiError] {
    match extract.json[NewTodo](q) {
        Ok(t) => Ok(extract.respond_json(201, t))
        Err(e) => Err(e.problem())
    }
}))
```

## Notes

- The text reader decides a single value's shape lazily: a field that turns out to want a list is
  read again as one (at most once per such field), which is invisible except in cost.
- `form` reads only urlencoded forms; `multipart/form-data` is a 415.
- Tests: `tests/extract_test.ei` (every extractor, every rejection, a streamed body, and
  routes driven through `http/testing`).
