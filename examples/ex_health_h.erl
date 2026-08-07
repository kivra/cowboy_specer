-module(ex_health_h).
-moduledoc """
`/healthz` -- the simplest plain `cowboy_handler` there is.

No `cowboy_rest`, so nothing is inferred from a state machine: the operation is
documented entirely from the one reply it makes. With no `cowboy_req:method/1`
test anywhere, it is documented as `GET`, which is what a probe is.
""".

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(200, #{~"content-type" => ~"text/plain"},
                           ~"OK", Req0),
    {ok, Req, State}.
