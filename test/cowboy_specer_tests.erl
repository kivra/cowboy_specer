-module(cowboy_specer_tests).

-include_lib("eunit/include/eunit.hrl").

-define(META, #{title => ~"test", version => ~"1.0.0"}).

%%%_ * Path conversion -------------------------------------------------

openapi_path_test_() ->
    [ ?_assertEqual(~"/v2/person", cowboy_specer:openapi_path("/v2/person"))
    , ?_assertEqual(~"/widgets/{id}", cowboy_specer:openapi_path("/widgets/:id"))
    , ?_assertEqual(~"/a/{b}/c/{d}", cowboy_specer:openapi_path(~"/a/:b/c/:d"))
      %% Already an OpenAPI template.
    , ?_assertEqual(~"/widgets/{id}", cowboy_specer:openapi_path("/widgets/{id}"))
      %% A catch-all contributes nothing to the template.
    , ?_assertEqual(~"/static", cowboy_specer:openapi_path("/static/[...]"))
    , ?_assertEqual(~"/", cowboy_specer:openapi_path("/"))
    ].

%%%_ * Scanning an annotated cowboy_rest resource ----------------------

person_scan_test_() ->
    Op = operation(cowboy_specer_person_h, "/person", ~"GET"),
    [ {"only the method allowed_methods/2 returns",
       ?_assertEqual([~"GET"], methods(cowboy_specer_person_h, "/person"))}
    , ?_assertEqual(rest, kind(cowboy_specer_person_h, "/person"))
    , {"the provide callback is found",
       ?_assertEqual(to_xml, maps:get(callback, Op))}
    , {"reading the authorization header means bearer auth",
       ?_assert(maps:get(auth, Op))}
    , {"every literal cowboy_req:reply/2,3,4 status is found",
       ?_assertEqual([204, 400, 401, 502],
                     lists:sort(maps:keys(maps:get(replies, Op))))}
    , {"a literal reply body becomes the description",
       ?_assertEqual(~"Not Authorized",
                     maps:get(body_text, maps:get(401, maps:get(replies, Op))))}
    , {"the reply's content-type header is picked up",
       ?_assertEqual(~"text/xml",
                     maps:get(content_type, maps:get(204, maps:get(replies, Op))))}
    , {"match_qs/2 gives a required parameter",
       ?_assertMatch(#{required := true}, param(Op, query, ~"ssn"))}
    , {"...and an optional one with its default",
       ?_assertMatch(#{required := false, default := false},
                     param(Op, query, ~"verified"))}
      %% verified_constraint/2 answers {ok,true}/{ok,false} in the forward
      %% direction, which is a boolean and nothing else.
    , {"a custom constraint fun's forward clauses give the type",
       ?_assertEqual(boolean,
                     simple_type(maps:get(schema, param(Op, query, ~"verified"))))}
    , {"GET has no request body",
       ?_assertNot(maps:get(request_body, Op))}
    ].

person_openapi_test_() ->
    Get = operation_json(cowboy_specer_person_h, "/person", ~"get"),
    Doc = document([{"/person", cowboy_specer_person_h, #{}}]),
    [ {"the -spectra summary on the provide callback becomes the summary",
       ?_assertEqual(~"Look up a person by SSN", maps:get(~"summary", Get))}
    , {"the -openapi operationId is used",
       ?_assertEqual(~"getPerson", maps:get(~"operationId", Get))}
    , {"resource-level -openapi tags are inherited",
       ?_assertEqual([~"person"], maps:get(~"tags", Get))}
    , {"the provide callback's return type is the 200 schema",
       ?_assertEqual(#{~"$ref" => ~"#/components/schemas/PersonXml0"},
                     schema_of(Get, ~"200", ~"text/xml"))}
    , {"an -openapi response description wins over the reply body text",
       ?_assertEqual(~"The registry is unhappy.",
                     maps:get(~"description", response(Get, ~"502")))}
    , {"a status replied from two places keeps both literal bodies",
       ?_assertEqual(~"Invalid SSN format / Bad query parameter",
                     maps:get(~"description", response(Get, ~"400")))}
    , {"cowboy_rest's own 406 is documented",
       ?_assert(maps:is_key(~"406", maps:get(~"responses", Get)))}
    , {"a bearer scheme is declared",
       ?_assertMatch(#{~"bearerAuth" := #{~"type" := ~"http", ~"scheme" := ~"bearer"}},
                     maps:get(~"securitySchemes", maps:get(~"components", Doc)))}
    , {"and required, since every operation needs it",
       ?_assertEqual([#{~"bearerAuth" => []}], maps:get(~"security", Doc))}
    , {"a named type referenced from -openapi lands in components",
       ?_assert(maps:is_key(~"Ssn0", maps:get(~"schemas", maps:get(~"components", Doc))))}
    , {"a query parameter's default reaches the reader as prose",
       ?_assertMatch(<<"Only ever promotes.\n\nDefaults to `false`.">>,
                     maps:get(~"description", parameter_json(Get, ~"verified")))}
    ].

%%%_ * Per-method attribution ------------------------------------------

per_method_facts_test_() ->
    Get = operation(cowboy_specer_widget_h, "/widgets/:widget_id", ~"GET"),
    Post = operation(cowboy_specer_widget_h, "/widgets/:widget_id", ~"POST"),
    Delete = operation(cowboy_specer_widget_h, "/widgets/:widget_id", ~"DELETE"),
    [ {"cowboy_req:binding/2 is a required path parameter",
       ?_assertMatch(#{in := path, required := true},
                     param(Get, path, ~"widget_id"))}
    , {"the int constraint is an integer",
       ?_assertEqual(integer, simple_type(maps:get(schema, param(Get, query, ~"page"))))}
    , {"a default makes the parameter optional",
       ?_assertMatch(#{required := false, default := 1}, param(Get, query, ~"page"))}
    , {"a non-protocol header is a header parameter",
       ?_assertMatch(#{in := header, required := false},
                     param(Get, header, ~"x-tenant"))}
    , {"returning {created, URI} means 201",
       ?_assertEqual([201], maps:get(implied, Post))}
    , {"DELETE implies 204",
       ?_assertEqual([204], maps:get(implied, Delete))}
    , {"the GET handler's 400 does not surface under DELETE",
       ?_assertEqual(#{}, maps:get(replies, Delete))}
    , {"the POST handler's 422 does not surface under GET",
       ?_assertEqual([400], maps:keys(maps:get(replies, Get)))}
    , {"...nor the GET handler's parameters under DELETE, though the path "
       "template's variable is declared on every operation",
       ?_assertEqual([~"widget_id"],
                     [N || #{name := N} <- maps:get(parameters, Delete)])}
    ].

widget_openapi_test_() ->
    Path = maps:get(~"/widgets/{widget_id}",
                    maps:get(~"paths",
                             document([{"/widgets/:widget_id", cowboy_specer_widget_h, #{}}]))),
    [ {"the Cowboy path became an OpenAPI template",
       ?_assertEqual([~"delete", ~"get", ~"post"], lists:sort(maps:keys(Path)))}
    , {"the <<\"application/json\">> shorthand content type is understood",
       ?_assertEqual(#{~"$ref" => ~"#/components/schemas/Widget0"},
                     schema_of(maps:get(~"get", Path), ~"200", ~"application/json"))}
      %% cowboy_rest answers {created, URI} with a Location header and no body,
      %% so claiming one would be wrong however good the provide callback's spec
      %% is.
    , {"a 201 from {created, URI} carries no body",
       ?_assertNot(maps:is_key(~"content", response(maps:get(~"post", Path), ~"201")))}
    , {"the -openapi request_body schema is used",
       ?_assertEqual(#{~"$ref" => ~"#/components/schemas/NewWidget0"},
                     maps:get(~"schema",
                              maps:get(~"application/json",
                                       maps:get(~"content",
                                                maps:get(~"requestBody",
                                                         maps:get(~"post", Path))))))}
    , {"DELETE's 204 carries no body",
       ?_assertNot(maps:is_key(~"content", response(maps:get(~"delete", Path), ~"204")))}
    , {"nothing reads an authorization header, so no security scheme",
       ?_assertNot(maps:is_key(~"securitySchemes",
                               maps:get(~"components",
                                        document([{"/w", cowboy_specer_widget_h, #{}}]))))}
    ].

%%%_ * An unannotated resource still documents -------------------------

no_annotations_test_() ->
    Post = operation(cowboy_specer_bare_h, "/bare", ~"POST"),
    Options = operation(cowboy_specer_bare_h, "/bare", ~"OPTIONS"),
    PostJson = operation_json(cowboy_specer_bare_h, "/bare", ~"post"),
    [ ?_assertMatch(#{required := true}, param(Post, query, ~"ssn"))
    , {"OPTIONS reaches none of the POST handler's code",
       ?_assertEqual([], maps:get(parameters, Options))}
    , ?_assertEqual(#{}, maps:get(replies, Options))
    , {"read_body/1 means there is a request body",
       ?_assert(maps:get(request_body, Post))}
    , {"returning {true, Req, State} through a span wrapper still means 204",
       ?_assertEqual([204], maps:get(implied, Post))}
    , {"the shape is there without a single annotation",
       ?_assertEqual([~"204", ~"400", ~"415"],
                     lists:sort(maps:keys(maps:get(~"responses", PostJson))))}
    , {"no summary was invented",
       ?_assertNot(maps:is_key(~"summary", PostJson))}
    , {"an undeclared body is documented as an opaque payload of the right type",
       ?_assert(maps:is_key(~"text/xml",
                            maps:get(~"content", maps:get(~"requestBody", PostJson))))}
    ].

%%%_ * is_authorized/2 -------------------------------------------------

%% cowboy_specer_open_h implements is_authorized/2 but answers {true, _, _} in every
%% clause, which is how a resource declares the callback while staying open.
%% Reporting it as authenticated would be a lie.
always_authorized_is_not_auth_test_() ->
    Op = operation(cowboy_specer_open_h, "/metrics", ~"GET"),
    Get = operation_json(cowboy_specer_open_h, "/metrics", ~"get"),
    [ ?_assertNot(maps:get(auth, Op))
    , ?_assertNot(maps:is_key(~"description", Get))
    , {"with no allowed_methods/2, cowboy's default applies",
       ?_assertEqual([~"GET", ~"HEAD", ~"OPTIONS"], methods(cowboy_specer_open_h, "/metrics"))}
    ].

%%%_ * Plain cowboy_handler modules ------------------------------------

plain_handler_test_() ->
    [Probe] = cowboy_specer:resources([{"/livez", cowboy_specer_probe_h, #{}}]),
    Op = maps:get(~"GET", maps:get(operations, Probe)),
    [ ?_assertEqual(plain, maps:get(kind, Probe))
    , {"with no cowboy_req:method/1 test, GET is the answer",
       ?_assertEqual([~"GET"], maps:get(methods, Probe))}
    , {"the literal reply body is the description",
       ?_assertEqual(~"still here",
                     maps:get(body_text, maps:get(200, maps:get(replies, Op))))}
    , {"nothing is implied -- there is no cowboy_rest state machine",
       ?_assertEqual([], maps:get(implied, Op))}
    , {"...and no content negotiation, so no 406",
       ?_assertEqual([~"200"],
                     maps:keys(maps:get(~"responses",
                                        operation_json(cowboy_specer_probe_h, "/livez", ~"get"))))}
    ].

%% Nothing about cowboy_specer_job_h is literal at the cowboy_req:reply/4 call site.
plain_handler_wrapper_test_() ->
    [Job] = cowboy_specer:resources([{"/jobs/import", cowboy_specer_job_h, #{}}]),
    Op = maps:get(~"POST", maps:get(operations, Job)),
    Replies = maps:get(replies, Op),
    [ {"the cowboy_req:method/1 test gives the method",
       ?_assertEqual([~"POST"], maps:get(methods, Job))}
    , {"statuses are traced through the local reply/4 wrapper",
       ?_assertEqual([202, 401, 409], lists:sort(maps:keys(Replies)))}
    , {"405 is dropped: it answers the methods this handler does not serve",
       ?_assertNot(maps:is_key(405, Replies))}
    , {"the content type comes from the local headers/1 helper",
       ?_assertEqual(~"application/json", maps:get(content_type, maps:get(202, Replies)))}
    , {"replying 401 means the endpoint is authenticated, wherever the check lives",
       ?_assert(maps:get(auth, Op))}
    , {"the -openapi response schema is used",
       ?_assertEqual(#{~"$ref" => ~"#/components/schemas/JobStatus0"},
                     schema_of(operation_json(cowboy_specer_job_h, "/jobs/import", ~"post"),
                               ~"202", ~"application/json"))}
    , {"a parameter the scanner cannot see is added from -openapi",
       ?_assertMatch(#{~"in" := ~"query", ~"required" := false,
                       ~"description" := ~"Validate the request without starting."},
                     parameter_json(operation_json(cowboy_specer_job_h,
                                                   "/jobs/import", ~"post"),
                                    ~"dry_run"))}
    , {"...and its declared `in` is honoured, not just the query default",
       ?_assertMatch(#{~"in" := ~"header", ~"required" := false},
                     parameter_json(operation_json(cowboy_specer_job_h,
                                                   "/jobs/import", ~"post"),
                                    ~"x-request-id"))}
    ].

%%%_ * Selecting what to document --------------------------------------

plain_handlers_can_be_excluded_test() ->
    Routes = [{"/livez", cowboy_specer_probe_h, #{}}, {"/person", cowboy_specer_person_h, #{}}],
    Kept = cowboy_specer:resources(Routes, #{plain_handlers => false}),
    ?assertEqual([cowboy_specer_person_h], [maps:get(module, R) || R <- Kept]).

hidden_handlers_are_skipped_test() ->
    ?assertEqual([], cowboy_specer:resources([{"/secret", cowboy_specer_hidden_h, #{}}])).

non_handlers_are_skipped_test() ->
    %% No init/2 at all, so not a Cowboy handler.
    ?assertEqual([], cowboy_specer:resources([{"/nope", cowboy_specer_secret, #{}}])).

implicit_responses_can_be_turned_off_test() ->
    {ok, Json} = cowboy_specer:openapi(?META, [{"/person", cowboy_specer_person_h, #{}}],
                                 #{implicit_responses => false}),
    Get = maps:get(~"get", maps:get(~"/person",
                                    maps:get(~"paths",
                                             json:decode(iolist_to_binary(Json))))),
    ?assertNot(maps:is_key(~"406", maps:get(~"responses", Get))).

%%%_ * Documentation routes --------------------------------------------

doc_routes_are_appended_test() ->
    Routes = cowboy_specer:routes(?META, [{"/person", cowboy_specer_person_h, #{}}]),
    ?assertEqual(["/person", "/openapi.json", "/swagger", "/redoc"],
                 [P || {P, _Mod, _State} <- Routes]).

doc_routes_can_be_moved_test() ->
    Routes = cowboy_specer:routes(?META, [], #{ json_path => "/docs/spec.json"
                                         , swagger_path => "/docs"
                                         , redoc_path => undefined
                                         }),
    ?assertEqual(["/docs/spec.json", "/docs"], [P || {P, _, _} <- Routes]).

%%%_ * Whole documents -------------------------------------------------

document_is_valid_openapi_test_() ->
    Doc = document([ {"/person", cowboy_specer_person_h, #{}}
                   , {"/widgets/:widget_id", cowboy_specer_widget_h, #{}}
                   , {"/bare", cowboy_specer_bare_h, #{}}
                   , {"/livez", cowboy_specer_probe_h, #{}}
                   , {"/jobs/import", cowboy_specer_job_h, #{}}
                   ]),
    [ ?_assertEqual(~"3.1.0", maps:get(~"openapi", Doc))
    , ?_assertEqual(#{~"title" => ~"test", ~"version" => ~"1.0.0"},
                    maps:get(~"info", Doc))
    , ?_assertEqual([~"/bare", ~"/jobs/import", ~"/livez", ~"/person",
                     ~"/widgets/{widget_id}"],
                    lists:sort(maps:keys(maps:get(~"paths", Doc))))
    , {"not every operation needs a token here, so security is not document-wide",
       ?_assertNot(maps:is_key(~"security", Doc))}
    , {"but the scheme is still declared, so the ones that do can say so",
       ?_assert(maps:is_key(~"securitySchemes", maps:get(~"components", Doc)))}
    , {"an operation needing a token says so in its description",
       ?_assertMatch(#{~"description" := _},
                     maps:get(~"get", maps:get(~"/person",
                                               maps:get(~"paths", Doc))))}
    ].

metadata_is_passed_through_test() ->
    Meta = maps:merge(?META, #{ description => ~"Everything."
                              , servers => [#{url => ~"https://example.test"}]
                              }),
    {ok, Json} = cowboy_specer:openapi(Meta, [{"/livez", cowboy_specer_probe_h, #{}}]),
    Doc = json:decode(iolist_to_binary(Json)),
    ?assertEqual([#{~"url" => ~"https://example.test"}], maps:get(~"servers", Doc)),
    ?assertEqual(~"Everything.", maps:get(~"description", maps:get(~"info", Doc))).

%%%_ * Failure modes ---------------------------------------------------

module_without_debug_info_test() ->
    %% erlang is preloaded and carries no abstract code.
    ?assertError({module_not_found, erlang, preloaded},
                 cowboy_specer:resources([{"/x", erlang, #{}}])).

%%%_ * Helpers ---------------------------------------------------------

document(Routes) ->
    {ok, Json} = cowboy_specer:openapi(?META, Routes),
    json:decode(iolist_to_binary(Json)).

resource(Module, Path) ->
    [Resource] = cowboy_specer:resources([{Path, Module, #{}}]),
    Resource.

kind(Module, Path) ->
    maps:get(kind, resource(Module, Path)).

methods(Module, Path) ->
    maps:get(methods, resource(Module, Path)).

operation(Module, Path, Method) ->
    maps:get(Method, maps:get(operations, resource(Module, Path))).

operation_json(Module, Path, Method) ->
    Document = document([{Path, Module, #{}}]),
    OpenApiPath = cowboy_specer:openapi_path(Path),
    maps:get(Method, maps:get(OpenApiPath, maps:get(~"paths", Document))).

param(#{parameters := Params}, In, Name) ->
    [P] = [P || #{in := I, name := N} = P <- Params, I =:= In, N =:= Name],
    P.

parameter_json(Operation, Name) ->
    [P] = [P || #{~"name" := N} = P <- maps:get(~"parameters", Operation), N =:= Name],
    P.

%% The `type` field of an #sp_simple_type{} without depending on the record.
simple_type({sp_simple_type, Type, _Meta}) -> Type.

response(Operation, Status) ->
    maps:get(Status, maps:get(~"responses", Operation)).

schema_of(Operation, Status, ContentType) ->
    maps:get(~"schema", maps:get(ContentType,
                                 maps:get(~"content", response(Operation, Status)))).
