%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : MQTT topic endpoint for fubar system.
%%%    This performs mqtt pubsub in fubar messaging system.  It is
%%% another mqtt endpoint with mqtt_session.  This is designed to form
%%% hierarchical subscription relationships among themselves to scale
%%% more than millions of subscribers in a logical topic.
%%%
%%% Created : Nov 18, 2012
%%% -------------------------------------------------------------------
-module(mqtt_topic).
-author("Sungjin Park <jinni.park@sk.com>").
-behavior(gen_server).

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("mqtt.hrl").
-include("log.hrl").
-include("props_to_record.hrl").

%%
%% Records and types
%%
-record(?MODULE, {name :: binary(),
				  subscribers = [] :: [{binary(), mqtt_qos(), pid(), module()}],
				  fubar :: #fubar{},
				  timeout = 10000 :: timeout()}).

%% @doc Subscriber database schema.
-record(mqtt_subscriber, {topic = '_' :: binary(),
						  client_id = '_' :: binary(),
						  qos = '_' :: mqtt_qos(),
						  module = '_' :: module()}).

%% @doc Retained message database schema.
-record(mqtt_retained, {topic = '_' :: binary(),
						fubar = '_' :: #fubar{}}).

%%
%% Exports
%%
-export([boot/0, cluster/1, start/1, state/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Master mode bootstrap logic.
boot() ->
	case mnesia:create_table(mqtt_subscriber, [{attributes, record_info(fields, mqtt_subscriber)},
											   {disc_copies, [node()]}, {type, bag},
											   {index, [client_id]}]) of
		{atomic, ok} ->
			?INFO({"table created", mqtt_subscriber}),
			ok;
		{aborted, {already_exists, mqtt_subscriber}} ->
			ok
	end,
	case mnesia:create_table(mqtt_retained, [{attributes, record_info(fields, mqtt_retained)},
											 {disc_copies, [node()]}, {type, set},
											 {local_content, true}]) of
		{atomic, ok} ->
			?INFO({"table created", mqtt_retained}),
			ok;
		{aborted, {already_exists, mqtt_retained}} ->
			ok
	end,
	ok = mnesia:wait_for_tables([mqtt_subscriber, mqtt_retained], 10000),
	?INFO({"table loaded", [mqtt_subscriber, mqtt_retained]}).

%% @doc Slave mode bootstrap logic.
cluster(_MasterNode) ->
	{atomic, ok} = mnesia:add_table_copy(mqtt_subscriber, node(), disc_copies),
	{atomic, ok} = mnesia:add_table_copy(mqtt_retained, node(), disc_copies),
	?INFO({"table created", [mqtt_subscriber, mqtt_retained]}).

%% @doc Start a topic.
start(Props) ->
	State = ?PROPS_TO_RECORD(Props, ?MODULE),
	gen_server:start(?MODULE, State, []).

%% @doc State query.
state(Topic) ->
	gen_server:call(Topic, state).

init(State=#?MODULE{name=Name}) ->
	?DEBUG([init, Name]),
	% Restore all the subscriptions and retained message from database.
	process_flag(trap_exit, true),
	Subscribers = mnesia:dirty_read(mqtt_subscriber, Name),
	Fubar = case mnesia:dirty_read(mqtt_retained, Name) of
				[#mqtt_retained{topic=Name, fubar=Value}] -> Value;
				[] -> undefined
			end,
	fubar_route:up(State#?MODULE.name, ?MODULE),
	F = fun(#mqtt_subscriber{client_id=ClientId, qos=QoS, module=Module}) ->
			{ClientId, QoS, undefined, Module}
		end,
	{ok, State#?MODULE{subscribers=lists:map(F, Subscribers), fubar=Fubar}}.

%% State query for admin operation.
handle_call(state, _, State) ->
	{reply, State, State};

%% Publish request.
handle_call(Fubar=#fubar{to={Name, _}, payload=#mqtt_publish{}}, _, State=#?MODULE{name=Name}) ->
	fubar:profile({Name, publish, sync}, Fubar),
	{Fubar1, Subscribers} = publish(Name, Fubar, State#?MODULE.subscribers),
	Publish = fubar:get(payload,Fubar1),
	case Publish#mqtt_publish.retain of
		true ->
			mnesia:dirty_write(#mqtt_retained{topic=Name, fubar=Fubar1}),
			{reply, ok, State#?MODULE{fubar=Fubar1, subscribers=Subscribers}};
		_ ->
			{reply, ok, State#?MODULE{subscribers=Subscribers}}
	end;

%% Subscribe request from a client session.
handle_call(Fubar=#fubar{from={ClientId, _}, to={Name, _}, payload={subscribe, QoS, Module}}, {Pid, _}, State=#?MODULE{name=Name}) ->
	% Check if it's a new subscription or not.
	fubar:profile({Name, subscribe}, Fubar),
	Subscribers = subscribe(Name, {ClientId, Pid}, {QoS, Module}, State#?MODULE.subscribers),
	case State#?MODULE.fubar of
		undefined ->
			ok;
		Retained ->
			gen_server:cast(Pid, fubar:set([{to, ClientId}, {via, Name}], Retained))
	end,
	{reply, {ok, QoS}, State#?MODULE{subscribers=Subscribers}};

%% Unsubscribe request from a client session.
handle_call(Fubar=#fubar{from={ClientId, _}, to={Name, _}, payload=unsubscribe}, _, State=#?MODULE{name=Name}) ->
	fubar:profile({Name, unsubscribe}, Fubar),
	Subscribers = unsubscribe(Name, ClientId, State#?MODULE.subscribers),
	{reply, ok, State#?MODULE{subscribers=Subscribers}};

%% Fallback
handle_call(Request, From, State) ->
	?WARNING([State#?MODULE.name, Request, From, "dropping unknown call"]),
	{reply, ok, State}.

%% Publish request (async version).
handle_cast(Fubar=#fubar{to={Name, _}, payload=#mqtt_publish{}}, State=#?MODULE{name=Name}) ->
	fubar:profile({Name, publish}, Fubar),
	{Fubar1, Subscribers} = publish(Name, Fubar, State#?MODULE.subscribers),
	Publish = fubar:get(payload,Fubar1),
	case Publish#mqtt_publish.retain of
		true ->
			mnesia:dirty_write(#mqtt_retained{topic=Name, fubar=Fubar1}),
			{noreply, State#?MODULE{fubar=Fubar1, subscribers=Subscribers}};
		_ ->
			{noreply, State#?MODULE{subscribers=Subscribers}}
	end;

%% Subscribe request from the client (async version).
handle_cast(Fubar=#fubar{from={ClientId, _}, to={Name, _}, payload={subscribe, QoS, Module}}, State=#?MODULE{name=Name}) ->
	% Check if it's a new subscription or not.
	fubar:profile({Name, subscribe, async}, Fubar),
	Pid = case fubar_route:resolve(ClientId) of
			  {ok, {Addr, _}} -> Addr;
			  _ -> undefined
		  end,
	Subscribers = subscribe(Name, {ClientId, Pid}, {QoS, Module}, State#?MODULE.subscribers),
	case State#?MODULE.fubar of
		undefined ->
			ok;
		Retained ->
			gen_server:cast(Pid, fubar:set([{to, ClientId}, {via, Name}], Retained))
	end,
	{noreply, State#?MODULE{subscribers=Subscribers}};

%% Unsubscribe request from a client session (async version).
handle_cast(Fubar=#fubar{from={ClientId, _}, to={Name, _}, payload=unsubscribe}, State=#?MODULE{name=Name}) ->
	fubar:profile({Name, unsubscribe, async}, Fubar),
	Subscribers = unsubscribe(Name, ClientId, State#?MODULE.subscribers),
	{noreply, State#?MODULE{subscribers=Subscribers}};

%% Fallback
handle_cast(Message, State) ->
	?WARNING([State#?MODULE.name, Message, "dropping unknown cast"]),
	{noreply, State}.

%% Likely to be a subscriber down event
handle_info({'EXIT', Pid, Reason}, State) ->
	case lists:keytake(Pid, 3, State#?MODULE.subscribers) of
		{value, {ClientId, QoS, Pid, Module}, Subscribers} ->
			{noreply, State#?MODULE{subscribers=[{ClientId, QoS, undefined, Module} | Subscribers]}};
		false ->
			?WARNING([State#?MODULE.name, Pid, Reason, "unknown exit signal"]),
			{noreply, State}
	end;
%% Fallback
handle_info(Info, State) ->
	?WARNING([State#?MODULE.name, Info, "dropping unknown info"]),
	{noreply, State}.

terminate(Reason, #?MODULE{name=Name}) ->
	?DEBUG([Name, Reason, terminate]),
	fubar_route:down(Name),
	Reason.
	
code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local
%%
publish(Name, Fubar, Subscribers) ->
	From = fubar:get(from, Fubar),
	Fubar1 = fubar:set([{from, Name}, {via, Name}], Fubar),
	Publish = fubar:get(payload, Fubar1),
	QoS = Publish#mqtt_publish.qos,
	F = fun({ClientId, MaxQoS, Pid, Module}) ->
			case ClientId of
				From ->
					% Don't send the message to the sender back.
					{ClientId, MaxQoS, Pid, Module};
				_ ->
					Publish1 = Publish#mqtt_publish{qos=mqtt:degrade(QoS, MaxQoS)},
					Fubar2 = fubar:set([{to, ClientId}, {payload, Publish1}], Fubar1),
					case Pid of
						undefined ->
							case fubar_route:ensure(ClientId, Module) of
								{ok, Addr} ->
									catch gen_server:cast(Addr, Fubar2),
									{ClientId, MaxQoS, Addr, Module};
								_ ->
									?ERROR([Name, ClientId, "cannot ensure subscriber, something wrong"]),
									{ClientId, MaxQoS, undefined, Module}
							end;
						_ ->
							catch gen_server:cast(Pid, Fubar2),
							{ClientId, MaxQoS, Pid, Module}
					end
			end
		end,
	{Fubar1, lists:map(F, Subscribers)}.

subscribe(Name, {ClientId, Pid}, {QoS, Module}, Subscribers) ->
	% Check if it's a new subscription or not.
	case lists:keytake(ClientId, 1, Subscribers) of
		{value, {ClientId, QoS, OldPid, Module}, Rest} ->
			% The same subscription from possibly different client.
			catch unlink(OldPid),
			catch link(Pid),
			[{ClientId, QoS, Pid, Module} | Rest];
		{value, {ClientId, _OldQoS, OldPid, _OldModule}, Rest} ->
			% Need to update the subscription.
			catch unlink(OldPid),
			case mnesia:dirty_match_object(#mqtt_subscriber{topic=Name, client_id=ClientId}) of
				[] ->
					ok;
				OldSubscribers ->
					F = fun(Subscriber) ->
							mnesia:dirty_delete_object(Subscriber)
						end,
					lists:foreach(F, OldSubscribers)
			end,
			mnesia:dirty_write(#mqtt_subscriber{topic=Name, client_id=ClientId, qos=QoS, module=Module}),
			catch link(Pid),
			[{ClientId, QoS, Pid, Module} | Rest];
		false ->
			% Not found.  This is a new one.
			mnesia:dirty_write(#mqtt_subscriber{topic=Name, client_id=ClientId, qos=QoS, module=Module}),
			catch link(Pid),
			[{ClientId, QoS, Pid, Module} | Subscribers]
	end.

unsubscribe(Name, ClientId, Subscribers) ->
	case lists:keytake(ClientId, 1, Subscribers) of
		{value, {ClientId, _, Pid, _}, Rest} ->
			catch unlink(Pid),
			case mnesia:dirty_match_object(#mqtt_subscriber{topic=Name, client_id=ClientId}) of
				[] ->
					ok;
				OldSubscribers ->
					F = fun(Subscriber) ->
							catch mnesia:dirty_delete_object(Subscriber)
						end,
					lists:foreach(F, OldSubscribers)
			end,
			Rest;
		false ->
			Subscribers
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.