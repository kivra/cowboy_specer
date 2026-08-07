-module(ex_minimal_h).
-moduledoc """
`/minimal` -- a `cowboy_rest` resource with no annotations whatsoever.

Here to show what the other examples would look like if nobody had written a
single `-openapi(...)` or `-spectra(...)`: the method, the required `q` query
parameter, the `text/plain` content type, the 200, the 400 and the 406 are all
still documented. Only the prose and the response schema are missing.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , content_types_provided/2
        , to_text/2
        ]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"GET"], Req, State}.

content_types_provided(Req, State) ->
    {[{{~"text", ~"plain", '*'}, to_text}], Req, State}.

to_text(Req, State) ->
    case cowboy_req:match_qs([q], Req) of
        #{q := ~""} ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"q must not be empty", Req), State};
        #{q := Q} ->
            {<<"you said ", Q/binary>>, Req, State}
    end.
