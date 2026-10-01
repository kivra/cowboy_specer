-module(cowboy_specer_job_h).
-moduledoc """
Fixture: the interesting kind of plain handler.

It dispatches on `cowboy_req:method/1`, and every status it answers goes
through a local `reply/4` wrapper whose headers come from a local `headers/1`
helper -- so nothing is literal at the `cowboy_req:reply/4` call site itself.
Authentication lives in another module and is therefore invisible; the 401 is
the only evidence.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-openapi(#{ tags => [~"jobs"]
          , post =>
                #{ summary => ~"Start the batch job"
                   %% Declaration-only fixture parameters: nothing in this
                   %% module reads either, which is the point -- an entry
                   %% naming a location is *added* when the scanner found
                   %% nothing to override. An addition must say where it
                   %% lives; an entry without `in` can only override, and
                   %% with nothing scanned here it adds nothing at all.
                 , parameters =>
                       #{ ~"dry_run" =>
                              #{ in => query
                               , description =>
                                     ~"Validate the request without starting."
                               }
                        , ~"X-Request-Id" =>
                              #{ description => ~"Echoed into the job log."
                               , in => header
                               }
                          %% Deliberately the same header in another spelling:
                          %% both canonicalize to `x-request-id`, so only one
                          %% may reach the document -- the first in key order,
                          %% which is `X-Request-Id` (uppercase sorts first).
                        , ~"x-request-id" =>
                              #{ description => ~"A duplicate spelling."
                               , in => header
                               }
                          %% A third spelling without a location: it may
                          %% neither add a parameter nor leak its description
                          %% onto the declared header, whose own entry wins.
                        , ~"X-Request-ID" =>
                              #{description => ~"A name-wide note."}
                        }
                 , responses =>
                       #{ 202 => #{ description => ~"The job was started."
                                  , schema => {type, job_status, 0}
                                  }
                        , 409 => #{description => ~"Already running."}
                        , 401 => #{description => ~"Wrong or missing secret."}
                        }
                 }
          }).

-export_type([job_status/0]).

-spectra(#{description => ~"What was decided about this request."}).
-type job_status() :: #{job := binary(), outcome := binary()}.

init(Req, State) ->
    maybe
        ok ?= require_post(Req),
        ok ?= authenticate(Req),
        start(Req, State)
    else
        {error, Outcome} -> refuse(Outcome, Req, State)
    end.

require_post(Req) ->
    case cowboy_req:method(Req) of
        ~"POST" -> ok;
        _Other -> {error, method_not_allowed}
    end.

authenticate(Req) ->
    cowboy_specer_secret:check(Req).

start(Req, State) ->
    case cowboy_specer_secret:start_job() of
        ok -> reply(202, accepted, Req, State);
        {error, already_running} -> reply(409, already_running, Req, State)
    end.

refuse(method_not_allowed, Req, State) ->
    reply(405, method_not_allowed, Req, State);
refuse(unauthorized, Req, State) ->
    reply(401, unauthorized, Req, State).

reply(Status, Outcome, Req, State) ->
    Body = json:encode(#{job => import, outcome => Outcome}),
    {ok, cowboy_req:reply(Status, headers(Status), Body, Req), State}.

headers(405) ->
    (headers(200))#{~"allow" => ~"POST"};
headers(_Status) ->
    #{~"content-type" => ~"application/json"}.
