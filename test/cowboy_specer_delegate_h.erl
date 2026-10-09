-module(cowboy_specer_delegate_h).
-moduledoc """
Fixture: a `POST` whose accept callback stops on one path and hands the
other to another module, whose result the scanner cannot see.

The one literal result is `stop`, but that is not "only ever stops": the
other path may well return `true`, so the operation keeps the 204 an unread
result implies.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , content_types_accepted/2
        , from_json/2
        ]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"POST"], Req, State}.

content_types_accepted(Req, State) ->
    {[{{~"application", ~"json", '*'}, from_json}], Req, State}.

from_json(Req0, State) ->
    case cowboy_req:read_body(Req0) of
        {ok, ~"", Req} ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"No body", Req), State};
        {ok, _Body, Req} ->
            cowboy_specer_store:store(Req, State)
    end.
