-module(cbs_open_h).
-moduledoc """
Fixture: a `cowboy_rest` resource that declares `is_authorized/2` but answers
`{true, _, _}` in every clause -- the way a metrics endpoint opts *out* of
authentication while still implementing the callback. Reporting it as
authenticated would be a lie.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , is_authorized/2
        , content_types_provided/2
        , to_text/2
        ]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

is_authorized(Req, State) ->
    {true, Req, State}.

content_types_provided(Req, State) ->
    {[{{~"text", ~"plain", '*'}, to_text}], Req, State}.

to_text(Req, State) ->
    {~"metrics", Req, State}.
