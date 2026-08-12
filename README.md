# cowboy_specer

Generate an OpenAPI 3.1 document from [Cowboy](https://github.com/ninenines/cowboy)
handler modules.

Point it at a Cowboy route list. It reads each handler's compiled abstract code,
works out the shape of the resource, and produces the document. There is no code
generation step, no DSL to port your handlers to, and no `Req` faked at runtime —
your handlers stay exactly as they are.

Built on [spectra](https://hex.pm/packages/spectra), which does the JSON Schema
generation and the OpenAPI assembly.

```erlang
Routes = [ {"/livez", my_liveness_h, #{}}
         , {"/widgets/:id", my_widget_h, #{}}
         ],
{ok, Json} = cowboy_specer:openapi(#{title => ~"My API", version => ~"2.0.0"}, Routes).
```

## Contents

- [Install](#install)
- [Examples](#examples)
- [Serving the document](#serving-the-document)
- [What is inferred](#what-is-inferred)
- [What you write](#what-you-write)
- [API reference](#api-reference)
- [Options](#options)
- [Known limits](#known-limits)
- [How it is put together](#how-it-is-put-together)
- [Build and test](#build-and-test)
- [Licence](#licence)

## Install

```erlang
{deps, [ {cowboy_specer, {git, "git@github.com:kivra/cowboy_specer.git",
                          {branch, "master"}}}
       ]}.
```

Your handler modules must be compiled with `debug_info` — the default for
`rebar3`, but check that you have not turned it off in a production profile.

## Examples

[`examples/`](examples/) is a small pet-store API — ordinary Cowboy handlers with
`cowboy_specer` bolted on in one place. Run it and browse the result:

```sh
rebar3 as examples shell
1> ex_server:start().
Serving http://localhost:8080/swagger
```

`ex_pets_h` is the fully annotated resource, `ex_minimal_h` is the same idea with
no annotations at all so you can see what comes for free, and `ex_reindex_h` is a
plain `cowboy_handler` whose statuses are only visible through a local reply
wrapper. See [examples/README.md](examples/README.md).

## Serving the document

`routes/2,3` gives you back your route list with `/openapi.json`, `/swagger` and
`/redoc` appended, ready for `cowboy_router:compile/1`:

```erlang
start() ->
    MetaData = #{title => ~"My API", version => ~"2.0.0"},
    Routes = cowboy_specer:routes(MetaData, my_app:routes()),
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    cowboy:start_clear(http, [{port, 8080}], #{env => #{dispatch => Dispatch}}).
```

The document is built once, at that call, and served from a binary — a request
does no analysis. Building it at startup is deliberate: a handler the analysis
cannot make sense of fails the boot rather than the docs.

| Path | Serves |
|------|--------|
| `/openapi.json` | the document |
| `/swagger` | Swagger UI, loaded from a CDN, pointed at the document |
| `/redoc` | Redoc, same |

Move or drop any of them with the `json_path`, `swagger_path` and `redoc_path`
options. Both UI pages fetch the document from a CDN-hosted bundle, so they need
outbound network access from the *browser*, not from your node.

Or skip the endpoints entirely and write the document to a file at build time:

```erlang
{ok, Json} = cowboy_specer:openapi(MetaData, my_app:routes()),
ok = file:write_file("openapi.json", json:format(json:decode(iolist_to_binary(Json)))).
```

That is usually the better answer for a service whose docs should not be public.

## What is inferred

Nothing here is a convention you have to adopt. It is the code you already
wrote.

| Fact | Read from |
|------|-----------|
| Methods | the literal list `allowed_methods/2` returns (Cowboy's default if absent) |
| Response content types | `content_types_provided/2` |
| Request content types | `content_types_accepted/2` |
| Status codes | `cowboy_req:reply/2,3,4` with a literal status |
| Response descriptions | the literal body of those replies |
| Success status | the accept callback's return: `true` → 204, `{created, _}` → 201, `{see_other, _}` → 303 |
| Query parameters | `cowboy_req:match_qs/2`, including required/optional and defaults |
| Cookie parameters | `cowboy_req:match_cookies/2` |
| Path parameters | the `{name}` variables in the route's path template |
| Header parameters | `cowboy_req:header/2,3`, minus the ones `cowboy_rest` negotiates itself |
| Parameter types | Cowboy constraints: `int`, `nonempty`, and custom constraint funs |
| Bearer auth | reading the `authorization` header, an `is_authorized/2` that can answer anything but `true`, or a 401 among the statuses |
| Request body present | `cowboy_req:read_body/1,2` |
| 406 / 415 | content negotiation for the method, given what the resource provides and accepts |
| Methods (plain handler) | the literals a `cowboy_req:method/1` test compares against |

### Constraint funs

Cowboy's custom constraints are read, not just its built-in ones. Given

```erlang
verified_constraint(forward, ~"true")  -> {ok, true};
verified_constraint(forward, ~"false") -> {ok, false};
verified_constraint(forward, _)        -> {error, not_boolean};
```

the parameter's schema is `boolean`, because those are the only values the
`forward` direction can produce. A constraint fun whose `forward` clauses return
some other fixed set of atoms or integers becomes an enum of them.

### Per-method attribution

Facts belong to a *method*, not to a module. For each method the callbacks
`cowboy_rest` can reach for that method are computed — the generic callbacks plus
that method's provide or accept callback — closed over local calls, and only the
facts in that set are collected. A resource serving `OPTIONS` and `POST` does not
report the `POST` handler's query parameters under `OPTIONS`.

### Through a local reply wrapper

Handlers rarely call `cowboy_req:reply/4` with a literal status — they funnel
through a helper. So when the status is one of the enclosing function's
arguments, its call sites are read instead:

```erlang
init(Req, State) -> ... reply(202, accepted, Req, State) ...
refuse(unauthorized, Req, State) -> reply(401, unauthorized, Req, State).

reply(Status, Outcome, Req, State) ->
    {ok, cowboy_req:reply(Status, headers(Status), body(Outcome), Req), State}.
```

`Status` is `reply/4`'s first argument, so the statuses are whatever is passed
there anywhere in the module: 202 and 401. The headers get one level of the same
treatment — a non-literal headers argument resolves to the first literal among
the helper's return expressions, which is enough to recover the content type. The
reply *body* is deliberately not resolved that way: it becomes a response
description, and a wrong description is worse than none.

### Spans and other wrappers

A tail call taking an anonymous function also yields that function's return
expressions, so the common tracing wrapper does not hide what a callback
returns:

```erlang
from_json(Req, State) ->
    otel:with_span(~"store", fun(_) -> do_store(Req, State) end).
```

### Plain `cowboy_handler` modules

A plain handler has no `allowed_methods/2` and no content negotiation, so there
is less to read: everything comes from what `init/2` reaches. Methods come from
the literals it tests `cowboy_req:method/1` against, or `GET` if it never
looks — which is the right answer for the liveness and readiness probes this
mostly describes. Nothing is *implied*, either: no `cowboy_rest` state machine is
deriving a status from a callback's return, so only the replies the handler makes
itself are documented, and there is no 406 or 415.

Its facts cannot be split by method — there is one entry point and no way to tell
one method's code from another's. The one place that would mislead is handled: a
handler that tests the method replies 405 on the branch for the methods it does
*not* serve, so 405 is dropped from the ones it does.

## What you write

The prose, and any body type. These are not guessed, because a wrong guess in
published API documentation is worse than a gap.

### A `-spectra(...)` attribute on the provide callback

The operation's summary and description come from a `-spectra(...)` attribute in
front of the callback's `-spec`:

```erlang
-spectra(#{ summary => ~"Look up a person by SSN"
          , description => ~"Answers from the cache when it can."
          }).
-spec to_xml(cowboy_req:req(), State) ->
          {person_xml(), cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.
```

### The 200's schema

A `cowboy_rest` provide callback returns the **encoded** body, so what its
`-spec` can honestly say depends on the format.

**When the body is the type** — XML, plain text, anything already a binary by the
time the callback hands it over — name the type in the spec and it becomes the
200's schema:

```erlang
-spectra(#{ title => ~"Person"
          , description => ~"One person record, serialised as XML."
          }).
-type person_xml() :: binary().
```

The `cowboy_rest` control atoms — `stop`, `true`, `{created, _}` and friends —
are skipped, so only the real body type is left. A named type goes into
`components/schemas` under its own name and keeps its own documentation, so
naming it is worth it.

**When the body is encoded** — JSON, or anything else with structure — the
callback returns `iodata()` and there is no structured type in the spec to read.
Declare the schema instead, and let the same type do both jobs:

```erlang
-openapi(#{get => #{responses => #{200 => #{schema => {type, pets, 0}}}}}).

to_json(Req, State) ->
    {ok, Json} = spectra:encode(json, ?MODULE, {type, pets, 0}, list_pets()),
    {Json, Req, State}.
```

Encoding through the type that generates the schema is the point: the wire format
and the documentation cannot drift apart. `examples/ex_pets_h.erl` does exactly
this.

Only 200 gets this schema. `cowboy_rest` sends no body with the statuses it
derives from a write callback's return — 201 after `{created, URI}`, 303 after
`{see_other, URI}`, 204 after `true` — so none of those claim one. The callback
consulted is always the one from `content_types_provided/2`, whatever the request
method was.

### An `-openapi(...)` module attribute

For everything the code cannot say. Keyed by method, with resource-wide defaults
at the top level. Every key is optional, and several attributes in one module are
merged.

```erlang
-openapi(#{ tags => [~"person"]
          , get =>
                #{ summary => ~"..."
                 , description => ~"..."
                 , operationId => ~"getPerson"
                 , deprecated => false
                 , parameters =>
                       #{~"ssn" => #{ description => ~"A Swedish SSN."
                                    , schema => {type, ssn, 0}
                                    , required => true
                                    }}
                 , request_body =>
                       #{ schema => {type, create_request, 0}
                        , content_type => ~"application/json"
                        }
                 , responses =>
                       #{ 200 => #{description => ~"The person."}
                        , 502 => #{ description => ~"Upstream is unhappy."
                                  , schema => {type, error_body, 0}
                                  }
                        }
                 }
          }).
```

| Key | Where | Meaning |
|-----|-------|---------|
| `hidden` | top level | leave this handler out of the document entirely |
| `tags`, `summary`, `description` | top level | defaults for every method |
| `get`, `post`, `put`, `patch`, `delete`, `head`, `options` | top level | per-method overrides |
| `summary`, `description`, `operationId`, `tags`, `deprecated`, `externalDocs` | per method | straight into the operation |
| `parameters` | per method | `#{ParameterName => #{description, schema, required}}` |
| `request_body` | per method | `#{schema, content_type}` |
| `responses` | per method | `#{StatusCode => #{description, schema, content_type}}` |

A `schema` is anything `spectra_openapi` accepts: `{type, Name, Arity}`,
`{record, Name}`, or an inline spectra type.

Request bodies always need declaring — `cowboy_rest` hands the accept callback a
`Req`, not a decoded body, so there is no type to read. Without a declaration, a
handler that calls `read_body/1` gets an opaque `string` body of the accepted
content type, which is at least honest.

### Two Erlang details

Erlang rejects a wild attribute after the first function definition, so
`-spectra(...)` and the `-spec` it documents both have to sit above the function
definitions rather than next to the function.

A type that is only ever named from `-openapi(...)` needs `-export_type` to count
as used — which it is: it is part of the resource's interface.

## API reference

All of it is in `cowboy_specer`.

### `cowboy_specer:openapi(MetaData, Routes)` / `openapi(MetaData, Routes, Options)`

```erlang
-spec openapi(spectra_openapi:openapi_metadata(), [route()], options()) ->
          {ok, iodata()} | {error, [spectra:error()]}.
```

The document, as JSON. `MetaData` goes to
`spectra_openapi:endpoints_to_openapi/2` and must carry at least `title` and
`version`; `description`, `servers`, `contact`, `license`, `security_schemes` and
`security` are passed through.

A `route()` is a path-level Cowboy route — `{Path, Handler}`,
`{Path, Handler, InitialState}` or `{Path, Constraints, Handler, InitialState}`.
Binding constraints are not read — a path parameter is typed from the handler
module only — but the form is accepted so an existing route list passes through
unchanged. Paths may be Cowboy's `"/widgets/:id"` or OpenAPI's
`"/widgets/{id}"`; both work.

### `cowboy_specer:routes(MetaData, Routes)` / `routes(MetaData, Routes, Options)`

```erlang
-spec routes(spectra_openapi:openapi_metadata(), [route()], options()) -> [route()].
```

`Routes` with the documentation endpoints appended. Raises
`{openapi_generation_failed, Errors}` rather than starting a listener that would
serve a broken document.

### `cowboy_specer:resources(Routes)` / `resources(Routes, Options)`

```erlang
-spec resources([route()], options()) -> [cowboy_specer_scan:resource()].
```

The analysis, before it becomes a document. This is the thing to look at when an
endpoint comes out wrong:

```erlang
1> [R] = cowboy_specer:resources([{"/widgets/:id", my_widget_h, #{}}]).
2> maps:get(operations, R).
#{~"GET" => #{method => ~"GET", callback => to_json, auth => false,
              parameters => [...], replies => #{400 => ...}, implied => [200],
              request_body => false}}
```

### `cowboy_specer:openapi_path(Path)`

```erlang
-spec openapi_path(iodata()) -> binary().
```

`"/widgets/:id"` → `<<"/widgets/{id}">>`. A trailing `[...]` is dropped and a
path that already uses `{id}` is returned unchanged.

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `json_path` | `"/openapi.json"` | where the document is served; `undefined` to leave it out |
| `swagger_path` | `"/swagger"` | where Swagger UI is served; `undefined` to leave it out |
| `redoc_path` | `"/redoc"` | where Redoc is served; `undefined` to leave it out |
| `implicit_responses` | `true` | also document the 406/415 `cowboy_rest` produces during content negotiation |
| `plain_handlers` | `true` | document plain `cowboy_handler` modules, not only `cowboy_rest` ones |
| `security_scheme_name` | `<<"bearerAuth">>` | name of the generated bearer security scheme |

## Known limits

Only what is literal *in the handler module* is seen:

- a `match_qs/2` list built at runtime is invisible;
- a method test written as `M = cowboy_req:method(Req), case M of ...` is
  invisible; only the direct `case cowboy_req:method(Req) of` and `=:=` forms are
  read;
- an `authorization` header read inside a helper module is invisible — though a
  401 in the reply set catches the common case;
- per-operation `security` is not expressible in spectra's endpoint spec, so an
  operation that needs a token says so in its description. The scheme is emitted
  into `components`, and document-level `security` only when *every* operation
  needs it.

`-openapi(...)` is the escape hatch for all of these.

Two smaller ones: OpenAPI puts a query parameter's default in its schema, but
spectra's JSON Schema generator has no `default`, so it goes into the description
instead. And one status maps to one content type, so a resource providing several
representations documents the first.

Generation raises rather than returning a half-built document. A type spectra
cannot turn into a schema raises `{type_not_supported, _}` naming the type; a
module compiled without `debug_info` raises
`{module_not_compiled_with_debug_info, _, _}`; `routes/2,3` raises
`{openapi_generation_failed, _}`. Better at boot than in the published docs.

## How it is put together

| Module | Does |
|--------|------|
| `cowboy_specer` | the API; everything else is internal |
| `cowboy_specer_scan` | abstract-code analysis of one handler into a `resource()` |
| `cowboy_specer_openapi` | `resource()` list into an OpenAPI document, via `spectra_openapi` |
| `cowboy_specer_docs_h` | serves `/openapi.json`, `/swagger`, `/redoc` |

`cowboy_specer_scan` never executes anything from the module it reads: constant folding
only folds constants, and a form containing a variable or a call is simply not a
literal.

### Why this and not a framework

[`cowboy_spectra`](https://github.com/kivra/cowboy_spectra) takes the other
route: define handlers against its own behaviour, with the whole interface in one
`-spec` per method, and it validates requests as well as documenting them. That
is the better answer for a new service.

This one is for the services you already have. A `cowboy_rest` handler's
interface is not in its specs — it is spread across `allowed_methods/2`,
`content_types_provided/2`, the `cowboy_req:match_qs/2` call three functions
down, and a dozen `cowboy_req:reply/4` calls. So that is what gets read.

## Build and test

```sh
make compile
make test      # xref, eunit, ct, dialyzer
```

`examples/` is compiled under the `test` and `examples` profiles only, so the
examples are verified by CI without shipping in the library's `ebin`.

`test/` holds a handler fixture per shape the analysis has to cope with — an
annotated `cowboy_rest` resource, an unannotated one, a three-method JSON
resource, an open resource declaring `is_authorized/2`, a liveness probe, and a
plain handler that dispatches on method through a reply wrapper. `cowboy_specer_SUITE`
starts a real Cowboy listener and fetches the documentation endpoints over HTTP.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
