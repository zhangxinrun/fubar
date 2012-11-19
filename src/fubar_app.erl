%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : fubar application callback.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(fubar_app).
-author("Sungjin Park <jinni.park@sk.com>").
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
-record(settings, {role = master :: master | {slave, node()},
				   acceptors = 100 :: integer(),
				   port = 1883 :: integer()}).

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
	case Settings#settings.role of
		master ->
			fubar:apply_all_module_attributes_of(bootstrap_master);
		{slave, MasterNode} ->
			fubar:apply_all_module_attributes_of({bootstrap_slave, [MasterNode]})
	end,
	application:start(ranch),
	ranch:start_listener(mqtt_listener, Settings#settings.acceptors,
						 ranch_tcp, [{port, Settings#settings.port}],
						 mqtt_protocol, [{dispatch, mqtt_server}]).

stop(_State) ->
	ok.