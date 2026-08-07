-module(cbs_SUITE).
-moduledoc """
End-to-end: start a real Cowboy listener from `cbs_spec:routes/2` and fetch the
documentation endpoints over HTTP.

The eunit tests check what the analysis produces; this checks that the routes
it hands back actually serve it, and that adding them does not disturb the
handler routes they were appended to.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(LISTENER, cbs_suite_http).

all() ->
    [ serves_openapi_json
    , serves_swagger_ui
    , serves_redoc
    , handler_routes_still_work
    , unknown_path_is_404
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([cowboy, inets]),
    Routes = cbs_spec:routes(#{title => ~"suite", version => ~"1.0.0"},
                             [ {"/person", cbs_person_h, #{}}
                             , {"/widgets/:widget_id", cbs_widget_h, #{}}
                             , {"/livez", cbs_probe_h, #{}}
                             ]),
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    [{port, ranch:get_port(?LISTENER)} | Config].

end_per_suite(_Config) ->
    ok = cowboy:stop_listener(?LISTENER).

serves_openapi_json(Config) ->
    {200, Headers, Body} = get(Config, "/openapi.json"),
    ?assertEqual("application/json", proplists:get_value("content-type", Headers)),
    Document = json:decode(Body),
    ?assertEqual(~"3.1.0", maps:get(~"openapi", Document)),
    ?assertEqual([~"/livez", ~"/person", ~"/widgets/{widget_id}"],
                 lists:sort(maps:keys(maps:get(~"paths", Document)))).

serves_swagger_ui(Config) ->
    {200, Headers, Body} = get(Config, "/swagger"),
    ?assertEqual("text/html; charset=utf-8",
                 proplists:get_value("content-type", Headers)),
    %% The page has to point at wherever the document is actually served.
    ?assertNotEqual(nomatch, binary:match(Body, ~"/openapi.json")),
    ?assertNotEqual(nomatch, binary:match(Body, ~"swagger-ui")).

serves_redoc(Config) ->
    {200, _Headers, Body} = get(Config, "/redoc"),
    ?assertNotEqual(nomatch, binary:match(Body, ~"spec-url=\"/openapi.json\"")).

%% The documentation routes are appended, so the handlers they were appended to
%% must behave exactly as before.
handler_routes_still_work(Config) ->
    {200, _, Alive} = get(Config, "/livez"),
    ?assertEqual(~"still here", Alive),
    {401, _, _} = get(Config, "/person?ssn=190001010000"),
    {200, PersonHeaders, Person} =
        get(Config, "/person?ssn=190001010000",
            [{"authorization", "Bearer token"}, {"accept", "text/xml"}]),
    ?assertEqual("text/xml", proplists:get_value("content-type", PersonHeaders)),
    ?assertNotEqual(nomatch, binary:match(Person, ~"190001010000")),
    {204, _, _} = get(Config, "/person?ssn=000000000000",
                      [{"authorization", "Bearer token"}]),
    {400, _, _} = get(Config, "/person?ssn=nope",
                      [{"authorization", "Bearer token"}]).

unknown_path_is_404(Config) ->
    {404, _, _} = get(Config, "/nothing/here").

%%%_ * Helpers ---------------------------------------------------------

get(Config, Path) ->
    get(Config, Path, []).

get(Config, Path, Headers) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(?config(port, Config)) ++ Path,
    {ok, {{_Version, Status, _Reason}, ResponseHeaders, Body}} =
        httpc:request(get, {Url, Headers}, [], [{body_format, binary}]),
    {Status, ResponseHeaders, Body}.
