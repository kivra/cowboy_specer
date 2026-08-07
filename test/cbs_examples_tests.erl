-module(cbs_examples_tests).
-moduledoc """
Keeps `examples/` honest.

An example that no longer produces what its comments claim is worse than no
example, so the document the example API generates is asserted here rather than
left to be discovered by a reader.
""".

-include_lib("eunit/include/eunit.hrl").

-define(TEMPDIR, case os:getenv("TMPDIR") of false -> "/tmp"; Dir -> Dir end).

document() ->
    {ok, Json} = cbs_spec:openapi(ex_server:metadata(), ex_server:routes()),
    json:decode(iolist_to_binary(Json)).

paths() ->
    maps:get(~"paths", document()).

operation(Path, Method) ->
    maps:get(Method, maps:get(Path, paths())).

schemas() ->
    maps:get(~"schemas", maps:get(~"components", document())).

every_example_route_is_documented_test() ->
    ?assertEqual([~"/admin/reindex", ~"/healthz", ~"/minimal", ~"/pets",
                  ~"/pets/{petId}"],
                 lists:sort(maps:keys(paths()))).

%%%_ * The annotated collection ----------------------------------------

pets_test_() ->
    Get = operation(~"/pets", ~"get"),
    Post = operation(~"/pets", ~"post"),
    [ {"the record behind the response type becomes a named component",
       ?_assertEqual(#{~"$ref" => ~"#/components/schemas/Pets0"},
                     schema_of(Get, ~"200", ~"application/json"))}
    , {"an optional record field is not required",
       ?_assertEqual([~"id", ~"name"],
                     maps:get(~"required", maps:get(~"Pet0", schemas())))}
    , {"a `=>` map field is optional in the request body too",
       ?_assertEqual([~"name"],
                     maps:get(~"required", maps:get(~"NewPet0", schemas())))}
    , {"the int constraint types the query parameter",
       ?_assertMatch(#{~"required" := false, ~"schema" := #{~"type" := ~"integer"}},
                     parameter(Get, ~"limit"))}
    , {"returning {created, URI} is a 201",
       ?_assert(maps:is_key(~"201", maps:get(~"responses", Post)))}
    , {"reading a body means a documented request body",
       ?_assert(maps:is_key(~"requestBody", Post))}
    ].

%%%_ * The item resource -----------------------------------------------

pet_test_() ->
    Get = operation(~"/pets/{petId}", ~"get"),
    Delete = operation(~"/pets/{petId}", ~"delete"),
    [ {"a remote type from another module still resolves to a component",
       ?_assertEqual(#{~"$ref" => ~"#/components/schemas/Pet0"},
                     schema_of(Get, ~"200", ~"application/json"))}
    , {"reading the authorization header is bearer auth",
       ?_assertNotEqual(nomatch, binary:match(maps:get(~"description", Get),
                                              ~"bearer token"))}
    , {"DELETE declares the path parameter even though it never reads it",
       ?_assertMatch(#{~"in" := ~"path", ~"required" := true},
                     parameter(Delete, ~"petId"))}
    , {"...and answers 204 and nothing else",
       ?_assertEqual([~"204"], maps:keys(maps:get(~"responses", Delete)))}
    ].

%%%_ * The unannotated resource ----------------------------------------

%% The point of ex_minimal_h is the contrast: without a single annotation the
%% shape is still there, and only the prose is missing.
minimal_test_() ->
    Get = operation(~"/minimal", ~"get"),
    [ ?_assertEqual([~"200", ~"400", ~"406"],
                    lists:sort(maps:keys(maps:get(~"responses", Get))))
    , ?_assertMatch(#{~"required" := true}, parameter(Get, ~"q"))
    , ?_assertNot(maps:is_key(~"summary", Get))
    , ?_assertNot(maps:is_key(~"content", maps:get(~"200", maps:get(~"responses", Get))))
    ].

%%%_ * The plain handlers ----------------------------------------------

health_test() ->
    ?assertEqual([~"get"], maps:keys(maps:get(~"/healthz", paths()))).

%% Nothing in ex_reindex_h is literal at the cowboy_req:reply/4 call site.
reindex_test_() ->
    Post = operation(~"/admin/reindex", ~"post"),
    [ {"the method comes from the cowboy_req:method/1 test",
       ?_assertEqual([~"post"], maps:keys(maps:get(~"/admin/reindex", paths())))}
    , {"the statuses come from the reply/4 wrapper's call sites",
       ?_assertEqual([~"202", ~"401", ~"409"],
                     lists:sort(maps:keys(maps:get(~"responses", Post))))}
    , {"405 is dropped: it answers the methods this handler does not serve",
       ?_assertNot(maps:is_key(~"405", maps:get(~"responses", Post)))}
    , {"the content type comes from the headers/1 helper",
       ?_assertEqual(#{~"$ref" => ~"#/components/schemas/JobStatus0"},
                     schema_of(Post, ~"202", ~"application/json"))}
    , {"a 401 is enough to know the endpoint is authenticated",
       ?_assertNotEqual(nomatch, binary:match(maps:get(~"description", Post),
                                              ~"bearer token"))}
    ].

%%%_ * Writing the document to a file ----------------------------------

write_document_test() ->
    File = filename:join(?TEMPDIR, "cbs_examples_openapi.json"),
    ok = ex_server:write_document(File),
    {ok, Written} = file:read_file(File),
    ok = file:delete(File),
    ?assertEqual(~"3.1.0", maps:get(~"openapi", json:decode(Written))).

%%%_ * Helpers ---------------------------------------------------------

parameter(Operation, Name) ->
    [P] = [P || #{~"name" := N} = P <- maps:get(~"parameters", Operation), N =:= Name],
    P.

schema_of(Operation, Status, ContentType) ->
    Response = maps:get(Status, maps:get(~"responses", Operation)),
    maps:get(~"schema", maps:get(ContentType, maps:get(~"content", Response))).
