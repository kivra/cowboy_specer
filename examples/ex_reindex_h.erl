-module(ex_reindex_h).
-moduledoc """
`/admin/reindex` -- the interesting kind of plain handler.

Nothing about it is literal at the `cowboy_req:reply/4` call site: it dispatches
on `cowboy_req:method/1`, funnels every answer through a local `reply/4`
wrapper, and builds its headers in a `headers/1` helper. The statuses come from
reading that wrapper's call sites, the content type from the helper's first
literal return, and the method from the dispatch.

Authentication lives in `ex_store`, which the scanner cannot see into -- the 401
is the only evidence, and it is enough.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-openapi(#{ tags => [~"admin"]
          , post =>
                #{ operationId => ~"startReindex"
                 , summary => ~"Start a reindex"
                 , description =>
                       ~"""
                       Answers as soon as the job has **started**, not when it
                       finishes, so the status says nothing about whether it
                       succeeded.
                       """
                 , responses =>
                       #{ 202 => #{ description => ~"The reindex was started."
                                  , schema => {type, job_status, 0}
                                  }
                        , 409 => #{description => ~"A reindex is already running."}
                        , 401 => #{description => ~"Wrong or missing token."}
                        }
                 }
          }).

-export_type([job_status/0]).

-spectra(#{description => ~"What was decided about this request."}).
-type job_status() :: #{outcome := binary()}.

init(Req, State) ->
    maybe
        ok ?= require_post(Req),
        ok ?= ex_store:authenticate(Req),
        start(Req, State)
    else
        {error, Outcome} -> refuse(Outcome, Req, State)
    end.

%% The one method this handler serves. A plain handler answers every method
%% unless it looks, and this is it looking.
require_post(Req) ->
    case cowboy_req:method(Req) of
        ~"POST" -> ok;
        _Other -> {error, method_not_allowed}
    end.

start(Req, State) ->
    case ex_store:start_reindex() of
        ok -> reply(202, accepted, Req, State);
        {error, already_running} -> reply(409, already_running, Req, State)
    end.

refuse(method_not_allowed, Req, State) ->
    reply(405, method_not_allowed, Req, State);
refuse(unauthorized, Req, State) ->
    reply(401, unauthorized, Req, State).

%% `Status` is this function's first argument, so the documented statuses are
%% whatever is passed there above: 202, 409, 405 and 401. The 405 is dropped
%% again, because it answers the methods this handler does *not* serve.
reply(Status, Outcome, Req, State) ->
    Body = json:encode(#{outcome => Outcome}),
    {ok, cowboy_req:reply(Status, headers(Status), Body, Req), State}.

headers(405) ->
    (headers(200))#{~"allow" => ~"POST"};
headers(_Status) ->
    #{~"content-type" => ~"application/json"}.
