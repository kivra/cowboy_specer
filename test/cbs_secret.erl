-module(cbs_secret).
-moduledoc """
Stand-in for the helper module a plain handler authenticates through. Lives
outside the handler on purpose: the scanner does not cross module boundaries,
so nothing here is visible to it.
""".

-export([check/1, start_job/0]).

-spec check(cowboy_req:req()) -> ok | {error, unauthorized}.
check(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        <<"Bearer ", _Secret/binary>> -> ok;
        _Other -> {error, unauthorized}
    end.

-spec start_job() -> ok | {error, already_running}.
start_job() ->
    ok.
