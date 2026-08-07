-module(cbs_span).
-moduledoc """
A tracing-style wrapper, as a separate module on purpose.

Handlers routinely wrap their work in `some_module:with_span(Name, fun(_) ->
... end)`. The call graph does not cross module boundaries, so the only way to
see what such a handler returns is the rule that a tail call taking an anonymous
function also yields that function's return expressions. The fixtures use this
to keep that rule tested.
""".

-export([with_span/2]).

-spec with_span(binary(), fun((binary()) -> Result)) -> Result.
with_span(Name, Fun) ->
    Fun(Name).
