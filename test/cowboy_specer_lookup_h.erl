-module(cowboy_specer_lookup_h).
-moduledoc """
Fixture: a read that is a `POST`, so that its argument can travel in the body.

`cowboy_rest` answers 204 for an accept callback that returns `true`, so a
`POST` that answers with a representation replies its 200 itself and stops.
Nothing is implied for such a resource: every status it answers is among its
replies. Two things used to imply a 204 anyway, and this fixture has both: an
`is_authorized/2` that returns `{true, Req, State}`, which is not the accept
callback, and an accept callback that never returns anything but `stop`.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , is_authorized/2
        , content_types_provided/2
        , content_types_accepted/2
        , from_json/2
        ]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"POST"], Req, State}.

is_authorized(Req, State) ->
    case cowboy_req:header(~"authorization", Req) of
        undefined -> {{false, ~"Bearer"}, Req, State};
        _Token -> {true, Req, State}
    end.

%% What `Accept' is negotiated against; for a POST, cowboy_rest never calls the
%% callback.
content_types_provided(Req, State) ->
    {[{{~"application", ~"json", '*'}, from_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{~"application", ~"json", '*'}, from_json}], Req, State}.

from_json(Req, State) ->
    cowboy_specer_span:with_span(~"lookup", fun(_) -> lookup(Req, State) end).

lookup(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    case Body of
        ~"" -> reply(400, ~"No body", Req, State);
        _ -> reply(200, Body, Req, State)
    end.

reply(Status, Body, Req, State) ->
    {stop, cowboy_req:reply(Status, #{~"content-type" => ~"application/json"},
                            Body, Req), State}.
