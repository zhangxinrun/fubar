REBAR=./rebar
ERL=erl

node=fubar
app=fubar

mqtt_port=1883
master=undefined

# Compile source codes only.
compile:
	$(REBAR) compile

# Start the program in test mode.
test: compile
	mkdir -p priv/data/$(node)
	$(ERL) -pa ebin deps/*/ebin +A 100 +K true +P 1000000 +W w -boot start_sasl \
		-sname $(node) -s reloader -s $(app) -mnesia dir '"priv/data/$(node)"' \
		-env MQTT_PORT $(mqtt_port) -env FUBAR_MASTER $(master)

# Start the program in production mode.
run: compile
	mkdir -p priv/data/$(node)
	$(ERL) -pa ebin deps/*/ebin +A 100 +K true +P 1000000 +W w -boot start_sasl \
	-sname $(node) -s reloader -s $(app) -detached -mnesia dir '"priv/data/$(node)"' \
	-env MQTT_PORT $(mqtt_port) -env FUBAR_MASTER $(master)

# Debug running program in production mode.
debug: compile
	$(ERL) -pa ebin deps/*/ebin -sname debug -remsh $(node)@`hostname -s`

# Launch a shell for client.
client: compile
	$(ERL) -pa ebin deps/*/ebin +A 100 +K true +P 1000000 +W w -s reloader

# Make a textual log snapshot.
log:
	priv/script/dump-log.escript $(node)`date "-sasl-+%Y%m%dT%H%M%S.log"` priv/log/$(node)@`hostname -s`

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
