%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar application callback.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(fubar_app).
-author("Sungjin Park <jinni.park@gmail.com>").
-behaviour(application).

-bootstrap_master(boot).
-bootstrap_slave(join).

%%
%% Includes
%%
-include("fubar.hrl").
-include("sasl_log.hrl").
-include("props_to_record.hrl").

%%
%% Records
%%
-record(settings, {acceptors = 100 :: integer(),
				   max_connections = infinity :: timeout(),
				   options = [] :: proplist(atom(), term())}).

%%
%% Exports
%%
-export([boot/0, join/1, leave/0, start/2, stop/1]).

%% @doc Master mode bootstrap logic.
boot() ->
	case mnesia:create_schema([node()]) of
		ok ->
			ok;
		{error, {_, {already_exists, _}}} ->
			ok
	end,
	?INFO({"created a schema on", node()}),
	ok = application:start(mnesia),
	fubar_route:boot(),
	mqtt_acl:boot(),
	mqtt_account:boot(),
	mqtt_topic:boot().

%% @doc Slave mode bootstrap logic.
join(MasterNode) ->
	ok = application:start(mnesia),
	pong = net_adm:ping(MasterNode),
	{ok, _} = rpc:call(MasterNode, mnesia, change_config, [extra_db_nodes, [node()]]),
	case mnesia:change_table_copy_type(schema, node(), disc_copies) of
		{atomic, ok} -> ok;
		{aborted, {already_exists, schema, _, _}} -> ok
	end,
	?INFO({"clustered with", MasterNode}),
	fubar_route:cluster(MasterNode),
	mqtt_acl:cluster(MasterNode),
	mqtt_account:cluster(MasterNode),
	mqtt_topic:cluster(MasterNode).

%% @doc Leave cluster.
leave() ->
	case nodes() of
		[] ->
			application:stop(mnesia);
		[Node | _] ->
			[mnesia:del_table_copy(Table, node()) || Table <- mnesia:system_info(tables)],
			application:stop(mnesia),
			rpc:call(Node, mnesia, del_table_copy, [schema, node()])
	end.

%%
%% Application callbacks
%%
start(_StartType, _StartArgs) ->
	Props = fubar:settings(?MODULE),
	?INFO({"loaded settings", Props}),
	Settings = ?PROPS_TO_RECORD(Props, settings),
	{ok, Pid} = fubar_sup:start_link(),
	application:start(crypto),
	application:start(public_key),
	application:start(ssl),
	case list_to_atom(os:getenv("FUBAR_MASTER")) of
		undefined ->
			fubar:apply_all_module_attributes_of(bootstrap_master);
		MasterNode ->
			fubar:apply_all_module_attributes_of({bootstrap_slave, [MasterNode]})
	end,
	application:start(ranch),
	case {string:to_integer(os:getenv("MQTT_PORT")), Settings#settings.max_connections} of
		{{error, _}, _} ->
			ok;
		{{MQTTPort, _}, MQTTMax} ->
			ranch:start_listener(mqtt, Settings#settings.acceptors,
								 ranch_tcp, [{port, MQTTPort}, {max_connections, MQTTMax} |
											 Settings#settings.options],
								 mqtt_protocol, [{dispatch, mqtt_server}])
	end,
	case {string:to_integer(os:getenv("MQTTS_PORT")), Settings#settings.max_connections} of
		{{error, _}, _} ->
			ok;
		{{MQTTSPort, _}, MQTTSMax} ->
			ssl:start(),
			ranch:start_listener(mqtts, Settings#settings.acceptors,
								 ranch_ssl, [{port, MQTTSPort}, {max_connections, MQTTSMax} |
											 Settings#settings.options],
								 mqtt_protocol, [{dispatch, mqtt_server}])
	end,
	{ok, Pid}.

stop(_State) ->
	timer:apply_after(0, application, stop, [ranch]).