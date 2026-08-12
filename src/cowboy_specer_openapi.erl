-module(cowboy_specer_openapi).
-moduledoc """
Turns the resources found by `cowboy_specer_scan` into an OpenAPI 3.1
document, using `spectra_openapi` to do the actual assembly and JSON Schema
generation.

This module owns the two things the scanner deliberately does not: where the
prose comes from, and where the body *types* come from.

## Prose

Per operation, in order of precedence:

1. the `-openapi(#{get => #{summary => ...}})` attribute for that method;
2. the `-spectra(#{summary => ...})` attribute on the method's provide/accept
   callback (spectra attaches it to the callback's `-spec`);
3. the resource-level `-openapi(#{summary => ...})` attribute.

## Body types

The 200's schema comes from the provide callback's `-spec`: the first element of
any returned 3-tuple that is not a `cowboy_rest` control atom (`stop`, `true`,
`{created, _}`, ...) is the body's type.

    -spec to_xml(cowboy_req:req(), State) ->
              {person_xml(), cowboy_req:req(), State}
            | {stop, cowboy_req:req(), State}.

That reaches as far as the callback's return type is honest, which is as far as
the body is already a binary -- XML, plain text. A callback that *encodes* can
only say `iodata()`, so a structured format declares its schema in
`-openapi(#{get => #{responses => #{200 => #{schema => ...}}}})` instead.

Only 200 is given this schema: `cowboy_rest` sends no body with the statuses it
derives from a write callback's return.

Request bodies cannot be inferred at all -- `cowboy_rest` hands the accept
callback a `Req`, not a decoded body -- so they come from
`-openapi(#{post => #{request_body => #{schema => ...}}})`.

Statuses replied to with a literal binary body get that binary as their
description and `string` as their schema, which is exactly right for the
`cowboy_req:reply(400, _, <<"Invalid SSN format">>, Req)` idiom.
""".

-export([ generate/2
        , generate/3
        , endpoints/2
        ]).

-include_lib("spectra/include/spectra_internal.hrl").

-type options() ::
        #{ %% Also document the statuses cowboy_rest produces on its own during
           %% content negotiation (406, 415). Default `true`.
           implicit_responses => boolean()
         , %% Name of the generated bearer security scheme. Default
           %% `<<"bearerAuth">>`.
           security_scheme_name => binary()
         }.

%% A `cowboy_specer_scan:operation()` with the method's `-openapi(...)`
%% overrides added under `attr`, so every step of the assembly can reach them
%% without also being handed the resource.
-type op() :: #{ method := binary()
               , callback := atom() | undefined
               , parameters := [cowboy_specer_scan:param()]
               , replies := #{100..599 => cowboy_specer_scan:reply()}
               , implied := [100..599]
               , auth := boolean()
               , request_body := boolean()
               , attr := map()
               }.

-export_type([options/0]).

-define(BEARER_NOTE,
        ~"Requires a bearer token in the `Authorization` header.").

%% Values `cowboy_rest` gives its own meaning to when a callback returns them,
%% and which are therefore never a response body.
-define(CONTROL_VALUES,
        [stop, true, false, created, see_other, switch_handler]).

%%%_ * API -------------------------------------------------------------

-doc "Equivalent to `generate(MetaData, Resources, #{})`.".
-spec generate(spectra_openapi:openapi_metadata(),
               [cowboy_specer_scan:resource()]) ->
          {ok, iodata()} | {error, [spectra:error()]}.
generate(MetaData, Resources) ->
    generate(MetaData, Resources, #{}).

-doc """
Generates the OpenAPI 3.1 document for `Resources`.

`MetaData` is passed through to `spectra_openapi:endpoints_to_openapi/2` and
must at least carry `title` and `version`. Any key it already has wins over
what this module would add, so a caller that wants to describe its own security
schemes can.
""".
-spec generate(spectra_openapi:openapi_metadata(),
               [cowboy_specer_scan:resource()], options()) ->
          {ok, iodata()} | {error, [spectra:error()]}.
generate(MetaData, Resources, Opts) ->
    Endpoints = lists:append([endpoints(R, Opts) || R <- Resources]),
    spectra_openapi:endpoints_to_openapi(
      with_security(MetaData, Resources, Opts), Endpoints).

-doc "The `spectra_openapi` endpoint specs for one resource, one per method.".
-spec endpoints(cowboy_specer_scan:resource(), options()) ->
          [spectra_openapi:endpoint_spec()].
endpoints(#{operations := Operations} = Resource, Opts) ->
    [endpoint(Resource, Op, Opts)
     || {_Method, Op} <- lists:sort(maps:to_list(Operations))].

%%%_ * One endpoint ----------------------------------------------------

endpoint(Resource, #{method := Method} = Op0, Opts) ->
    #{module := Module, path := Path} = Resource,
    Op = Op0#{attr => method_attr(Resource, Method)},
    Endpoint0 = spectra_openapi:endpoint(method_atom(Method), Path,
                                        doc(Resource, Op)),
    Endpoint1 = add_parameters(Endpoint0, Module, Op),
    Endpoint2 = add_request_body(Endpoint1, Resource, Op),
    add_responses(Endpoint2, Resource, Op, Opts).

method_atom(~"GET") -> get;
method_atom(~"HEAD") -> head;
method_atom(~"POST") -> post;
method_atom(~"PUT") -> put;
method_atom(~"PATCH") -> patch;
method_atom(~"DELETE") -> delete;
method_atom(~"OPTIONS") -> options.

%%%_ * Documentation ---------------------------------------------------

-spec doc(cowboy_specer_scan:resource(), op()) -> spectra_openapi:endpoint_doc().
doc(Resource, #{auth := Auth} = Op) ->
    Attr = method_attr_of(Op),
    Spec = callback_doc(Resource, Op),
    Resourcewide = maps:with([summary, description, tags], resource_attr(Resource)),
    Doc = maps:merge(maps:merge(Resourcewide, Spec),
                     maps:with([summary, description, operationId, tags, deprecated,
                                externalDocs], Attr)),
    with_auth_note(Doc, Auth).

%% The `-spectra(...)` attribute on the provide/accept callback, which spectra
%% has already parsed into the callback spec's meta.
callback_doc(_Resource, #{callback := undefined}) ->
    #{};
callback_doc(#{type_info := TypeInfo}, #{callback := Callback}) ->
    case spectra_type_info:find_function(TypeInfo, Callback, 2) of
        {ok, [#sp_function_spec{meta = #{doc := Doc}} | _]} ->
            maps:with([summary, description, deprecated], Doc);
        _ ->
            #{}
    end.

%% Per-operation security is not expressible in spectra's endpoint spec, so an
%% operation that needs a token says so in its description instead. Harmless
%% when the whole document already requires one; essential when it does not.
with_auth_note(Doc, false) ->
    Doc;
with_auth_note(Doc, true) ->
    case maps:get(description, Doc, undefined) of
        undefined -> Doc#{description => ?BEARER_NOTE};
        Existing -> Doc#{description => <<Existing/binary, "\n\n", ?BEARER_NOTE/binary>>}
    end.

resource_attr(#{doc := Attr}) ->
    Attr.

method_attr(#{doc := Attr}, Method) ->
    case maps:get(method_atom(Method), Attr, #{}) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.

%%%_ * Parameters ------------------------------------------------------

%% Scanned parameters are rendered with the override entry that speaks for
%% them; declared parameters carry the entry they were born from, so a
%% name-wide entry can never leak onto a declared parameter whose identity it
%% does not share.
add_parameters(Endpoint, Module, #{parameters := Params} = Op) ->
    Overrides = maps:get(parameters, method_attr_of(Op), #{}),
    Scanned = [ {P, override_for(Name, In, Overrides)}
                || #{name := Name, in := In} = P <- Params ],
    All = Scanned ++ declared_parameters(Overrides, Params),
    lists:foldl(fun({P, Override}, Ep) ->
                        spectra_openapi:with_parameter(
                          Ep, Module, parameter(P, Override))
                end, Endpoint, All).

%% A parameter declared in `-openapi(...)` that the scanner never found -- a
%% `match_qs/2` list built at runtime, a header read inside a helper module.
%% The attribute is the documented escape hatch for exactly those, so it must
%% be able to add a parameter, not only override a found one. An addition
%% must say where it lives: only an entry with an explicit `in` declares a
%% parameter, and one without stays what it always was -- an override of a
%% scanned parameter, adding nothing. Nothing is guessed, not even `query`.
declared_parameters(Overrides, Scanned) ->
    dedup_declared(
      [ {declared_parameter(Name, Override), Override}
        || Name := Override <- maps:iterator(Overrides, ordered),
           is_map(Override),
           addable(Override),
           not scanned_already(Name, Override, Scanned) ]).

%% Only an entry with an explicit `in` declares a parameter -- and never at
%% `path`: the route template is the authority on path parameters and the
%% scanner already seeds every template variable, so an unmatched `path`
%% declaration could only produce an operation OpenAPI forbids. Path entries
%% stay override-only.
addable(#{in := path}) -> false;
addable(#{in := _In}) -> true;
addable(_NoLocation) -> false.

%% Two attribute keys can collapse to one canonical identity -- ~"X-Tenant"
%% and ~"x-tenant" are both {header, ~"x-tenant"} -- and OpenAPI forbids
%% duplicate parameters. The first in key order wins, the same keep-first rule
%% the scanner's dedup_params applies to scanned duplicates.
dedup_declared(Params) ->
    dedup_declared(Params, []).

dedup_declared([], _Seen) ->
    [];
dedup_declared([{#{in := In, name := Name}, _Override} = Pair | Rest], Seen) ->
    case lists:member({In, Name}, Seen) of
        true -> dedup_declared(Rest, Seen);
        false -> [Pair | dedup_declared(Rest, [{In, Name} | Seen])]
    end.

declared_parameter(Name, #{in := In} = Override) ->
    #{ name => canonical(In, Name)
     , in => In
     , required => maps:get(required, Override, false)
     , schema => maps:get(schema, Override, string_type())
     }.

%% {In, Name} is a parameter's identity, so an entry saying `in => header`
%% collides only with a scanned header of that name -- a scanned query `id`
%% must not swallow a declared header `id`.
scanned_already(Name, #{in := In}, Scanned) ->
    Canonical = canonical(In, Name),
    lists:any(fun(#{name := N, in := I}) -> {I, N} =:= {In, Canonical} end, Scanned).

%% HTTP header names are case-insensitive and the scanner canonicalizes the
%% ones it finds to lowercase, so a declared header is compared and emitted
%% the same way -- `~"X-Tenant"` must override a scanned `x-tenant`, not sit
%% beside it as a second spelling.
canonical(header, Name) -> string:lowercase(Name);
canonical(_In, Name) -> Name.

method_attr_of(#{attr := Attr}) -> Attr.

parameter(#{name := Name, in := In, required := Required} = Param, Override) ->
    Schema = maps:get(schema, Override, maps:get(schema, Param)),
    #{ name => Name
     , in => In
       %% OpenAPI forbids an optional path parameter, whatever an override
       %% says.
     , required => In =:= path orelse maps:get(required, Override, Required)
     , schema => describe(Schema, parameter_description(Param, Override))
     }.

%% The entry that speaks for a *scanned* parameter. One with an explicit `in`
%% only speaks for that location; one without is a name-wide override. `Name`
%% arrives canonical (scanned headers are lowercased), so header entries are
%% matched case-insensitively.
override_for(Name, In, Overrides) ->
    Compatible = [ O || K := O <- maps:iterator(Overrides, ordered),
                        is_map(O),
                        canonical(In, K) =:= Name,
                        location_compatible(In, O) ],
    %% The most specific entry wins: one naming the location outranks a
    %% name-wide one, whatever order their keys happen to sort in.
    case [O || #{in := _} = O <- Compatible] of
        [Exact | _] ->
            Exact;
        [] ->
            case Compatible of
                [NameWide | _] -> NameWide;
                [] -> #{}
            end
    end.

location_compatible(In, #{in := DeclaredIn}) -> DeclaredIn =:= In;
location_compatible(_In, _Override) -> true.

%% OpenAPI would put a query parameter's default in the schema, but spectra's
%% JSON Schema generator has no `default`, so it goes in the prose where it at
%% least still reaches the reader.
parameter_description(Param, Override) ->
    Base = maps:get(description, Override, undefined),
    case maps:get(default, Param, undefined) of
        undefined ->
            Base;
        Default ->
            Note = <<"Defaults to `", (format_term(Default))/binary, "`.">>,
            join_paragraphs(Base, Note)
    end.

%%%_ * Request body ----------------------------------------------------

add_request_body(Endpoint, Resource, Op) ->
    #{module := Module} = Resource,
    case request_body(Resource, Op) of
        undefined ->
            Endpoint;
        {Schema, ContentType} ->
            spectra_openapi:with_request_body(Endpoint, Module, Schema, ContentType)
    end.

request_body(Resource, #{request_body := ReadsBody} = Op) ->
    Attr = maps:get(request_body, method_attr_of(Op), #{}),
    Declared = maps:get(schema, Attr, undefined),
    ContentType = maps:get(content_type, Attr, accepted_content_type(Resource)),
    case {Declared, ReadsBody, ContentType} of
        {undefined, false, _} ->
            undefined;
        {undefined, true, undefined} ->
            undefined;
        {undefined, true, CT} ->
            %% The handler reads a body and the resource declares what it
            %% accepts; we just cannot say more than "an opaque payload".
            {describe(string_type(), ~"Request body."), CT};
        {Schema, _, CT} ->
            {Schema, default_content_type(CT)}
    end.

accepted_content_type(#{accepted := [{CT, _Fun} | _]}) ->
    content_type_binary(CT);
accepted_content_type(#{accepted := []}) ->
    undefined.

default_content_type(undefined) -> ~"application/json";
default_content_type(CT) -> CT.

%%%_ * Responses -------------------------------------------------------

add_responses(Endpoint, Resource, Op, Opts) ->
    Statuses = response_statuses(Resource, Op, Opts),
    lists:foldl(fun(Status, Ep) ->
                        spectra_openapi:add_response(
                          Ep, response(Status, Resource, Op))
                end, Endpoint, Statuses).

response_statuses(Resource, #{implied := Implied, replies := Replies} = Op, Opts) ->
    Declared = maps:keys(maps:get(responses, method_attr_of(Op), #{})),
    lists:usort(Implied ++ maps:keys(Replies) ++ Declared ++
                    implicit_statuses(Resource, Op, Opts)).

%% Statuses cowboy_rest can produce for this method without the handler being
%% involved at all.
implicit_statuses(Resource, Op, Opts) ->
    case maps:get(implicit_responses, Opts, true) of
        false -> [];
        true -> negotiation_statuses(Resource, Op)
    end.

%% cowboy_rest matches Accept against content_types_provided before calling
%% anything, and Content-Type against content_types_accepted for a method with a
%% body -- so both statuses are reachable whatever the handler does. A plain
%% handler negotiates nothing, so neither status is.
negotiation_statuses(#{kind := plain}, _Op) ->
    [];
negotiation_statuses(_Resource, #{method := Method}) when Method =:= ~"GET";
                                                         Method =:= ~"HEAD" ->
    [406];
negotiation_statuses(#{accepted := [_ | _]}, #{method := Method})
  when Method =:= ~"POST"; Method =:= ~"PUT"; Method =:= ~"PATCH" ->
    [415];
negotiation_statuses(_Resource, _Op) ->
    [].

response(Status, Resource, Op) ->
    #{module := Module} = Resource,
    Override = response_attr(Status, Op),
    Response = spectra_openapi:response(Status, response_description(Status, Op, Override)),
    case response_body(Status, Resource, Op, Override) of
        undefined ->
            Response;
        {Schema, ContentType} ->
            spectra_openapi:response_with_body(Response, Module, Schema, ContentType)
    end.

response_attr(Status, Op) ->
    case maps:get(Status, maps:get(responses, method_attr_of(Op), #{}), #{}) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

%% A literal reply body is the best description available: it is the exact text
%% the caller will see.
response_description(Status, #{replies := Replies}, Override) ->
    case maps:get(description, Override, undefined) of
        undefined ->
            case maps:get(body_text, maps:get(Status, Replies, #{}), undefined) of
                undefined -> reason_phrase(Status);
                Text -> Text
            end;
        Description ->
            Description
    end.

response_body(Status, Resource, Op, Override) ->
    case maps:get(schema, Override, undefined) of
        undefined -> inferred_response_body(Status, Resource, Op, Override);
        Schema -> {Schema, response_content_type(Status, Resource, Op, Override)}
    end.

%% The provide callback's body is what a *representation* looks like, so it
%% belongs to 200 and nothing else. `cowboy_rest` sends no body at all with the
%% statuses it derives from a write callback's return -- 201 after
%% `{created, URI}`, 303 after `{see_other, URI}`, 204 after `true` -- and 205
%% and 304 are bodiless by definition.
inferred_response_body(Status, _Resource, _Op, _Override)
  when Status =:= 201; Status =:= 204; Status =:= 205;
       Status =:= 303; Status =:= 304 ->
    undefined;
inferred_response_body(Status, Resource, Op, Override) ->
    ContentType = response_content_type(Status, Resource, Op, Override),
    Reply = maps:get(Status, maps:get(replies, Op), #{}),
    case {Status =:= 200, Reply} of
        {true, _} ->
            success_body(Resource, ContentType);
        {false, #{body_text := Text}} ->
            {describe(string_type(), Text), or_text_plain(ContentType)};
        {false, _} ->
            undefined
    end.

%% The success body's type comes from the *provide* callback's -spec, whatever
%% the method: `cowboy_rest` serves a response body out of
%% `content_types_provided`, so a `POST` answering 201 with a body renders it
%% through the same callback a `GET` would. The accept callback only decides the
%% status.
success_body(#{provided := Provided, type_info := TypeInfo}, ContentType) ->
    case Provided of
        [{_CT, Callback} | _] ->
            provided_body(TypeInfo, Callback, ContentType);
        [] ->
            undefined
    end.

provided_body(TypeInfo, Callback, ContentType) ->
    case spectra_type_info:find_function(TypeInfo, Callback, 2) of
        {ok, Specs} ->
            case body_type(Specs) of
                undefined -> undefined;
                Type -> {Type, default_content_type(ContentType)}
            end;
        error ->
            undefined
    end.

body_type(Specs) ->
    Returns = lists:append([union_members(R) || #sp_function_spec{return = R} <- Specs]),
    Bodies = [B || #sp_tuple{fields = [B, _Req, _State]} <- Returns,
                   not is_control_type(B)],
    case Bodies of
        [Body | _] -> normalize_body_type(Body);
        [] -> undefined
    end.

%% A named type goes on as a reference rather than as the type it resolves to,
%% so it lands in `components/schemas` under its own name and keeps the
%% documentation its `-spectra(...)` attribute gave it.
normalize_body_type(#sp_user_type_ref{type_name = Name, arity = Arity}) ->
    {type, Name, Arity};
normalize_body_type(#sp_rec_ref{record_name = Name}) ->
    {record, Name};
normalize_body_type(Type) ->
    Type.

union_members(#sp_union{types = Types}) -> Types;
union_members(Type) -> [Type].

%% The `cowboy_rest` sentinels that occupy the body slot of a return tuple:
%% `stop`, `true`, and the `{created, URI}` family.
is_control_type(#sp_literal{value = V}) ->
    lists:member(V, ?CONTROL_VALUES);
is_control_type(#sp_tuple{fields = [#sp_literal{value = V} | _]}) ->
    lists:member(V, ?CONTROL_VALUES);
is_control_type(_Type) ->
    false.

is_success(Status, #{implied := Implied}) ->
    lists:member(Status, Implied) orelse (Status >= 200 andalso Status < 300).

response_content_type(Status, Resource, Op, Override) ->
    case maps:get(content_type, Override, undefined) of
        undefined -> derived_content_type(Status, Resource, Op);
        CT -> CT
    end.

derived_content_type(Status, Resource, Op) ->
    case maps:get(content_type, maps:get(Status, maps:get(replies, Op), #{}),
                  undefined) of
        undefined -> provided_content_type(Status, Resource, Op);
        CT -> strip_parameters(CT)
    end.

provided_content_type(Status, #{provided := Provided}, Op) ->
    case is_success(Status, Op) of
        true -> success_content_type(Provided);
        false -> undefined
    end.

success_content_type([{CT, _Fun} | _]) -> content_type_binary(CT);
success_content_type([]) -> undefined.

or_text_plain(undefined) -> ~"text/plain";
or_text_plain(CT) -> CT.

content_type_binary({Type, Sub, _Params}) ->
    <<Type/binary, "/", Sub/binary>>.

strip_parameters(CT) ->
    [Full | _] = binary:split(CT, ~";"),
    string:trim(Full).

%%%_ * Security --------------------------------------------------------

%% Emit the bearer scheme as soon as any operation needs one, so it is at least
%% documented, and apply it document-wide only when every operation needs it.
%% Anything the caller already said stands.
with_security(MetaData, Resources, Opts) ->
    Auths = [Auth || #{operations := Ops} <- Resources,
                     #{auth := Auth} <- maps:values(Ops)],
    Name = maps:get(security_scheme_name, Opts, ~"bearerAuth"),
    case lists:member(true, Auths) of
        false ->
            MetaData;
        true ->
            With = put_new(security_schemes, #{Name => bearer_scheme()}, MetaData),
            case lists:member(false, Auths) of
                true -> With;
                false -> put_new(security, [#{Name => []}], With)
            end
    end.

bearer_scheme() ->
    #{ ~"type" => ~"http"
     , ~"scheme" => ~"bearer"
     }.

put_new(Key, Value, Map) ->
    case maps:is_key(Key, Map) of
        true -> Map;
        false -> Map#{Key => Value}
    end.

%%%_ * Small helpers ---------------------------------------------------

%% spectra reads `description` out of a type's own metadata, so that is how a
%% description is attached to an otherwise anonymous schema. A `{type, _, _}`
%% reference has no metadata to attach to -- it carries the description of the
%% type it names, which is the right answer anyway.
describe(Schema, undefined) ->
    Schema;
describe({type, _, _} = Ref, _Description) ->
    Ref;
describe({record, _} = Ref, _Description) ->
    Ref;
describe(Schema, Description) ->
    spectra_type:add_doc_to_type(Schema, #{description => Description}).

join_paragraphs(undefined, B) -> B;
join_paragraphs(A, B) -> <<A/binary, "\n\n", B/binary>>.

format_term(Term) when is_binary(Term) -> Term;
format_term(Term) -> unicode:characters_to_binary(io_lib:format("~tp", [Term])).

string_type() ->
    #sp_simple_type{type = binary}.

reason_phrase(200) -> ~"OK";
reason_phrase(201) -> ~"Created";
reason_phrase(202) -> ~"Accepted";
reason_phrase(204) -> ~"No Content";
reason_phrase(303) -> ~"See Other";
reason_phrase(304) -> ~"Not Modified";
reason_phrase(400) -> ~"Bad Request";
reason_phrase(401) -> ~"Unauthorized";
reason_phrase(403) -> ~"Forbidden";
reason_phrase(404) -> ~"Not Found";
reason_phrase(405) -> ~"Method Not Allowed";
reason_phrase(406) -> ~"Not Acceptable";
reason_phrase(409) -> ~"Conflict";
reason_phrase(410) -> ~"Gone";
reason_phrase(412) -> ~"Precondition Failed";
reason_phrase(413) -> ~"Content Too Large";
reason_phrase(415) -> ~"Unsupported Media Type";
reason_phrase(422) -> ~"Unprocessable Content";
reason_phrase(429) -> ~"Too Many Requests";
reason_phrase(500) -> ~"Internal Server Error";
reason_phrase(501) -> ~"Not Implemented";
reason_phrase(502) -> ~"Bad Gateway";
reason_phrase(503) -> ~"Service Unavailable";
reason_phrase(504) -> ~"Gateway Timeout";
reason_phrase(Status) -> integer_to_binary(Status).
