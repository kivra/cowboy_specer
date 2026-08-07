-module(cowboy_specer_hidden_h).
-moduledoc "Fixture: a handler that opts out of the document.".

-behaviour(cowboy_handler).

-export([init/2]).

-openapi(#{hidden => true}).

init(Req0, State) ->
    {ok, cowboy_req:reply(200, #{}, ~"secret", Req0), State}.
