-module(cowboy_specer_store).
-moduledoc """
Stand-in for a module an accept callback hands its work to. Lives outside the
handler on purpose: the scanner does not cross module boundaries, so what
`store/2` returns is invisible to it.
""".

-export([store/2]).

-spec store(cowboy_req:req(), State) -> {true, cowboy_req:req(), State}.
store(Req, State) ->
    {true, Req, State}.
