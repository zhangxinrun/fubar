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
-bootstrap_slave(cluster).

%%
%% Includes
%%
-include("fubar.hrl").
-include("log.hrl").
-include("props_to_record.hrl").

%%
%% Records
%%
-record(settings, {acceptors = 100 :: integer(),
				   max_connections = infinity :: timeout()}).

%%
%% Exports
%%
-export([boot/0, cluster/1, start/2, stop/1]).

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
	mqtt_account:boot(),
	mqtt_topic:boot().

%% @doc Slave mode bootstrap logic.
cluster(MasterNode) ->
	ok = application:start(mnesia),
	pong = net_adm:ping(MasterNode),
	{ok, _} = rpc:call(MasterNode, mnesia, change_config, [extra_db_nodes, [node()]]),
	{atomic, ok} = mnesia:change_table_copy_type(schema, node(), disc_copies),
	?INFO({"clustered with", MasterNode}),
	fubar_route:cluster(MasterNode),
	mqtt_account:cluster(MasterNode),
	mqtt_topic:cluster(MasterNode).

%%
%% Application callbacks
%%
start(_StartType, _StartArgs) ->
	Props = fubar:settings(?MODULE),
	?INFO({"loaded settings", Props}),
	Settings = ?PROPS_TO_RECORD(Props, settings),
	fubar_sup:start_link(),
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
	{MQTTPort, _} = string:to_integer(os:getenv("MQTT_PORT")),
	ranch:start_listener(mqtt_listener, Settings#settings.acceptors,
						 ranch_tcp, [{port, MQTTPort},
									 {max_connections, Settings#settings.max_connections}],
						 mqtt_protocol, [{dispatch, mqtt_server}]).

stop(_State) ->
	ok.