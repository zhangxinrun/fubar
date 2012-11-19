REBAR=./rebar
ERL=erl

node=fubar
app=fubar

# Compile source codes only.
compile:
	$(REBAR) compile

# Update all the dependencies, compile and initialize the runtime.
boot: get-deps update-deps compile
	$(ERL) -pa ebin deps/*/ebin -boot start_sasl -sname $(node) -mnesia dir '"priv/data/$(node)"' -s $(app) boot

# Start the program in test mode.
test: compile
	mkdir -p priv/data/$(node)
	$(ERL) -pa ebin deps/*/ebin +A 16 +K true +P 1000000 +W w -boot start_sasl -sname $(node) -s reloader -s $(app) -mnesia dir '"priv/data/$(node)"'

# Start the program in production mode.
run: compile
	mkdir -p priv/data/$(node)
	$(ERL) -pa ebin deps/*/ebin +A 16 +K true +P 1000000 +W w -boot start_sasl -sname $(node) -s reloader -s $(app) -detached -mnesia dir '"priv/data/$(node)"'

# Debug running program in production mode.
debug: compile
	$(ERL) -pa ebin deps/*/ebin -sname debug -remsh $(node)@`hostname -s`

# Launch a shell for client.
client: compile
	$(ERL) -pa ebin deps/*/ebin +A 16 +K true +P 1000000 +W w -s reloader

# Make a textual log snapshot.
log:
	priv/script/dump-log.escript $(node)-`date "+%Y%m%dT%H%M%S.log"` priv/log/$(node)@`hostname -s`

# Perform unit tests.
check: compile
	$(REBAR) eunit

# Clear all the binaries and dependencies.  The runtime remains intact.
clean: delete-deps
	rm -rf *.dump
	$(REBAR) clean

# Clear the runtime.
reset:
	rm -rf priv/data/$(node)

# Generate documents.
doc:
	$(REBAR) doc

deps: get-deps
	$(REBAR) update-deps

get-deps:
	$(REBAR) get-deps

delete-deps:
	$(REBAR) delete-deps
