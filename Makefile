# -*-Make-*-
.PHONY: default all clean distclean upgrade compile test dialyzer eunit ct xref repl

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

test: xref eunit ct dialyzer

dialyzer:
	rebar3 dialyzer

eunit:
	rebar3 eunit

ct:
	rebar3 ct

xref:
	rebar3 xref

repl:
	rebar3 as test shell
