-module(cowboy_specer_bare_h).
-moduledoc """
Fixture: a `cowboy_rest` resource with no annotations whatsoever.

Serving `OPTIONS` and `POST` from one module, so that facts found under the
`POST` handler must not leak into the `OPTIONS` operation. The accept callback
is wrapped in a span, so its `{true, Req, State}` return is only reachable
through the anonymous function -- which is what decides the success status.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , content_types_accepted/2
        , options/2
        , from_xml/2
        ]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"OPTIONS", ~"POST"], Req, State}.

options(Req, State) ->
    {ok, Req, State}.

content_types_accepted(Req, State) ->
    {[{{~"text", ~"xml", '*'}, from_xml}], Req, State}.

from_xml(Req, State) ->
    cowboy_specer_span:with_span(~"store", fun(_) -> verify_query(Req, State) end).

verify_query(Req, State) ->
    try cowboy_req:match_qs([ssn], Req) of
        #{ssn := SSN} -> store(SSN, Req, State)
    catch
        exit:_Reason:_ ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"Bad query parameter", Req), State}
    end.

store(SSN, Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    case byte_size(SSN) =:= 12 andalso Body =/= ~"" of
        true ->
            {true, Req, State};
        false ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"Invalid SSN format", Req), State}
    end.
