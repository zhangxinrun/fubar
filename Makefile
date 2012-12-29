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
	mkdir -p priv/data
	mkdir -p priv/log/$(node)
	$(ERL) -pa ebin deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
		-sname $(node) -s reloader -s $(APP) -mnesia dir '"priv/data/$(node)"' \
		-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env FUBAR_MASTER $(master)

# Start the program in production mode.
run: compile
	mkdir -p priv/data
	mkdir -p priv/log/$(node)
	mkdir -p /tmp/$(node)
	RUN_ERL_LOG_GENERATIONS=10
	RUN_ERL_LOG_MAXSIZE=10485760
	export RUN_ERL_LOG_GENERATIONS RUN_ERL_LOG_MAXSIZE
	run_erl -daemon /tmp/$(node)/ $(CURDIR)/priv/log/$(node) \
		"$(ERL) -pa $(CURDIR)/ebin $(CURDIR)/deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
			-sname $(node) -s $(APP) -mnesia dir '\"$(CURDIR)/priv/data/$(node)\"' \
			-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env FUBAR_MASTER $(master)"

# Debug running program in production mode.
debug:
#	ssh $(host) -p $(port) -tt /usr/local/bin/to_erl /tmp/$(node)/
	to_erl /tmp/$(node)/

# Launch a shell for client.
client: compile
	$(ERL) -pa ebin deps/*/ebin +A 16 +K true +P 1000000 +W w -s reloader

# Start a log manager.
monitor: compile
	mkdir -p priv/data
	mkdir -p priv/log/$(node)_monitor
	mkdir -p /tmp/$(node)_monitor
	RUN_ERL_LOG_GENERATIONS=10
	RUN_ERL_LOG_MAXSIZE=10485760
	export RUN_ERL_LOG_GENERATIONS RUN_ERL_LOG_MAXSIZE
	run_erl -daemon /tmp/$(node)_monitor/ $(CURDIR)/priv/log/$(node)_monitor \
		"$(ERL) -pa $(CURDIR)/ebin $(CURDIR)/deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
			-sname $(node)_monitor -s $(APP) -mnesia dir '\"$(CURDIR)/priv/data/$(node)_monitor\"' \
			-env MQTT_PORT undefined -env MQTTS_PORT undefined -env FUBAR_MASTER $(master)"

# Make a textual log snapshot.
dump:
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
