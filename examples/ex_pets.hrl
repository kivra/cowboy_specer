%% Shared between the handler that serves pets and the store that holds them,
%% the way a record usually is in a real application.
-record(pet, { id :: binary()
             , name :: binary()
             , tag :: binary() | undefined
             }).
