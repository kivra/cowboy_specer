-module(ex_server).
-moduledoc """
Wiring: the whole of what using `cowboy_specer` looks like.

    $ rebar3 as examples shell
    1> ex_server:start().
    Serving http://localhost:8080/swagger

`routes/0` is an ordinary Cowboy route list -- the handlers know nothing about
any of this. `cbs_spec:routes/2` reads them and hands back the same list with
`/openapi.json`, `/swagger` and `/redoc` appended.
""".

-export([ start/0
        , start/1
        , stop/0
        , routes/0
        , metadata/0
        , write_document/1
        ]).

-define(LISTENER, ex_http).

-doc "Starts the example API on port 8080.".
-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    start(8080).

-spec start(inet:port_number()) -> {ok, pid()} | {error, term()}.
start(Port) ->
    {ok, _Started} = application:ensure_all_started(cowboy),
    %% The document is built here, once, and served from a binary -- so a
    %% handler the analysis cannot make sense of fails the boot rather than the
    %% docs.
    Dispatch = cowboy_router:compile([{'_', cbs_spec:routes(metadata(), routes())}]),
    Result = cowboy:start_clear(?LISTENER, [{port, Port}],
                                #{env => #{dispatch => Dispatch}}),
    io:format("Serving http://localhost:~p/swagger~n", [Port]),
    Result.

-spec stop() -> ok | {error, not_found}.
stop() ->
    cowboy:stop_listener(?LISTENER).

-doc "A plain Cowboy route list. Nothing here is specific to `cowboy_specer`.".
-spec routes() -> [cbs_spec:route()].
routes() ->
    [ {"/healthz", ex_health_h, #{}}
    , {"/minimal", ex_minimal_h, #{}}
    , {"/pets", ex_pets_h, #{}}
    , {"/pets/:petId", ex_pet_h, #{}}
    , {"/admin/reindex", ex_reindex_h, #{}}
    ].

-spec metadata() -> spectra_openapi:openapi_metadata().
metadata() ->
    #{ title => ~"Pet Store"
     , version => ~"1.0.0"
     , description => ~"The `cowboy_specer` example API."
     , servers => [#{url => ~"http://localhost:8080"}]
     }.

-doc """
Writes the document to a file instead of serving it.

Usually the better answer for a service whose docs should not be public: run it
at build time and check the result in, so an API change shows up as a diff.
""".
-spec write_document(file:filename_all()) -> ok.
write_document(File) ->
    {ok, Document} = cbs_spec:openapi(metadata(), routes()),
    Pretty = json:format(json:decode(iolist_to_binary(Document))),
    file:write_file(File, Pretty).
