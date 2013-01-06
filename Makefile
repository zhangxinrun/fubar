APP=fubar

mqtt_port=1883
mqtts_port=undefined
node=fubar
master=undefined
cookie=sharedsecretamongnodesofafubarcluster_youneedtochangethisforsecurity
# ssh_host=localhost
# ssh_port=22

# Compile source codes only.
compile:
	./rebar compile

# Start the program in test mode.
test: compile
	mkdir -p priv/data
	mkdir -p priv/log/$(node)
	erl -pa ebin deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
		-sname $(node) -setcookie $(cookie) -s reloader -s $(APP) \
		-mnesia dir '"priv/data/$(node)"' \
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
		"erl -pa $(CURDIR)/ebin $(CURDIR)/deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
			-sname $(node) -setcookie $(cookie) -s $(APP) \
			-mnesia dir '\"$(CURDIR)/priv/data/$(node)\"' \
			-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env FUBAR_MASTER $(master)"

# Debug running program in production mode.
debug:
#	ssh $(ssh_host) -p $(ssh_port) -tt /usr/local/bin/to_erl /tmp/$(node)/
	to_erl /tmp/$(node)/

# Launch a shell for client.
client: compile
	erl -pa ebin deps/*/ebin +A 16 +K true +P 1000000 +W w -s reloader

# Start a log manager.
monitor: compile
	mkdir -p priv/data
	mkdir -p priv/log/$(node)_monitor
	mkdir -p /tmp/$(node)_monitor
	RUN_ERL_LOG_GENERATIONS=10
	RUN_ERL_LOG_MAXSIZE=10485760
	export RUN_ERL_LOG_GENERATIONS RUN_ERL_LOG_MAXSIZE
	run_erl -daemon /tmp/$(node)_mon/ $(CURDIR)/priv/log/$(node)_mon \
		"erl -pa $(CURDIR)/ebin $(CURDIR)/deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
			-sname $(node)_mon -setcookie $(cookie) -s $(APP) \
			-mnesia dir '\"$(CURDIR)/priv/data/$(node)_monitor\"' \
			-env MQTT_PORT undefined -env MQTTS_PORT undefined -env FUBAR_MASTER $(master)"

# Make a textual SASL log snapshot.
dump:
	priv/script/dump-log.escript $(node)

# Perform unit tests.
check: compile
	./rebar eunit

# Clear all the binaries and dependencies.  The runtime remains intact.
clean: delete-deps
	rm -rf *.dump
	./rebar clean

# Clear the runtime.
reset:
	rm -rf priv/data/$(node)

# Generate documents.
doc:
	./rebar doc

deps: get-deps
	./rebar update-deps

get-deps:
	./rebar get-deps

delete-deps:
	./rebar delete-deps
