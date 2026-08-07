# Examples

A small pet-store API, written as ordinary Cowboy handlers, with
`cowboy_specer` bolted on in one place. Nothing in the handlers knows the
generator exists beyond the `-openapi(...)` and `-spectra(...)` annotations,
which are just module attributes.

## Run it

```sh
rebar3 as examples shell
1> ex_server:start().
Serving http://localhost:8080/swagger
```

Then browse `/swagger`, `/redoc` or `/openapi.json`. Or skip the server and
write the document to a file — usually the better answer for a service whose
docs should not be public:

```erlang
1> ex_server:write_document("openapi.json").
```

`examples/` is compiled only under the `examples` and `test` profiles, so it
never ships in the library's `ebin`. `test/cowboy_specer_examples_tests.erl` asserts what
the example API generates, so an example that stops matching its own comments
fails CI.

## What each one is for

| Module | Route | Shows |
|--------|-------|-------|
| `ex_server` | — | the whole of the wiring: a plain route list, `cowboy_specer:routes/2`, `cowboy:start_clear/3` |
| `ex_pets_h` | `/pets` | the fully annotated resource — a record as a response schema, a map type as a request body, an `int` query constraint with a default, `{created, URI}` → 201 |
| `ex_pet_h` | `/pets/{petId}` | a path parameter, a remote type (`ex_pets_h:pet()`) resolving to a shared component, bearer auth recognised from the `authorization` header |
| `ex_minimal_h` | `/minimal` | **no annotations at all** — the contrast that shows how much comes for free |
| `ex_health_h` | `/healthz` | the simplest plain `cowboy_handler`: documented entirely from the one reply it makes |
| `ex_reindex_h` | `/admin/reindex` | the interesting plain handler — method dispatch, statuses traced through a local `reply/4` wrapper, content type from a `headers/1` helper, auth inferred from a 401 |
| `ex_store` | — | a stand-in backend, deliberately a *separate* module: the analysis does not cross module boundaries, which is exactly why `ex_reindex_h` is recognised as authenticated only by its 401 |

## The three things worth noticing

**`ex_minimal_h` costs nothing and still documents.** Its method, its required
`q` parameter, its `text/plain` content type, its 200, its 400 (described by
the literal body it replies) and its 406 are all read off the code. Only the
summary and the response schema are missing, and those are exactly the two
things that cannot be guessed.

**`ex_pet_h`'s `DELETE` declares `petId` without ever reading it.** Path
parameters come from the route's path template, not from `cowboy_req:binding/2`
calls — OpenAPI requires every template variable to be declared on every
operation under it, whether or not that method cares.

**`ex_reindex_h` has nothing literal at its `cowboy_req:reply/4` call site.**
`Status` there is `reply/4`'s first argument, so the documented statuses come
from what is passed at that position anywhere in the module: 202, 409, 401 —
and 405, which is then dropped again, because it answers the methods the
handler does *not* serve.

See the [top-level README](../README.md) for the full rules.
