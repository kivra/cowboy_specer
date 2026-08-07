-module(cowboy_specer_person_h).
-moduledoc """
Fixture: a fully annotated `cowboy_rest` resource.

Serves XML rather than JSON, reads its query parameters through
`cowboy_req:match_qs/2` with a custom constraint fun, authenticates by reading
the `authorization` header itself, and replies with a handful of statuses. This
is the shape a real service that predates any OpenAPI tooling tends to have.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , content_types_provided/2
        , to_xml/2
        ]).

-openapi(#{ tags => [~"person"]
          , get =>
                #{ operationId => ~"getPerson"
                 , parameters =>
                       #{ ~"ssn" => #{schema => {type, ssn, 0}}
                        , ~"verified" =>
                              #{description => ~"Only ever promotes."}
                        }
                 , responses =>
                       #{ 204 => #{description => ~"No such person."}
                        , 502 => #{description => ~"The registry is unhappy."}
                        }
                 }
          }).

-spectra(#{ title => ~"Personnummer"
          , description =>
                ~"A Swedish personal identity number, 12 digits: `YYYYMMDDNNNN`."
          }).
-type ssn() :: binary().

-spectra(#{ title => ~"Person"
          , description => ~"One person record, serialised as XML."
          }).
-type person_xml() :: binary().

%% Erlang rejects a wild attribute after the first function definition, so a
%% `-spectra(...)` annotation and the `-spec` it documents both live up here.

-spectra(#{ summary => ~"Look up a person by SSN"
          , description => ~"Answers from the cache when it can."
          }).
-spec to_xml(cowboy_req:req(), State) ->
          {person_xml(), cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.

-spec lookup(ssn(), boolean(), cowboy_req:req(), State) ->
          {person_xml(), cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"GET"], Req, State}.

content_types_provided(Req, State) ->
    {[{{~"text", ~"xml", '*'}, to_xml}], Req, State}.

to_xml(Req, State) ->
    cowboy_specer_span:with_span(~"lookup", fun(_) -> verify_query(Req, State) end).

verified_constraint(forward, ~"true") -> {ok, true};
verified_constraint(forward, ~"false") -> {ok, false};
verified_constraint(forward, _) -> {error, not_boolean};
verified_constraint(reverse, true) -> {ok, ~"true"};
verified_constraint(reverse, false) -> {ok, ~"false"};
verified_constraint(format_error, Value) ->
    io_lib:format("The value ~p is not a boolean.", [Value]).

verify_query(Req, State) ->
    try cowboy_req:match_qs([ssn, {verified, [fun verified_constraint/2], false}],
                            Req) of
        #{ssn := SSN, verified := Verified} ->
            lookup(SSN, Verified, Req, State)
    catch
        exit:_Reason:_ ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"Bad query parameter", Req), State}
    end.

lookup(SSN, Verified, Req, State) ->
    maybe
        ok ?= authorize(Req),
        ok ?= valid_ssn(SSN),
        case registry_lookup(SSN, Verified) of
            {ok, Person} ->
                {Person, Req, State};
            not_found ->
                {stop, cowboy_req:reply(204, #{~"content-type" => ~"text/xml"},
                                        Req), State};
            {error, _Reason} ->
                {stop, cowboy_req:reply(502, #{~"content-type" => ~"text/plain"},
                                        ~"Upstream service error", Req), State}
        end
    else
        {error, invalid_ssn} ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"Invalid SSN format", Req), State};
        {error, unauthorized} ->
            {stop, cowboy_req:reply(401, #{~"content-type" => ~"text/plain"},
                                    ~"Not Authorized", Req), State}
    end.

authorize(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        undefined -> {error, unauthorized};
        <<"Bearer ", _Token/binary>> -> ok;
        _Other -> {error, unauthorized}
    end.

valid_ssn(SSN) when byte_size(SSN) =:= 12 -> ok;
valid_ssn(_SSN) -> {error, invalid_ssn}.

registry_lookup(~"000000000000", _Verified) -> not_found;
registry_lookup(~"999999999999", _Verified) -> {error, upstream};
registry_lookup(SSN, _Verified) -> {ok, <<"<person><ssn>", SSN/binary, "</ssn></person>">>}.
