REBAR=./rebar
ERL=erl
APP=fubar

mqtt_port=1883
mqtts_port=undefined
node=fubar
master=undefined
host=localhost
port=22

# Compile source codes only.
compile:
	$(REBAR) compile

# Start the program in test mode.
test: compile
	mkdir -p priv/data/$(node)
	$(ERL) -pa ebin deps/*/ebin +A 100 +K true +P 1000000 +W w -boot start_sasl \
		-sname $(node) -s reloader -s $(APP) -mnesia dir '"priv/data/$(node)"' \
		-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env FUBAR_MASTER $(master)

# Start the program in production mode.
run: compile
	mkdir -p priv/data
	mkdir -p /tmp/$(node)
	run_erl -daemon /tmp/$(node)/ $(CURDIR)/priv/log/$(node) \
	"$(ERL) -pa $(CURDIR)/ebin $(CURDIR)/deps/*/ebin +A 100 +K true +P 1000000 +W w -boot start_sasl \
	-sname $(node) -s $(APP) -mnesia dir '\"$(CURDIR)/priv/data/$(node)\"' \
	-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env FUBAR_MASTER $(master)"

# Debug running program in production mode.
debug: compile
	ssh $(host) -p $(port) -tt /usr/local/bin/to_erl /tmp/$(node)/

# Launch a shell for client.
client: compile
	$(ERL) -pa ebin deps/*/ebin +A 16 +K true +P 100000 +W w -s reloader

# Make a textual log snapshot.
log:
	priv/script/dump-log.escript $(node)

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
