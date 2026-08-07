-module(ex_pet_h).
-moduledoc """
`/pets/{petId}` -- an item resource, behind a bearer token.

Shows a path parameter (read off the route's path template, so `DELETE` declares
it even though it never looks at the binding), a type borrowed from another
module (`ex_pets_h:pet()`, which lands in `components/schemas` once and is
referenced from both resources), and authentication recognised from the
`authorization` header this handler reads itself.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , content_types_provided/2
        , delete_resource/2
        , to_json/2
        ]).

-openapi(#{ tags => [~"pets"]
          , get =>
                #{ operationId => ~"getPet"
                 , parameters =>
                       #{~"petId" => #{description => ~"The pet's identifier."}}
                 , responses => #{200 => #{schema => {type, pet, 0}}}
                 }
          , delete => #{ operationId => ~"deletePet"
                       , summary => ~"Remove a pet"
                       }
          }).

%% The 200's schema is declared in -openapi above rather than read from this
%% spec: a provide callback returns the *encoded* body, so all the spec can
%% honestly say is `iodata()`.
%% A schema reference in -openapi is resolved against *this* module, so a type
%% shared with another resource needs a local alias. It still resolves to the
%% one #pet{} record, so `components/schemas` gets a single `Pet0` that both
%% resources point at.
-export_type([pet/0]).
-type pet() :: ex_pets_h:pet().

-spectra(#{summary => ~"Fetch one pet"}).
-spec to_json(cowboy_req:req(), State) ->
          {iodata(), cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"GET", ~"DELETE"], Req, State}.

content_types_provided(Req, State) ->
    {[{{~"application", ~"json", '*'}, to_json}], Req, State}.

to_json(Req, State) ->
    maybe
        ok ?= authorize(Req),
        {ok, Pet} ?= ex_store:find_pet(cowboy_req:binding(petId, Req)),
        {ok, Json} = spectra:encode(json, ex_pets_h, {type, pet, 0}, Pet),
        {Json, Req, State}
    else
        {error, unauthorized} ->
            {stop, cowboy_req:reply(401, #{~"content-type" => ~"text/plain"},
                                    ~"Not authorized", Req), State};
        not_found ->
            {stop, cowboy_req:reply(404, #{~"content-type" => ~"text/plain"},
                                    ~"No such pet", Req), State}
    end.

%% Returning `true` from a delete_resource callback is a 204 to cowboy_rest, and
%% that is where the documented status comes from.
delete_resource(Req, State) ->
    ok = ex_store:delete_pet(cowboy_req:binding(petId, Req)),
    {true, Req, State}.

authorize(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        <<"Bearer ", _Token/binary>> -> ok;
        _Other -> {error, unauthorized}
    end.
