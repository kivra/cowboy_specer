-module(ex_pets_h).
-moduledoc """
`/pets` -- a collection resource. The fully annotated example: everything
`cowboy_specer` can be told is told here.

Shows a record as a response schema, a map type as a request body, an `int`
query constraint with a default, and a `POST` that answers `{created, URI}`.

The types do double duty: `spectra` encodes the response through the same
`pets()` that `cowboy_specer` turns into the response schema, so the wire format
and the documentation cannot drift apart.
""".

-behaviour(cowboy_rest).

-export([ init/2
        , allowed_methods/2
        , content_types_provided/2
        , content_types_accepted/2
        , to_json/2
        , from_json/2
        ]).

%% Everything the code cannot say. The methods, the `limit` parameter and its
%% type, the 400 and 422, the `application/json` content types and the 201 are
%% all read off the code below -- none of that is repeated here.
%%
%% The 200's schema has to be declared: a `cowboy_rest` provide callback returns
%% the *encoded* body, so its `-spec` says `iodata()` and there is no structured
%% type to read. (A handler that answers XML or plain text can name a type in
%% its spec instead -- see the README.)
-openapi(#{ tags => [~"pets"]
          , get =>
                #{ operationId => ~"listPets"
                 , responses =>
                       #{200 => #{ description => ~"A page of pets."
                                 , schema => {type, pets, 0}
                                 }}
                 }
          , post =>
                #{ operationId => ~"createPet"
                 , request_body => #{schema => {type, new_pet, 0}}
                 , responses =>
                       #{201 => #{description =>
                                      ~"Created. The `Location` header has the URL."}}
                 }
          }).

%% pet() and new_pet() are named only from -openapi and from ex_pet_h, so they
%% need exporting to count as used -- which they are: they are this resource's
%% interface.
-export_type([pet/0, pets/0, new_pet/0]).

-include("ex_pets.hrl").

-spectra(#{ title => ~"Pet"
          , description => ~"One pet. `tag` is optional."
          }).
-type pet() :: #pet{}.

-spectra(#{description => ~"Every pet on this page."}).
-type pets() :: [pet()].

-spectra(#{description => ~"The fields needed to create a pet."}).
-type new_pet() :: #{name := binary(), tag => binary()}.

%% Erlang rejects a wild attribute after the first function definition, so a
%% `-spectra(...)` annotation and the `-spec` it documents both live up here
%% rather than next to the function.

-spectra(#{ summary => ~"List pets"
          , description => ~"Newest first. Use `limit` to page."
          }).
-spec to_json(cowboy_req:req(), State) ->
          {iodata(), cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.

-spectra(#{summary => ~"Add a pet"}).
-spec from_json(cowboy_req:req(), State) ->
          {{created, binary()}, cowboy_req:req(), State}
        | {stop, cowboy_req:req(), State}.

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[~"GET", ~"POST"], Req, State}.

content_types_provided(Req, State) ->
    {[{{~"application", ~"json", '*'}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{~"application", ~"json", '*'}, from_json}], Req, State}.

to_json(Req, State) ->
    %% `limit` becomes an optional integer query parameter defaulting to 20.
    case cowboy_req:match_qs([{limit, int, 20}], Req) of
        #{limit := Limit} when Limit > 0, Limit =< 100 ->
            {ok, Json} = spectra:encode(json, ?MODULE, {type, pets, 0},
                                        ex_store:list_pets(Limit)),
            {Json, Req, State};
        #{} ->
            {stop, cowboy_req:reply(400, #{~"content-type" => ~"text/plain"},
                                    ~"limit must be between 1 and 100", Req),
             State}
    end.

from_json(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    case spectra:decode(json, ?MODULE, {type, new_pet, 0}, Body) of
        {ok, NewPet} ->
            %% The store assigns the id, which is why the request body is a
            %% new_pet() and the response a pet().
            #pet{id = Id} = ex_store:add_pet(NewPet),
            {{created, <<"/pets/", Id/binary>>}, Req, State};
        {error, _Errors} ->
            {stop, cowboy_req:reply(422, #{~"content-type" => ~"text/plain"},
                                    ~"Not a pet", Req), State}
    end.
