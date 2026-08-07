-module(cowboy_specer_probe_h).
-moduledoc """
Fixture: the simplest plain handler there is -- a liveness probe. No method
test, no parameters, one literal reply.
""".

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(200, #{~"content-type" => ~"text/plain"},
                           ~"still here", Req0),
    {ok, Req, State}.
