-module(cowboy_specer).
-moduledoc """
Generate an OpenAPI 3.1 document from Cowboy handler modules.

This is the whole public API; everything else in `cowboy_specer` is internal.
See the README for the long version.

Point it at a Cowboy route list and it reads each handler's compiled abstract
code, works out the shape of the resource, and produces the document. Both
`cowboy_rest` handlers and plain `cowboy_handler` modules are read, so an
existing route list can be passed in unchanged:

    Routes = [ {"/livez", my_liveness_h, #{}}
             , {"/widgets/:id", my_widget_h, #{}}
             ],
    Meta = #{title => ~"My API", version => ~"2.0.0"},
    {ok, Json} = cowboy_specer:openapi(Meta, Routes).

`routes/2` does the same and hands back a route list with `/openapi.json`,
`/swagger` and `/redoc` appended, ready for `cowboy_router:compile/1`:

    Dispatch = cowboy_router:compile([{'_', cowboy_specer:routes(Meta, Routes)}]),
    {ok, _} = cowboy:start_clear(http, [{port, 8080}], #{env => #{dispatch => Dispatch}}).

The document is built once, when you call this, and served from a binary.

## What is inferred and what you have to write

The *shape* is inferred: methods, query/path/header/cookie parameters and their
types, status codes, content types, and whether a bearer token is needed. See
`cowboy_specer_scan` for exactly which construct each fact is read from.

A plain `cowboy_handler` has less to read -- no `allowed_methods/2` and no
content negotiation -- so it is documented from what `init/2` reaches: the
methods it tests `cowboy_req:method/1` against, and the statuses it replies
with. Exclude one entirely with `-openapi(#{hidden => true})`, or all of them
with the `plain_handlers => false` option.

The *prose*, and any body type, is not guessed. Two things supply it.

### A `-spec` on the provide callback

The type in the body slot of the `cowboy_rest` return tuple is the success
response's schema, and a `-spectra(...)` attribute in front of the spec is the
operation's summary and description:

    -spectra(#{ summary => ~"Look up a person by SSN"
              , description => ~"Served from the cache when possible."
              }).
    -spec to_xml(cowboy_req:req(), State) ->
              {person_xml(), cowboy_req:req(), State}
            | {stop, cowboy_req:req(), State}.

### An `-openapi(...)` module attribute

For everything else, keyed by method, with resource-wide defaults at the top
level. Every key is optional:

    -openapi(#{ tags => [~"person"]
              , get =>
                    #{ summary => ~"..."
                     , description => ~"..."
                     , operationId => ~"getPerson"
                     , deprecated => false
                     , parameters =>
                           #{~"ssn" => #{ description => ~"A Swedish SSN."
                                        , schema => {type, ssn, 0}
                                        }}
                     , request_body =>
                           #{ schema => {type, my_request, 0}
                            , content_type => ~"application/json"
                            }
                     , responses =>
                           #{ 200 => #{description => ~"The person."}
                            , 502 => #{description => ~"SPAR is unhappy."}
                            }
                     }
              }).

A `schema` is anything `spectra_openapi` takes: a `{type, Name, Arity}` or
`{record, Name}` reference into the handler module, or an inline spectra type.
Referenced types get their own `-spectra(#{description => ...})` documentation
and land in `components/schemas`, so they are worth naming.

Multiple `-openapi(...)` attributes in one module are merged.
""".

-export([ openapi/2
        , openapi/3
        , routes/2
        , routes/3
        , resources/1
        , resources/2
        , openapi_path/1
        ]).

%% A path-level Cowboy route: `cowboy_router:route_path()`, which Cowboy does not
%% export. The two-element form is accepted as a convenience when there is no
%% initial state to pass. The four-element form carries binding constraints,
%% which the analysis does not read -- a path parameter is typed from the
%% handler module only -- but the route must still pass through unchanged.
-type route() :: {Path :: iodata(), module()}
               | {Path :: iodata(), module(), InitialState :: any()}
               | {Path :: iodata(), Constraints :: cowboy:fields(), module(),
                  InitialState :: any()}.

-type options() ::
        #{ %% Where the document and the two UIs are served from. Set any of
           %% them to `undefined` to leave it out. Only used by routes/2,3.
           json_path => iodata() | undefined
         , swagger_path => iodata() | undefined
         , redoc_path => iodata() | undefined
         , implicit_responses => boolean()
         , security_scheme_name => binary()
           %% Document plain `cowboy_handler` modules too, not only
           %% `cowboy_rest` ones. Default `true`.
         , plain_handlers => boolean()
         }.

-export_type([route/0, options/0]).

-define(DEFAULT_JSON_PATH, "/openapi.json").
-define(DEFAULT_SWAGGER_PATH, "/swagger").
-define(DEFAULT_REDOC_PATH, "/redoc").

%%%_ * API -------------------------------------------------------------

-doc "Equivalent to `openapi(MetaData, Routes, #{})`.".
-spec openapi(spectra_openapi:openapi_metadata(), [route()]) ->
          {ok, iodata()} | {error, [spectra:error()]}.
openapi(MetaData, Routes) ->
    openapi(MetaData, Routes, #{}).

-doc """
The OpenAPI 3.1 document for the `cowboy_rest` handlers in `Routes`.

`MetaData` must carry `title` and `version`; see
`spectra_openapi:openapi_metadata()` for the rest (`servers`, `contact`,
`license`, `security_schemes`, ...).
""".
-spec openapi(spectra_openapi:openapi_metadata(), [route()], options()) ->
          {ok, iodata()} | {error, [spectra:error()]}.
openapi(MetaData, Routes, Opts) ->
    cowboy_specer_openapi:generate(MetaData, resources(Routes, Opts), Opts).

-doc "Equivalent to `routes(MetaData, Routes, #{})`.".
-spec routes(spectra_openapi:openapi_metadata(), [route()]) -> [route()].
routes(MetaData, Routes) ->
    routes(MetaData, Routes, #{}).

-doc """
`Routes` with the documentation endpoints appended.

Appended, and Cowboy matches in order -- so a catch-all (`"/[...]"`) at the end
of `Routes` would swallow them. Pass the routes without the catch-all and
append it yourself afterwards.

Raises `{openapi_generation_failed, Errors}` rather than starting a listener
that would serve a broken document -- the same reasoning as validating config at
boot.
""".
-spec routes(spectra_openapi:openapi_metadata(), [route()], options()) -> [route()].
routes(MetaData, Routes, Opts) ->
    case openapi(MetaData, Routes, Opts) of
        {ok, Json} ->
            Routes ++ doc_routes(iolist_to_binary(Json), Opts);
        {error, Errors} ->
            erlang:error({openapi_generation_failed, Errors})
    end.

-doc "Equivalent to `resources(Routes, #{})`.".
-spec resources([route()]) -> [cowboy_specer_scan:resource()].
resources(Routes) ->
    resources(Routes, #{}).

-doc """
The analysed `cowboy_rest` resources behind `Routes`, in route order.

Exposed for inspecting or post-processing what was found before it is turned
into a document.
""".
-spec resources([route()], options()) -> [cowboy_specer_scan:resource()].
resources(Routes, Opts) ->
    Plain = maps:get(plain_handlers, Opts, true),
    [R || Route <- Routes, {ok, R} <- [resource(Route)], wanted(R, Plain)].

wanted(#{kind := plain}, false) -> false;
wanted(#{}, _Plain) -> true.

-doc """
Converts a Cowboy path to an OpenAPI path template.

`"/users/:id"` becomes `<<"/users/{id}">>`. A trailing `[...]` is dropped, and a
path that already uses `{id}` is returned unchanged, so both spellings work.
""".
-spec openapi_path(iodata()) -> binary().
openapi_path(Path) ->
    Segments = binary:split(iolist_to_binary(Path), ~"/", [global]),
    Converted = [openapi_segment(S) || S <- Segments, S =/= ~"[...]"],
    case lists:join(~"/", Converted) of
        [] -> ~"/";
        Joined -> iolist_to_binary(Joined)
    end.

openapi_segment(<<$:, Name/binary>>) -> <<"{", Name/binary, "}">>;
openapi_segment(Segment) -> Segment.

%%%_ * Internal --------------------------------------------------------

resource(Route) ->
    {Path, Module} = path_and_module(Route),
    {module, Module} = code:ensure_loaded(Module),
    cowboy_specer_scan:resource(openapi_path(Path), Module).

path_and_module({Path, Module}) when is_atom(Module) ->
    {Path, Module};
path_and_module({Path, Module, _InitialState}) when is_atom(Module) ->
    {Path, Module};
path_and_module({Path, Constraints, Module, _InitialState})
  when is_list(Constraints), is_atom(Module) ->
    {Path, Module}.

doc_routes(Json, Opts) ->
    JsonPath = path(json_path, ?DEFAULT_JSON_PATH, Opts),
    %% The UIs fetch the document by URL, so they are only useful when it is
    %% actually being served.
    SpecUrl = case JsonPath of
                  undefined -> ?DEFAULT_JSON_PATH;
                  P -> P
              end,
    [{JsonPath, cowboy_specer_docs_h, {json, Json}} || JsonPath =/= undefined] ++
        ui_route(swagger, swagger_path, ?DEFAULT_SWAGGER_PATH, SpecUrl, Opts) ++
        ui_route(redoc, redoc_path, ?DEFAULT_REDOC_PATH, SpecUrl, Opts).

ui_route(UI, Key, Default, SpecUrl, Opts) ->
    case path(Key, Default, Opts) of
        undefined -> [];
        Path -> [{Path, cowboy_specer_docs_h, {UI, list_to_binary(SpecUrl)}}]
    end.

-spec path(atom(), iodata(), options()) -> string() | undefined.
path(Key, Default, Opts) ->
    case maps:get(Key, Opts, Default) of
        undefined -> undefined;
        Path -> binary_to_list(iolist_to_binary(Path))
    end.
