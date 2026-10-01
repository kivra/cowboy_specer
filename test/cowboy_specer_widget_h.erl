-module(cowboy_specer_widget_h).
-moduledoc """
Fixture: a JSON `cowboy_rest` resource serving three methods.

Exercises what the person fixture does not: a path binding, an `int` query
constraint with a default, a custom request header, a `POST` answering
`{created, URI}`, and a `DELETE`. Each method replies a status the others do
not, which is how per-method fact attribution is checked.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , content_types_provided/2
        , content_types_accepted/2
        , delete_resource/2
        , to_json/2
        , from_json/2
        ]).

-openapi(#{ tags => [~"widget"]
            %% `page` deliberately reuses a scanned query parameter's name in
            %% another location: {in, name} is a parameter's identity, so this
            %% adds a header without touching the query parameter.
            %% `X-Tenant` names the scanned `x-tenant` header in different
            %% case: header names are case-insensitive, so it must override
            %% that parameter, not sit beside it as a second spelling. And
            %% `widget_id`'s required => false must be ignored -- OpenAPI
            %% forbids an optional path parameter.
          , get => #{ summary => ~"Fetch one widget"
                    , parameters =>
                          #{ ~"page" =>
                                 #{ in => header
                                  , description => ~"Page hint header."
                                  }
                           , ~"X-Tenant" =>
                                 #{ in => header
                                  , description => ~"The tenant to bill."
                                  }
                             %% A name-wide alias for the same scanned header,
                             %% deliberately spelled to sort *before* the
                             %% location-specific entry: the entry naming the
                             %% location must win anyway.
                           , ~"X-TENANT" =>
                                 #{description => ~"A name-wide alias."}
                           , ~"widget_id" =>
                                 #{ description => ~"The widget's identifier."
                                  , required => false
                                  }
                             %% Not a variable in the route template, so this
                             %% must be dropped: the template is the authority
                             %% on path parameters, and emitting one it does
                             %% not declare would be invalid OpenAPI.
                           , ~"legacy_id" =>
                                 #{ in => path
                                  , description => ~"A path that never was."
                                  }
                           }
                    }
          , post =>
                #{ summary => ~"Create a widget"
                 , request_body => #{schema => {type, new_widget, 0}}
                 }
          , delete => #{summary => ~"Delete a widget"}
          }).

%% Named only from -openapi above, so it needs exporting to count as used --
%% which it is: it is this resource's request body.
-export_type([new_widget/0]).

-spectra(#{description => ~"A widget."}).
-type widget() :: #{id := binary(), size := integer()}.

-spectra(#{description => ~"The fields needed to create a widget."}).
-type new_widget() :: #{size := integer()}.

-spec to_json(cowboy_req:req(), State) ->
          {widget(), cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.

-spec from_json(cowboy_req:req(), State) ->
          {{created, binary()}, cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"GET", ~"POST", ~"DELETE"], Req, State}.

content_types_provided(Req, State) ->
    %% The <<"application/json">> shorthand rather than the {Type, Sub, Params}
    %% form -- Cowboy accepts both.
    {[{~"application/json", to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{~"application", ~"json", '*'}, from_json}], Req, State}.

to_json(Req, State) ->
    Id = cowboy_req:binding(widget_id, Req),
    #{page := Page} = cowboy_req:match_qs([{page, int, 1}], Req),
    case cowboy_req:header(~"x-tenant", Req) of
        undefined ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"Missing tenant", Req), State};
        Tenant ->
            {#{id => Id, size => Page + byte_size(Tenant)}, Req, State}
    end.

from_json(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    case Body of
        ~"" ->
            {stop, cowboy_req:reply(422, #{~"content-type" => ~"text/plain"},
                                    ~"Empty body", Req), State};
        _Payload ->
            {{created, ~"/widgets/1"}, Req, State}
    end.

delete_resource(Req, State) ->
    {true, Req, State}.
