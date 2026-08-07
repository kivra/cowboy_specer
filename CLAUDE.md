# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What this library does

`cowboy_specer` generates an OpenAPI 3.1 document from Cowboy handler modules by
reading their compiled abstract code. Read `README.md` first — it is the design
document as well as the user documentation, and everything below assumes it.

The one-line summary of the design: **the shape is inferred from the code, the
prose and the body types are written by hand.** A wrong guess in published API
documentation is worse than a gap, so nothing is invented. When adding an
inference, that is the line to hold.

## Build & test

Toolchain pinned in `.tool-versions` (Erlang 29.0.2, rebar 3.27.0); CI uses
29.0.3. `warnings_as_errors` is on, so any compiler warning fails the build.

- `make compile`
- `make test` — `xref`, `eunit`, `ct`, `dialyzer`, which is what CI runs
- `make repl` — `rebar3 as test shell`, with the fixtures on the path

Run one eunit test or one CT case:

```
rebar3 eunit --module=cbs_tests
rebar3 ct --suite test/cbs_SUITE --case serves_openapi_json
```

## Architecture

Four modules, no processes, no application callback — it is a pure function from
a route list to a JSON document.

- `cbs_spec` — the entire public API. Everything else is internal.
- `cbs_scan` — reads one handler module's abstract code into a `resource()`: its
  kind (`rest` | `plain`), methods, content types, and a per-method `operation()`
  carrying parameters, replies, implied statuses and whether a token is needed.
- `cbs_openapi` — turns `resource()`s into `spectra_openapi` endpoint specs and
  calls `spectra_openapi:endpoints_to_openapi/2`. Owns where prose and body
  *types* come from, which `cbs_scan` deliberately says nothing about.
- `cbs_docs_h` — a Cowboy handler serving the document and the two UI pages. The
  HTML is inlined rather than in `priv/`, so the library has no `priv_dir`
  dependency and stays a file move away from anywhere else.

### The two rules that keep `cbs_scan` honest

1. **It never executes anything.** `literal/1` folds constants and nothing else;
   a form containing a variable or a call is simply not a literal. Arithmetic is
   matched operator by operator rather than applied by name, so no atom from the
   source can reach `apply/3`.
2. **Facts belong to a method, not a module.** Per method it computes which
   callbacks `cowboy_rest` can reach, closes over local calls, and collects only
   what is in that set. Breaking this is how a `POST` handler's query parameters
   end up documented under `OPTIONS`.

### Two-pass fact extraction

Facts are gathered per *clause*, so a variable in a body can be traced to the
argument it came from. A `cowboy_req:reply/4` whose status is argument N becomes
a pending `{reply_arg, FA, N, Partial}` fact, resolved in a second pass against
every literal passed at that position module-wide. This is the only reason a
handler that replies through a local `reply(Status, ...)` wrapper documents
anything at all.

## Conventions & gotchas

- Erlang 28+ syntax throughout: `maybe`/`?=` and `~"binary"` sigils. Match the
  surrounding style.
- xref runs `locals_not_used`, so an unused local function fails the build.
- `spectra` must be >= 0.13.2 — that is the release that added the
  `security_schemes` / `security` metadata keys, which are silently dropped by
  anything older.
- Per-operation `security` is still not expressible in spectra's endpoint spec.
  An operation needing a token says so in its description instead; document-level
  `security` is only set when *every* operation needs one. If spectra grows the
  key, `cbs_openapi:with_security/3` and `with_auth_note/2` are what change.
- The test fixtures in `test/` are the specification of the analysis. Each one
  exists for a shape: `cbs_person_h` (annotated `cowboy_rest`, custom constraint
  fun, auth header), `cbs_widget_h` (three methods, path binding, `{created,_}`),
  `cbs_bare_h` (no annotations, `OPTIONS`+`POST`), `cbs_open_h` (an
  `is_authorized/2` that always says yes), `cbs_probe_h` (trivial plain handler),
  `cbs_job_h` (plain, method dispatch through a reply wrapper), `cbs_hidden_h`
  (opts out). Adding an inference means adding or extending a fixture, not
  asserting against a handler in some other repo.
- `cbs_span` and `cbs_secret` are separate modules on purpose: the scanner does
  not cross module boundaries, and both fixtures depend on it not doing so.
