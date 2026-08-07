-module(cowboy_specer_examples_SUITE).
-moduledoc """
Runs the example API and checks that it answers what its document says it does.

`cowboy_specer_examples_tests` asserts what the examples *document*; this asserts that the
handlers actually behave that way. An example whose documented 404 cannot happen
teaches the reader the wrong thing, and only exercising it catches that.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [ documented_endpoints_are_served
    , every_documented_status_happens
    , responses_match_their_schemas
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([cowboy, inets]),
    {ok, _} = ex_server:start(0),
    [{port, ranch:get_port(ex_http)} | Config].

end_per_suite(_Config) ->
    ok = ex_server:stop().

documented_endpoints_are_served(Config) ->
    {200, _, Body} = request(Config, get, "/openapi.json", [], <<>>),
    Document = json:decode(Body),
    ?assertEqual([~"/admin/reindex", ~"/healthz", ~"/minimal", ~"/pets",
                  ~"/pets/{petId}"],
                 lists:sort(maps:keys(maps:get(~"paths", Document)))),
    {200, _, Swagger} = request(Config, get, "/swagger", [], <<>>),
    ?assertNotEqual(nomatch, binary:match(Swagger, ~"/openapi.json")).

%% Every status in the document, provoked for real.
every_documented_status_happens(Config) ->
    Json = [{"accept", "application/json"}],
    Token = [{"authorization", "Bearer t"}],
    ?assertMatch({200, _, ~"OK"}, request(Config, get, "/healthz", [], <<>>)),
    ?assertMatch({200, _, _}, request(Config, get, "/minimal?q=hi",
                                      [{"accept", "text/plain"}], <<>>)),
    ?assertMatch({400, _, _}, request(Config, get, "/minimal?q=",
                                      [{"accept", "text/plain"}], <<>>)),
    ?assertMatch({200, _, _}, request(Config, get, "/pets?limit=1", Json, <<>>)),
    ?assertMatch({400, _, _}, request(Config, get, "/pets?limit=999", Json, <<>>)),
    ?assertMatch({201, _, _}, request(Config, post, "/pets", [], ~"{\"name\":\"Cy\"}")),
    ?assertMatch({422, _, _}, request(Config, post, "/pets", [], ~"{}")),
    ?assertMatch({401, _, _}, request(Config, get, "/pets/1", Json, <<>>)),
    ?assertMatch({200, _, _}, request(Config, get, "/pets/1", Json ++ Token, <<>>)),
    ?assertMatch({404, _, _}, request(Config, get, "/pets/9", Json ++ Token, <<>>)),
    ?assertMatch({204, _, _}, request(Config, delete, "/pets/1", Token, <<>>)),
    ?assertMatch({401, _, _}, request(Config, post, "/admin/reindex", [], <<>>)),
    ?assertMatch({202, _, _}, request(Config, post, "/admin/reindex", Token, <<>>)),
    %% The second one is refused, which is where the documented 409 comes from.
    ?assertMatch({409, _, _}, request(Config, post, "/admin/reindex", Token, <<>>)).

%% The pets resource encodes through the same type cowboy_specer turns into the
%% schema, so a response that does not match its schema means they have drifted.
responses_match_their_schemas(Config) ->
    Json = [{"accept", "application/json"}],
    {200, Headers, Pets} = request(Config, get, "/pets?limit=2", Json, <<>>),
    ?assertEqual("application/json", proplists:get_value("content-type", Headers)),
    ?assertMatch({ok, [_, _]},
                 spectra:decode(json, ex_pets_h, {type, pets, 0}, Pets)),
    {200, _, Pet} = request(Config, get, "/pets/1",
                            Json ++ [{"authorization", "Bearer t"}], <<>>),
    ?assertMatch({ok, _}, spectra:decode(json, ex_pets_h, {type, pet, 0}, Pet)),
    %% A 201 carries no body, which is what the document says of it.
    {201, _, Created} = request(Config, post, "/pets", [], ~"{\"name\":\"Cy\"}"),
    ?assertEqual(~"", Created).

%%%_ * Helpers ---------------------------------------------------------

request(Config, Method, Path, Headers, Body) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(?config(port, Config)) ++ Path,
    Request = case Method of
                  post -> {Url, Headers, "application/json", Body};
                  _NoBody -> {Url, Headers}
              end,
    {ok, {{_Version, Status, _Reason}, ResponseHeaders, ResponseBody}} =
        httpc:request(Method, Request, [], [{body_format, binary}]),
    {Status, ResponseHeaders, ResponseBody}.
