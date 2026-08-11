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
                   %% Both parameters are read elsewhere, where the scanner
                   %% cannot see them -- so they are declared by hand, which
                   %% must *add* them, not just override found ones. `dry_run`
                   %% exercises the `in` default (query); `x-request-id` an
                   %% explicit `in`.
                 , parameters =>
                       #{ ~"dry_run" =>
                              #{description =>
                                    ~"Validate the request without starting."}
                        , ~"x-request-id" =>
                              #{ description => ~"Echoed into the job log."
                               , in => header
                               }
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
