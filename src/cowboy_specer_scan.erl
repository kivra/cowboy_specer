-module(cowboy_specer_scan).
-moduledoc """
Static analysis of a `cowboy_rest` handler module.

Reads the module's abstract code (it must be compiled with `debug_info`) and
derives the *shape* of the resource it implements. Nothing is executed and no
`Req` is faked, so the analysis is safe to run at boot or in a test.

What is derived, and from where:

| Fact                     | Source                                                    |
|--------------------------|-----------------------------------------------------------|
| Methods                  | the literal list returned by `allowed_methods/2`          |
| Response content types   | `content_types_provided/2`                                |
| Request content types    | `content_types_accepted/2`                                |
| Status codes             | `cowboy_req:reply/2,3,4` calls with a literal status       |
| Success status           | the accept callback's return value (`true`, `{created,_}`) |
| Query parameters         | `cowboy_req:match_qs/2`                                   |
| Cookie parameters        | `cowboy_req:match_cookies/2`                              |
| Path parameters          | the `{name}` variables in the route's path template        |
| Header parameters        | `cowboy_req:header/2,3`                                   |
| Bearer auth              | reading the `authorization` header, or `is_authorized/2`   |
| Request body present     | `cowboy_req:read_body/1,2`                                |

Facts are attributed to a method rather than to the module: for each method we
compute the callbacks `cowboy_rest` can reach for *that* method (the generic
callbacks plus the method's provide/accept callback), close over local calls,
and collect only the facts found in that set. So a resource serving `OPTIONS`
and `POST` does not report the `POST` handler's query parameters under
`OPTIONS`.

Prose (summaries, descriptions) and anything a type is needed for (response and
request body schemas) is *not* guessed — see `cowboy_specer` for the
`-openapi(...)` attribute and the `-spec`/`-spectra(...)` conventions that
supply it.

## Known limits

Only what is literal in *this* module is seen. A status code passed through a
local `reply/5` wrapper, a `match_qs/2` list built at runtime, or an
`authorization` header read inside a helper module are all invisible. The
`-openapi(...)` attribute is the escape hatch for those.
""".

-export([ resource/2
        ]).

-export_type([ resource/0
             , kind/0
             , operation/0
             , param/0
             , reply/0
             , content_type/0
             ]).

-include_lib("spectra/include/spectra_internal.hrl").

%% `cowboy_rest` callbacks that run for every method. Used as the roots of the
%% per-method reachability search, so any of them that the module implements
%% contributes its facts to all methods.
-define(GENERIC_CALLBACKS,
        [ init
        , allowed_methods
        , allow_missing_post
        , charsets_provided
        , content_types_accepted
        , content_types_provided
        , expires
        , forbidden
        , generate_etag
        , is_authorized
        , is_conflict
        , known_methods
        , languages_provided
        , last_modified
        , malformed_request
        , moved_permanently
        , moved_temporarily
        , multiple_choices
        , previously_existed
        , ranges_provided
        , rate_limited
        , resource_exists
        , service_available
        , uri_too_long
        , valid_content_headers
        , valid_entity_length
        , variances
        ]).

%% Headers `cowboy_rest` negotiates itself. Reading one of these says nothing
%% about the resource's interface, so they are not reported as parameters.
-define(PROTOCOL_HEADERS,
        [ ~"accept"
        , ~"accept-charset"
        , ~"accept-encoding"
        , ~"accept-language"
        , ~"content-length"
        , ~"content-type"
        , ~"cookie"
        , ~"host"
        , ~"if-match"
        , ~"if-modified-since"
        , ~"if-none-match"
        , ~"if-unmodified-since"
        , ~"range"
        , ~"te"
        , ~"transfer-encoding"
        ]).

-define(DOCUMENTED_METHODS,
        [~"GET", ~"HEAD", ~"POST", ~"PUT", ~"PATCH", ~"DELETE", ~"OPTIONS"]).

%% Matches a call to `cowboy_req:F(...)` in abstract form.
-define(cowboy_req(F), {remote, _, {atom, _, cowboy_req}, {atom, _, F}}).

-type content_type() :: {binary(), binary(), '*' | [{binary(), binary()}]}.
-type fa() :: {atom(), arity()}.
-type location() :: path | query | header | cookie.

-type param() ::
        #{ name := binary()
         , in := location()
         , required := boolean()
         , schema := spectra:sp_type_or_ref()
         , default => term()
         }.

-type reply() ::
        #{ status := 100..599
         , content_type => binary()
         , body_text => binary()
         }.

-type kind() :: rest | plain.

-type operation() ::
        #{ method := binary()
           %% The `content_types_provided`/`content_types_accepted` callback
           %% that serves this method, if any. Its `-spec` carries the body
           %% type and its `-spectra(...)` attribute the prose. Always
           %% `undefined` for a plain handler, which has no such callback.
         , callback := atom() | undefined
         , parameters := [param()]
         , replies := #{100..599 => reply()}
           %% Statuses implied by the handler's return value rather than by an
           %% explicit `cowboy_req:reply/2,3,4`.
         , implied := [100..599]
         , auth := boolean()
         , request_body := boolean()
         }.

-type resource() ::
        #{ module := module()
         , kind := kind()
         , path := binary()
         , type_info := spectra:type_info()
         , methods := [binary()]
         , provided := [{content_type(), atom()}]
         , accepted := [{content_type(), atom()}]
           %% The merged `-openapi(...)` attributes.
         , doc := map()
         , operations := #{binary() => operation()}
         }.

%% A fact discovered in one function's body.
-type fact() :: auth
              | reads_body
              | {param, param()}
              | {reply, reply()}
              | {method, binary()}
                %% A `cowboy_req:reply/2,3,4` whose status is the enclosing
                %% function's Nth argument. Resolved against that function's
                %% call sites in a second pass -- see resolve_facts/2.
              | {reply_arg, fa(), pos_integer(), map()}
              | {accept_result, true | false | created | see_other}.

%%%_ * API -------------------------------------------------------------

-doc """
Analyses the resource `Module` serves at `Path`.

`Path` is an OpenAPI path template (`/users/{id}`); see
`cowboy_specer:openapi_path/1` for turning a Cowboy path into one.

A `cowboy_rest` handler is analysed through its REST callbacks. Any other
module exporting `init/2` is analysed as a plain `cowboy_handler`: `init/2` is
the only entry point, so every fact comes from what is reachable from there.

Returns `skip` for a module that exports no `init/2` at all -- it is not a
Cowboy handler -- and for one that asks to be left out with
`-openapi(#{hidden => true})`.
""".
-spec resource(binary(), module()) -> {ok, resource()} | skip.
resource(Path, Module) ->
    Forms = forms(Module),
    Clauses = clauses(Forms),
    case maps:is_key({init, 2}, Clauses) andalso not hidden(Forms) of
        false -> skip;
        true -> {ok, build(Path, Module, Forms, Clauses)}
    end.

hidden(Forms) ->
    maps:get(hidden, doc_attribute(Forms), false) =:= true.

%%%_ * Reading the module ----------------------------------------------

-spec forms(module()) -> [erl_parse:abstract_form()].
forms(Module) ->
    case code:which(Module) of
        cover_compiled ->
            {_, _, Path} = code:get_object_code(Module),
            forms_from_path(Path);
        Error when Error =:= non_existing orelse Error =:= preloaded ->
            erlang:error({module_not_found, Module, Error});
        Path ->
            forms_from_path(Path)
    end.

forms_from_path(Path) ->
    case beam_lib:chunks(Path, [abstract_code]) of
        {ok, {_Module, [{abstract_code, {_, Forms}}]}} ->
            Forms;
        {ok, {Module, [{abstract_code, no_abstract_code}]}} ->
            erlang:error({module_not_compiled_with_debug_info, Module, Path});
        {error, beam_lib, Reason} ->
            erlang:error({beam_lib_error, Path, Reason})
    end.

%% Either the behaviour is declared, or `init/2` says so by returning
%% `{cowboy_rest, _, _}` -- which is what Cowboy actually goes on.
-spec is_cowboy_rest([erl_parse:abstract_form()], #{fa() => list()}) -> boolean().
is_cowboy_rest(Forms, Clauses) ->
    Behaviours = [B || {attribute, _, A, B} <- Forms,
                       A =:= behaviour orelse A =:= behavior],
    lists:member(cowboy_rest, Behaviours) orelse
        lists:any(fun is_rest_upgrade/1,
                  return_exprs(clause_list({init, 2}, Clauses))).

is_rest_upgrade({tuple, _, [{atom, _, cowboy_rest} | _]}) -> true;
is_rest_upgrade(_) -> false.

-spec clauses([erl_parse:abstract_form()]) -> #{fa() => list()}.
clauses(Forms) ->
    maps:from_list([{{Name, Arity}, Cs} || {function, _, Name, Arity, Cs} <- Forms]).

clause_list(FA, Clauses) ->
    maps:get(FA, Clauses, []).

%%%_ * Building the resource -------------------------------------------

-spec build(binary(), module(), [erl_parse:abstract_form()], #{fa() => list()}) ->
          resource().
build(Path, Module, Forms, Clauses) ->
    Kind = case is_cowboy_rest(Forms, Clauses) of
               true -> rest;
               false -> plain
           end,
    {Provided, Accepted} = content_types(Kind, Clauses),
    Graph = call_graph(Module, Clauses),
    Facts = facts(Module, Clauses),
    Methods = methods(Kind, Clauses, Graph, Facts),
    PathParams = path_parameters(Path),
    #{ module => Module
     , kind => Kind
     , path => Path
     , type_info => spectra_abstract_code:types_in_forms(Module, Forms)
     , methods => Methods
     , provided => Provided
     , accepted => Accepted
     , doc => doc_attribute(Forms)
     , operations =>
           maps:from_list(
             [ {M, operation(Kind, M, Clauses, Graph, Facts, Provided, Accepted,
                             PathParams)}
               || M <- Methods, lists:member(M, ?DOCUMENTED_METHODS) ])
     }.

%% OpenAPI requires every variable in a path template to be declared as a path
%% parameter on every operation under it, so the template is the authority on
%% what those are. A `cowboy_req:binding/2` call cannot add one the route does
%% not have, and a method that never reads its binding still has it -- a DELETE
%% that ignores the id in `/widgets/{id}` must still declare it.
-spec path_parameters(binary()) -> [param()].
path_parameters(Path) ->
    [ #{name => Name, in => path, required => true, schema => string_type()}
      || Segment <- binary:split(Path, ~"/", [global]),
         {ok, Name} <- [template_variable(Segment)] ].

template_variable(<<"{", Rest/binary>>) ->
    case binary:match(Rest, ~"}") of
        {Length, 1} when Length > 0 -> {ok, binary:part(Rest, 0, Length)};
        _NoneOrEmpty -> error
    end;
template_variable(_Segment) ->
    error.

%% A plain handler negotiates nothing: it writes whatever it writes, and the
%% content type comes from the headers it replies with.
content_types(plain, _Clauses) ->
    {[], []};
content_types(rest, Clauses) ->
    { %% Cowboy's own default when the callback is not implemented.
      content_types(content_types_provided, Clauses,
                    [{{~"text", ~"html", '*'}, to_html}])
    , content_types(content_types_accepted, Clauses, [])
    }.

-spec methods(kind(), #{fa() => list()}, #{fa() => [fa()]}, #{fa() => [fact()]}) ->
          [binary()].
methods(rest, Clauses, _Graph, _Facts) ->
    allowed_methods(Clauses);
methods(plain, _Clauses, Graph, Facts) ->
    %% A plain handler answers every method unless it checks, so the only
    %% honest source is a `cowboy_req:method/1` test it actually performs. With
    %% no test at all, saying `GET` is the least surprising answer -- and the
    %% right one for the liveness/readiness probes this mostly describes.
    case lists:usort([M || FA <- reachable([{init, 2}], Graph),
                           {method, M} <- maps:get(FA, Facts, [])]) of
        [] -> [~"GET"];
        Methods -> Methods
    end.

%% All `-openapi(...)` attributes in the module, merged left to right.
-spec doc_attribute([erl_parse:abstract_form()]) -> map().
doc_attribute(Forms) ->
    lists:foldl(fun(M, Acc) -> maps:merge(Acc, M) end, #{},
                [M || {attribute, _, openapi, M} <- Forms, is_map(M)]).

-spec allowed_methods(#{fa() => list()}) -> [binary()].
allowed_methods(Clauses) ->
    case returned_literal({allowed_methods, 2}, Clauses) of
        {value, Methods} when is_list(Methods) ->
            [M || M <- Methods, is_binary(M)];
        _ ->
            %% Cowboy's default.
            [~"GET", ~"HEAD", ~"OPTIONS"]
    end.

-spec content_types(atom(), #{fa() => list()}, [{content_type(), atom()}]) ->
          [{content_type(), atom()}].
content_types(Callback, Clauses, Default) ->
    case returned_literal({Callback, 2}, Clauses) of
        {value, List} when is_list(List) ->
            case lists:filtermap(fun normalize_content_type/1, List) of
                [] -> Default;
                CTs -> CTs
            end;
        _ ->
            Default
    end.

normalize_content_type({{Type, Sub, Params}, Fun})
  when is_binary(Type), is_binary(Sub), is_atom(Fun) ->
    {true, {{Type, Sub, Params}, Fun}};
%% Cowboy also accepts the <<"text/xml">> shorthand.
normalize_content_type({Bin, Fun}) when is_binary(Bin), is_atom(Fun) ->
    {true, {parse_content_type(Bin), Fun}};
normalize_content_type(_) ->
    false.

parse_content_type(Bin) ->
    [Full | _Params] = binary:split(Bin, ~";"),
    case binary:split(string:trim(Full), ~"/") of
        [Type, Sub] -> {Type, Sub, '*'};
        _ -> {~"application", ~"octet-stream", '*'}
    end.

%%%_ * Per-method assembly ---------------------------------------------

-spec operation(kind(), binary(), #{fa() => list()}, #{fa() => [fa()]},
                #{fa() => [fact()]}, [{content_type(), atom()}],
                [{content_type(), atom()}], [param()]) -> operation().
operation(Kind, Method, Clauses, Graph, Facts, Provided, Accepted, PathParams) ->
    Reachable = reachable(roots(Kind, Method, Clauses, Provided, Accepted), Graph),
    Fs = lists:append([maps:get(FA, Facts, []) || FA <- Reachable]),
    Replies = drop_method_not_allowed(Kind, Fs,
                                      index_replies([R || {reply, R} <- Fs])),
    #{ method => Method
     , callback => method_callback(Kind, Method, Provided, Accepted)
     , parameters =>
           sort_params(dedup_params(PathParams ++ [P || {param, P} <- Fs]))
     , replies => Replies
     , implied => implied_statuses(Kind, Method,
                                   accept_facts(Kind, Method, Accepted, Graph,
                                                Facts))
     , auth => lists:member(auth, Fs) orelse
               requires_auth(Clauses) orelse
               maps:is_key(401, Replies)
     , request_body => lists:member(reads_body, Fs)
     }.

%% A plain handler's facts are not split by method -- there is one `init/2` and
%% no way to tell one method's code from another's. That is harmless except for
%% 405, which by construction belongs to the branch handling the methods the
%% handler does *not* serve, and so can never answer one it does.
drop_method_not_allowed(plain, Fs, Replies) ->
    case [M || {method, M} <- Fs] of
        [] -> Replies;
        _Tested -> maps:remove(405, Replies)
    end;
drop_method_not_allowed(rest, _Fs, Replies) ->
    Replies.

%% The functions Cowboy may call while serving `Method`. A plain handler has
%% exactly one entry point, and no way to tell one method's code from another's,
%% so every method sees the same facts.
-spec roots(kind(), binary(), #{fa() => list()}, [{content_type(), atom()}],
            [{content_type(), atom()}]) -> [fa()].
roots(plain, _Method, _Clauses, _Provided, _Accepted) ->
    [{init, 2}];
roots(rest, Method, Clauses, Provided, Accepted) ->
    Candidates =
        [{F, 2} || F <- ?GENERIC_CALLBACKS] ++
        method_roots(Method, Provided, Accepted),
    [FA || FA <- Candidates, maps:is_key(FA, Clauses)].

method_roots(Method, Provided, _Accepted)
  when Method =:= ~"GET"; Method =:= ~"HEAD" ->
    [{F, 2} || {_CT, F} <- Provided];
method_roots(Method, _Provided, Accepted)
  when Method =:= ~"POST"; Method =:= ~"PUT"; Method =:= ~"PATCH" ->
    [{F, 2} || {_CT, F} <- Accepted];
method_roots(~"DELETE", _Provided, _Accepted) ->
    [{delete_resource, 2}, {delete_completed, 2}];
method_roots(~"OPTIONS", _Provided, _Accepted) ->
    [{options, 2}];
method_roots(_Method, _Provided, _Accepted) ->
    [].

method_callback(rest, Method, Provided, _Accepted)
  when Method =:= ~"GET"; Method =:= ~"HEAD" ->
    first_callback(Provided);
method_callback(rest, Method, _Provided, Accepted)
  when Method =:= ~"POST"; Method =:= ~"PUT"; Method =:= ~"PATCH" ->
    first_callback(Accepted);
method_callback(_Kind, _Method, _Provided, _Accepted) ->
    undefined.

first_callback([{_CT, Fun} | _]) -> Fun;
first_callback([]) -> undefined.

%% A resource that can answer 401 has something authenticating it, even when
%% that something lives in another module and is therefore invisible here --
%% which is how the shared-secret job endpoints are recognised.
%%
%% Implementing `is_authorized/2` is not by itself a sign that the resource is
%% authenticated -- `{true, Req, State}` in every clause is how a resource opts
%% *out* while still declaring the callback, which is what
%% `prometheus`-style metrics endpoints do. Anything less certain than
%% "cannot answer other than `true`" counts as authenticated.
-spec requires_auth(#{fa() => list()}) -> boolean().
requires_auth(Clauses) ->
    case clause_list({is_authorized, 2}, Clauses) of
        [] -> false;
        ClauseList -> not lists:all(fun always_authorized/1, return_exprs(ClauseList))
    end.

always_authorized({tuple, _, [{atom, _, true}, _Req, _State]}) -> true;
always_authorized(_Expr) -> false.

%% The facts reachable from the method's accept callback alone. The success
%% status of a write method comes from what *that callback* returns -- the
%% generic callbacks return `{true | false, Req, State}` tuples of their own
%% (`resource_exists`, `forbidden`, `allow_missing_post`, ...), and reading
%% those as accept results would invent statuses the method can never answer.
-spec accept_facts(kind(), binary(), [{content_type(), atom()}],
                   #{fa() => [fa()]}, #{fa() => [fact()]}) -> [fact()].
accept_facts(rest, Method, Accepted, Graph, Facts)
  when Method =:= ~"POST"; Method =:= ~"PUT"; Method =:= ~"PATCH" ->
    Roots = [{F, 2} || {_CT, F} <- Accepted],
    lists:append([maps:get(FA, Facts, []) || FA <- reachable(Roots, Graph)]);
accept_facts(_Kind, _Method, _Accepted, _Graph, _Facts) ->
    [].

%% Statuses `cowboy_rest` derives from the handler's return value, as opposed to
%% the ones the handler replies with itself.
-spec implied_statuses(kind(), binary(), [fact()]) -> [100..599].
%% Nothing is implied for a plain handler: there is no `cowboy_rest` state
%% machine deriving a status from a callback's return value, only the replies
%% the handler makes itself.
implied_statuses(plain, _Method, _Fs) ->
    [];
implied_statuses(rest, Method, _Fs) when Method =:= ~"GET";
                                         Method =:= ~"HEAD";
                                         Method =:= ~"OPTIONS" ->
    [200];
implied_statuses(rest, ~"DELETE", _Fs) ->
    [204];
implied_statuses(rest, Method, Fs) when Method =:= ~"POST";
                                        Method =:= ~"PUT";
                                        Method =:= ~"PATCH" ->
    case lists:usort([accept_status(R) || {accept_result, R} <- Fs]) of
        [] -> [204];
        Statuses -> Statuses
    end;
implied_statuses(rest, _Method, _Fs) ->
    [].

accept_status(true) -> 204;
accept_status(false) -> 400;
accept_status(created) -> 201;
accept_status(see_other) -> 303.

-spec dedup_params([param()]) -> [param()].
dedup_params(Params) ->
    dedup_params(Params, [], []).

dedup_params([], _Seen, Acc) ->
    lists:reverse(Acc);
dedup_params([#{in := In, name := Name} = P | Rest], Seen, Acc) ->
    case lists:member({In, Name}, Seen) of
        true -> dedup_params(Rest, Seen, Acc);
        false -> dedup_params(Rest, [{In, Name} | Seen], [P | Acc])
    end.

%% Deterministic order, so the generated document is stable across runs.
sort_params(Params) ->
    lists:sort(fun(#{in := IA, name := NA}, #{in := IB, name := NB}) ->
                       {location_order(IA), NA} =< {location_order(IB), NB}
               end, Params).

location_order(path) -> 0;
location_order(query) -> 1;
location_order(header) -> 2;
location_order(cookie) -> 3.

-spec index_replies([reply()]) -> #{100..599 => reply()}.
index_replies(Replies) ->
    lists:foldl(fun(#{status := S} = R, Acc) ->
                        maps:update_with(S, fun(Old) -> merge_reply(Old, R) end,
                                         R, Acc)
                end, #{}, Replies).

%% Same status replied from two places: keep the first reply's fields and fill
%% in whatever it lacked, but keep both body texts -- they are the descriptions.
merge_reply(Old, New) ->
    Merged = maps:merge(New, Old),
    case {maps:get(body_text, Old, undefined), maps:get(body_text, New, undefined)} of
        {A, B} when is_binary(A), is_binary(B), A =/= B ->
            Merged#{body_text => <<A/binary, " / ", B/binary>>};
        _ ->
            Merged
    end.

%%%_ * Local call graph ------------------------------------------------

-spec call_graph(module(), #{fa() => list()}) -> #{fa() => [fa()]}.
call_graph(Module, Clauses) ->
    maps:map(fun(_FA, Cs) ->
                     ordsets:from_list(
                       fold_forms(fun(T, Acc) -> local_call(Module, T, Acc) end,
                                  [], Cs))
             end, Clauses).

local_call(_Module, {call, _, {atom, _, F}, Args}, Acc) ->
    [{F, length(Args)} | Acc];
local_call(Module, {call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args}, Acc)
  when M =:= Module ->
    [{F, length(Args)} | Acc];
local_call(_Module, {'fun', _, {function, F, A}}, Acc) ->
    [{F, A} | Acc];
local_call(_Module, _Form, Acc) ->
    Acc.

-spec reachable([fa()], #{fa() => [fa()]}) -> [fa()].
reachable(Roots, Graph) ->
    reachable(ordsets:from_list(Roots), Graph, ordsets:new()).

reachable([], _Graph, Seen) ->
    Seen;
reachable([FA | Rest], Graph, Seen) ->
    case ordsets:is_element(FA, Seen) of
        true ->
            reachable(Rest, Graph, Seen);
        false ->
            Callees = ordsets:from_list(maps:get(FA, Graph, [])),
            reachable(ordsets:union(Callees, Rest), Graph,
                      ordsets:add_element(FA, Seen))
    end.

%%%_ * Fact extraction -------------------------------------------------

-spec facts(module(), #{fa() => list()}) -> #{fa() => [fact()]}.
facts(Module, Clauses) ->
    CallArguments = call_arguments(Module, Clauses),
    maps:map(fun(FA, ClauseList) ->
                     resolve_facts(function_facts(FA, ClauseList, Clauses),
                                   CallArguments)
             end, Clauses).

function_facts(FA, ClauseList, Clauses) ->
    lists:append([clause_facts(FA, C, Clauses) || C <- ClauseList]) ++
        return_facts(ClauseList).

%% Facts are gathered a clause at a time so that a variable in the body can be
%% traced back to the argument it came from -- which is what makes a local
%% `reply(Status, ...)` wrapper readable.
clause_facts(FA, {clause, _, Patterns, _Guards, Body}, Clauses) ->
    Ctx = #{fa => FA, params => clause_params(Patterns), clauses => Clauses},
    lists:reverse(
      fold_forms(fun(T, Acc) -> lists:reverse(call_fact(Ctx, T)) ++ Acc end,
                 [], Body)).

%% #{VarName => ArgumentIndex} for arguments matched by a plain variable.
clause_params(Patterns) ->
    maps:from_list([{Name, Index}
                    || {{var, _, Name}, Index}
                           <- lists:zip(Patterns, lists:seq(1, length(Patterns))),
                       Name =/= '_']).

-type ctx() :: #{fa := fa(), params := #{atom() => pos_integer()},
                 clauses := #{fa() => list()}}.

-spec call_fact(ctx(), tuple()) -> [fact()].
call_fact(Ctx, {call, _, ?cowboy_req(reply), Args}) ->
    reply_fact(Ctx, Args);
call_fact(Ctx, {call, _, ?cowboy_req(match_qs), [ListForm, _Req]}) ->
    match_params(query, ListForm, clauses_of(Ctx));
call_fact(Ctx, {call, _, ?cowboy_req(match_cookies), [ListForm, _Req]}) ->
    match_params(cookie, ListForm, clauses_of(Ctx));
call_fact(_Ctx, {call, _, ?cowboy_req(header), [NameForm | _]}) ->
    header_fact(NameForm);
call_fact(_Ctx, {call, _, ?cowboy_req(Read), _Args})
  when Read =:= read_body;
       Read =:= read_urlencoded_body;
       Read =:= read_and_match_urlencoded_body ->
    [reads_body];
%% A plain handler answers every method unless it looks; when it does look, the
%% literals it compares against are the methods it serves.
call_fact(_Ctx, {'case', _, {call, _, ?cowboy_req(method), _Args}, ClauseList}) ->
    [{method, M} || C <- ClauseList, {ok, M} <- [case_pattern_method(C)]];
call_fact(_Ctx, {op, _, Comparison, {call, _, ?cowboy_req(method), _}, Form})
  when Comparison =:= '=:='; Comparison =:= '==' ->
    method_fact(Form);
call_fact(_Ctx, {op, _, Comparison, Form, {call, _, ?cowboy_req(method), _}})
  when Comparison =:= '=:='; Comparison =:= '==' ->
    method_fact(Form);
call_fact(_Ctx, _Form) ->
    [].

clauses_of(#{clauses := Clauses}) -> Clauses.

case_pattern_method({clause, _, [Pattern], _Guards, _Body}) ->
    method_literal(Pattern);
case_pattern_method(_Clause) ->
    error.

method_fact(Form) ->
    case method_literal(Form) of
        {ok, Method} -> [{method, Method}];
        error -> []
    end.

method_literal(Form) ->
    case literal(Form) of
        {value, Method} when is_binary(Method), Method =/= ~"" -> {ok, Method};
        _ -> error
    end.

%% Second pass: a reply whose status was the enclosing function's Nth argument
%% becomes one reply per literal status passed at that position, anywhere in the
%% module. This is what makes a `reply(202, ...)` / `reply(409, ...)` wrapper --
%% the usual shape of a plain handler -- say anything at all.
resolve_facts(Facts, CallArguments) ->
    lists:append([resolve_fact(F, CallArguments) || F <- Facts]).

resolve_fact({reply_arg, FA, Index, Partial}, CallArguments) ->
    [{reply, Partial#{status => Status}}
     || Status <- literal_arguments_at(maps:get(FA, CallArguments, []), Index),
        is_status(Status)];
resolve_fact(Fact, _CallArguments) ->
    [Fact].

literal_arguments_at(ArgumentLists, Index) ->
    lists:usort([V || Arguments <- ArgumentLists, length(Arguments) >= Index,
                      {value, V} <- [literal(lists:nth(Index, Arguments))]]).

%% Every argument list passed to each locally called function, module-wide.
-spec call_arguments(module(), #{fa() => list()}) -> #{fa() => [[tuple()]]}.
call_arguments(Module, Clauses) ->
    fold_forms(fun(T, Acc) -> call_argument(Module, T, Acc) end, #{},
               maps:values(Clauses)).

call_argument(_Module, {call, _, {atom, _, F}, Args}, Acc) ->
    add_call_arguments({F, length(Args)}, Args, Acc);
call_argument(Module, {call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args}, Acc)
  when M =:= Module ->
    add_call_arguments({F, length(Args)}, Args, Acc);
call_argument(_Module, _Form, Acc) ->
    Acc.

add_call_arguments(FA, Args, Acc) ->
    maps:update_with(FA, fun(Lists) -> [Args | Lists] end, [Args], Acc).

%% Facts that depend on *where* an expression sits: the accept callback's
%% status comes from what the handler returns, not from what it calls.
return_facts(Cs) ->
    [{accept_result, R} || E <- return_exprs(Cs), {ok, R} <- [accept_result(E)]].

accept_result({tuple, _, [{atom, _, V}, _Req, _State]})
  when V =:= true; V =:= false ->
    {ok, V};
accept_result({tuple, _, [{tuple, _, [{atom, _, V}, _URI]}, _Req, _State]})
  when V =:= created; V =:= see_other ->
    {ok, V};
accept_result(_Form) ->
    error.

%%%_ * cowboy_req:reply/2,3,4 ------------------------------------------

reply_fact(Ctx, [StatusForm, _Req]) ->
    reply_fact(Ctx, StatusForm, undefined, undefined);
reply_fact(Ctx, [StatusForm, HeadersForm, _Req]) ->
    reply_fact(Ctx, StatusForm, HeadersForm, undefined);
reply_fact(Ctx, [StatusForm, HeadersForm, BodyForm, _Req]) ->
    reply_fact(Ctx, StatusForm, HeadersForm, BodyForm);
reply_fact(_Ctx, _Args) ->
    [].

reply_fact(Ctx, StatusForm, HeadersForm, BodyForm) ->
    Partial = with_body_text(with_content_type(#{}, HeadersForm, Ctx), BodyForm),
    case literal(StatusForm) of
        {value, Status} ->
            [{reply, Partial#{status => Status}} || is_status(Status)];
        undefined ->
            %% Not a literal. If it is one of this function's arguments, its
            %% call sites may still say -- see resolve_facts/2.
            [{reply_arg, maps:get(fa, Ctx), Index, Partial}
             || {ok, Index} <- [param_index(StatusForm, Ctx)]]
    end.

is_status(Status) ->
    is_integer(Status) andalso Status >= 100 andalso Status =< 599.

param_index({var, _, Name}, #{params := Params}) ->
    maps:find(Name, Params);
param_index(_Form, _Ctx) ->
    error.

with_content_type(Reply, undefined, _Ctx) ->
    Reply;
with_content_type(Reply, HeadersForm, Ctx) ->
    case literal_or_local(HeadersForm, Ctx) of
        {value, Headers} when is_map(Headers) ->
            case maps:get(~"content-type", Headers, undefined) of
                CT when is_binary(CT) -> Reply#{content_type => CT};
                _ -> Reply
            end;
        _ ->
            Reply
    end.

%% Headers are routinely built by a local `headers(Status)` helper, so a
%% non-literal headers argument gets one level of indirection: the first literal
%% among the helper's return expressions. Only used for the content type, where
%% picking the wrong branch of a helper costs little. The reply body is not
%% resolved this way -- a stray literal there would become a response
%% description, and a wrong description is worse than none.
literal_or_local(Form, Ctx) ->
    case literal(Form) of
        {value, _} = Value -> Value;
        undefined -> local_call_literal(Form, Ctx)
    end.

local_call_literal({call, _, {atom, _, F}, Args}, #{clauses := Clauses}) ->
    first_literal(return_exprs(clause_list({F, length(Args)}, Clauses)));
local_call_literal(_Form, _Ctx) ->
    undefined.

with_body_text(Reply, undefined) ->
    Reply;
with_body_text(Reply, BodyForm) ->
    case literal(BodyForm) of
        {value, Body} -> maybe_body_text(Reply, Body);
        undefined -> Reply
    end.

maybe_body_text(Reply, Body) when is_binary(Body), Body =/= ~"" ->
    Reply#{body_text => Body};
maybe_body_text(Reply, Body) when is_list(Body) ->
    case io_lib:printable_unicode_list(Body) andalso Body =/= [] of
        true -> Reply#{body_text => unicode:characters_to_binary(Body)};
        false -> Reply
    end;
maybe_body_text(Reply, _Body) ->
    Reply.

%%%_ * Parameters ------------------------------------------------------

%% cowboy_req:match_qs/2 and match_cookies/2 share the constraint syntax:
%%     Name | {Name, Constraints} | {Name, Constraints, Default}
-spec match_params(location(), tuple(), #{fa() => list()}) -> [fact()].
match_params(In, ListForm, Clauses) ->
    [{param, P} || Form <- list_elements(ListForm),
                   {ok, P} <- [match_param(In, Form, Clauses)]].

match_param(In, {atom, _, Name}, _Clauses) ->
    {ok, param(In, Name, true, string_type())};
match_param(In, {tuple, _, [{atom, _, Name}, Constraints]}, Clauses) ->
    {ok, param(In, Name, true, constraint_type(Constraints, Clauses))};
match_param(In, {tuple, _, [{atom, _, Name}, Constraints, DefaultForm]}, Clauses) ->
    P = param(In, Name, false, constraint_type(Constraints, Clauses)),
    case literal(DefaultForm) of
        {value, Default} -> {ok, P#{default => Default}};
        undefined -> {ok, P}
    end;
match_param(_In, _Form, _Clauses) ->
    error.

param(In, Name, Required, Schema) ->
    #{ name => atom_to_binary(Name, utf8)
     , in => In
     , required => Required
     , schema => Schema
     }.

header_fact(NameForm) ->
    case literal(NameForm) of
        {value, Name} when is_binary(Name) ->
            header_fact_for(string:lowercase(Name));
        _ ->
            []
    end.

header_fact_for(~"authorization") ->
    [auth];
header_fact_for(Name) ->
    case lists:member(Name, ?PROTOCOL_HEADERS) of
        true ->
            [];
        false ->
            %% cowboy_req:header/2 answers `undefined` for a missing header, so
            %% reading one never makes it required on its own.
            [{param, #{ name => Name
                      , in => header
                      , required => false
                      , schema => string_type()
                      }}]
    end.

%%%_ * Constraints to types --------------------------------------------

%% Cowboy constraints are a single constraint or a list of them. Pick the first
%% one that says something about the type; anything else means "a string".
constraint_type(Form, Clauses) ->
    Types = [T || C <- constraint_forms(Form),
                  {ok, T} <- [constraint_to_type(C, Clauses)]],
    case Types of
        [Type | _] -> Type;
        [] -> string_type()
    end.

constraint_forms({cons, _, _, _} = List) -> list_elements(List);
constraint_forms({nil, _}) -> [];
constraint_forms(Single) -> [Single].

constraint_to_type({atom, _, int}, _Clauses) ->
    {ok, #sp_simple_type{type = integer}};
constraint_to_type({atom, _, nonempty}, _Clauses) ->
    {ok, #sp_simple_type{type = nonempty_binary}};
constraint_to_type({'fun', _, {function, Fun, 2}}, Clauses) ->
    fun_constraint_type(Fun, Clauses);
constraint_to_type(_Form, _Clauses) ->
    error.

%% A custom constraint fun is a `forward`/`reverse`/`format_error` dispatcher.
%% Its `forward` clauses say what values the parameter can take, so
%%     id_user_constraint(forward, <<"true">>)  -> {ok, true};
%%     id_user_constraint(forward, <<"false">>) -> {ok, false};
%%     id_user_constraint(forward, _)           -> {error, not_boolean};
%% is a boolean.
fun_constraint_type(Fun, Clauses) ->
    Values = forward_values(clause_list({Fun, 2}, Clauses)),
    case lists:usort(Values) of
        [] -> error;
        [false, true] -> {ok, #sp_simple_type{type = boolean}};
        Sorted -> literal_union(Sorted)
    end.

forward_values(ClauseList) ->
    lists:append([forward_clause_values(C) || C <- ClauseList]).

forward_clause_values({clause, _, [{atom, _, forward}, _Value], _Guards, Body}) ->
    [V || E <- tail_exprs(lists:last(Body)), {ok, V} <- [ok_value(E)]];
forward_clause_values(_Clause) ->
    [].

ok_value({tuple, _, [{atom, _, ok}, ValueForm]}) ->
    case literal(ValueForm) of
        {value, V} -> {ok, V};
        undefined -> error
    end;
ok_value(_Form) ->
    error.

%% spectra literals are atoms and integers; anything else we cannot express.
literal_union(Values) ->
    case lists:all(fun(V) -> is_atom(V) orelse is_integer(V) end, Values) of
        false ->
            error;
        true ->
            {ok, #sp_union{types = [#sp_literal{ value = V
                                               , binary_value = value_to_binary(V)
                                               } || V <- Values]}}
    end.

value_to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
value_to_binary(V) when is_integer(V) -> integer_to_binary(V).

string_type() ->
    #sp_simple_type{type = binary}.

%%%_ * Abstract form helpers -------------------------------------------

%% The first element of the first `{X, Req, State}` tuple that `FA` returns and
%% that is a literal -- which is how `allowed_methods/2` and friends are read.
-spec returned_literal(fa(), #{fa() => list()}) -> undefined | {value, term()}.
returned_literal(FA, Clauses) ->
    first_literal([First || {tuple, _, [First, _Req, _State]} <-
                                return_exprs(clause_list(FA, Clauses))]).

first_literal([]) ->
    undefined;
first_literal([Form | Rest]) ->
    case literal(Form) of
        {value, _} = V -> V;
        undefined -> first_literal(Rest)
    end.

%% Expressions in return position, following `case`/`if`/`try`/`maybe` branches.
%%
%% A tail call taking an anonymous function also yields that function's return
%% expressions: the `ot:with_span(Name, fun(_) -> ... end)` wrapper is a tail
%% call whose value is the fun's value, and the same holds for every
%% wrapper of that shape.
-spec return_exprs(list()) -> [tuple()].
return_exprs(ClauseList) ->
    lists:append([tail_exprs(lists:last(Body))
                  || {clause, _, _Pat, _Guards, Body} <- ClauseList, Body =/= []]).

body_exprs([]) -> [];
body_exprs(Body) -> tail_exprs(lists:last(Body)).

tail_exprs({'case', _, _Subject, Cs}) ->
    return_exprs(Cs);
tail_exprs({'if', _, Cs}) ->
    return_exprs(Cs);
tail_exprs({'receive', _, Cs}) ->
    return_exprs(Cs);
tail_exprs({'receive', _, Cs, _Timeout, After}) ->
    return_exprs(Cs) ++ body_exprs(After);
tail_exprs({'try', _, Body, Cs, CatchCs, _After}) ->
    case Cs of
        [] -> body_exprs(Body);
        _ -> return_exprs(Cs)
    end ++ return_exprs(CatchCs);
tail_exprs({block, _, Body}) ->
    body_exprs(Body);
tail_exprs({'maybe', _, Body}) ->
    body_exprs(Body);
tail_exprs({'maybe', _, Body, {'else', _, Cs}}) ->
    body_exprs(Body) ++ return_exprs(Cs);
tail_exprs({'fun', _, {clauses, Cs}}) ->
    return_exprs(Cs);
tail_exprs({call, _, _Fun, Args} = Call) ->
    [Call | lists:append([return_exprs(Cs)
                          || {'fun', _, {clauses, Cs}} <- Args])];
tail_exprs(Expr) ->
    [Expr].

list_elements({cons, _, Head, Tail}) -> [Head | list_elements(Tail)];
list_elements({nil, _}) -> [];
%% Not a literal list -- an improper tail, a variable, a comprehension.
list_elements(_Form) -> [].

%% Constant folding of abstract forms. Only constants fold: a form containing a
%% variable or a call is `undefined`, never evaluated, so analysing a module can
%% never run any of its code.
-spec literal(term()) -> undefined | {value, term()}.
literal({atom, _, V}) -> {value, V};
literal({integer, _, V}) -> {value, V};
literal({char, _, V}) -> {value, V};
literal({float, _, V}) -> {value, V};
literal({string, _, V}) -> {value, V};
literal({nil, _}) -> {value, []};
literal({cons, _, _, _} = List) ->
    literal_list(list_elements(List), fun(Vs) -> Vs end);
literal({tuple, _, Elements}) ->
    literal_list(Elements, fun erlang:list_to_tuple/1);
literal({bin, _, Segments}) ->
    literal_bin(Segments);
literal({map, _, Assocs}) ->
    literal_map(Assocs);
literal({op, _, Op, Arg}) ->
    literal_op(Op, [Arg]);
literal({op, _, Op, Left, Right}) ->
    literal_op(Op, [Left, Right]);
literal(_Form) ->
    undefined.

literal_list(Forms, Wrap) ->
    Values = [literal(F) || F <- Forms],
    case lists:member(undefined, Values) of
        true -> undefined;
        false -> {value, Wrap([V || {value, V} <- Values])}
    end.

literal_bin(Segments) ->
    Parts = [literal_bin_segment(S) || S <- Segments],
    case lists:member(undefined, Parts) of
        true ->
            undefined;
        false ->
            try {value, iolist_to_binary([P || {value, P} <- Parts])}
            catch _:_ -> undefined
            end
    end.

%% Only the plain `<<"literal">>` and `<<$c>>` shapes; a segment with a size or
%% a type specifier is not something we need to understand.
literal_bin_segment({bin_element, _, Form, default, default}) ->
    literal(Form);
literal_bin_segment({bin_element, _, Form, default, [utf8]}) ->
    literal(Form);
literal_bin_segment(_Segment) ->
    undefined.

literal_map(Assocs) ->
    Pairs = [literal_map_assoc(A) || A <- Assocs],
    case lists:member(undefined, Pairs) of
        true -> undefined;
        false -> {value, maps:from_list([KV || {value, KV} <- Pairs])}
    end.

literal_map_assoc({map_field_assoc, _, KeyForm, ValueForm}) ->
    case {literal(KeyForm), literal(ValueForm)} of
        {{value, K}, {value, V}} -> {value, {K, V}};
        _ -> undefined
    end;
literal_map_assoc(_Assoc) ->
    undefined.

%% Arithmetic on constants, so a status written as `?BASE + 4` still folds.
%% The operator is matched, not applied by name, so nothing outside this list
%% can be reached however the form was built.
literal_op(Op, ArgForms) ->
    case literal_list(ArgForms, fun(Vs) -> Vs end) of
        {value, Args} ->
            case lists:all(fun erlang:is_number/1, Args) of
                true -> arith(Op, Args);
                false -> undefined
            end;
        undefined ->
            undefined
    end.

arith('+', [A]) -> {value, A};
arith('-', [A]) -> {value, -A};
arith('+', [A, B]) -> {value, A + B};
arith('-', [A, B]) -> {value, A - B};
arith('*', [A, B]) -> {value, A * B};
arith('div', [A, B]) when is_integer(A), is_integer(B), B =/= 0 -> {value, A div B};
arith('rem', [A, B]) when is_integer(A), is_integer(B), B =/= 0 -> {value, A rem B};
arith('/', [A, B]) when B =/= 0 -> {value, A / B};
arith(_Op, _Args) -> undefined.

%% Depth-first fold over every tuple in a nested form structure.
-spec fold_forms(fun((tuple(), Acc) -> Acc), Acc, term()) -> Acc.
fold_forms(Fun, Acc, Term) when is_tuple(Term) ->
    fold_forms(Fun, Fun(Term, Acc), tuple_to_list(Term));
fold_forms(Fun, Acc, [Head | Tail]) ->
    fold_forms(Fun, fold_forms(Fun, Acc, Head), Tail);
fold_forms(_Fun, Acc, _Other) ->
    Acc.
