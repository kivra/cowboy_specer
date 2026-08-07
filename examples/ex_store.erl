-module(ex_store).
-moduledoc """
A stand-in for whatever the example handlers would really talk to.

Deliberately a separate module: `cowboy_specer` does not cross module
boundaries, so nothing in here is visible to the analysis. That is the point of
`authenticate/1` living here -- `ex_reindex_h` is recognised as authenticated
only because it can answer 401, not because anything reads an `authorization`
header where the scanner can see it.
""".

-export([ list_pets/1
        , find_pet/1
        , add_pet/1
        , delete_pet/1
        , authenticate/1
        , start_reindex/0
        ]).

-include("ex_pets.hrl").

-spec list_pets(pos_integer()) -> [#pet{}].
list_pets(Limit) ->
    lists:sublist([ #pet{id = ~"1", name = ~"Ada", tag = ~"cat"}
                  , #pet{id = ~"2", name = ~"Bo"}
                  ], Limit).

-spec find_pet(binary() | undefined) -> {ok, #pet{}} | not_found.
find_pet(~"1") -> {ok, #pet{id = ~"1", name = ~"Ada", tag = ~"cat"}};
find_pet(_Id) -> not_found.

-spec add_pet(ex_pets_h:new_pet()) -> #pet{}.
add_pet(#{name := Name} = NewPet) ->
    #pet{ id = integer_to_binary(erlang:unique_integer([positive]))
        , name = Name
        , tag = maps:get(tag, NewPet, undefined)
        }.

-spec delete_pet(binary() | undefined) -> ok.
delete_pet(_Id) ->
    ok.

-spec authenticate(cowboy_req:req()) -> ok | {error, unauthorized}.
authenticate(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        <<"Bearer ", _Token/binary>> -> ok;
        _Other -> {error, unauthorized}
    end.

-doc "Refuses a second reindex while the first is still running.".
-spec start_reindex() -> ok | {error, already_running}.
start_reindex() ->
    case persistent_term:get({?MODULE, reindexing}, false) of
        true ->
            {error, already_running};
        _NotRunning ->
            persistent_term:put({?MODULE, reindexing}, true),
            ok
    end.
