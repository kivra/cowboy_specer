# -*-Make-*-
.PHONY: default all clean distclean upgrade compile test dialyzer dialyzer-examples \
        eunit ct xref repl examples

default: compile

all: compile xref

clean:
	rebar3 clean --all
	find . -name "erlcinfo" -exec rm {} \;

distclean: clean
	rm -rf _build
	rm -f rebar.lock

upgrade:
	rebar3 upgrade

compile:
	rebar3 compile

test: xref eunit ct dialyzer dialyzer-examples

dialyzer:
	rebar3 dialyzer

# examples/ is not in the default profile, so it needs its own run -- an example
# that no longer type-checks is one someone is about to copy.
dialyzer-examples:
	rebar3 as examples dialyzer

eunit:
	rebar3 eunit

ct:
	rebar3 ct

xref:
	rebar3 xref

repl:
	rebar3 as test shell

# Run the example API: then ex_server:start().
examples:
	rebar3 as examples shell
