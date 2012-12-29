%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
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
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

%%
%% Exports
%%
-export([boot/0,	% master mode bootstrap sequence
		 cluster/1,	% slave mode bootstrap sequence
		 start/1,	% start a topic
		 state/1,	% state query
		 trace/2]).	% set trace flag true/false

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("mqtt.hrl").
-include("sasl_log.hrl").
-include("props_to_record.hrl").
-include_lib("stdlib/include/qlc.hrl").

%%
%% Records and types
%%
-record(?MODULE, {name :: binary(),	% topic name
				  subscribers = [] :: [{binary(), binary(), mqtt_qos(), term(), pid(), module()}],	% [{id, client_id, qos, monitor, session, module}]
				  fubar :: #fubar{},	% retained fubar
				  trace = false :: boolean()}).	% trace flag

%% @doc Subscriber database schema.
-record(mqtt_subscriber, {id = '_' :: binary(),			% primary key
						  topic = '_' :: binary(),		% topic name
						  client_id = '_' :: binary(),	% subscriber
						  qos = '_' :: mqtt_qos(),		% max qos
						  module = '_' :: module()}).	% subscriber type

%% @doc Retained message database schema.
-record(mqtt_retained, {topic = '_' :: binary(),	% topic name
						fubar = '_' :: #fubar{}}).	% fubar to send to new subscribers

%%
%% Callbacks
%%
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Master mode bootstrap logic.
boot() ->
	case mnesia:create_table(mqtt_subscriber, [{attributes, record_info(fields, mqtt_subscriber)},
											   {disc_copies, [node()]}, {type, set},
											   {index, [topic, client_id]}]) of
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
state(Topic) when is_pid(Topic) ->
	gen_server:call(Topic, state);
state(Name) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE}} ->
			{error, inactive};
		{ok, {Topic, ?MODULE}} ->
			state(Topic);
		Error ->
			Error
	end.

%% @doc Start or stop tracing.
trace(Topic, Value) when is_pid(Topic) ->
	gen_server:call(Topic, {trace, Value});
trace(Name, Value) ->
	case fubar_route:ensure(Name, ?MODULE) of
		{ok, Topic} ->
			trace(Topic, Value);
		Error ->
			Error
	end.

init(State=#?MODULE{name=Name}) ->
	% Restore all the subscriptions and retained message from database.
	process_flag(trap_exit, true),
	Q = qlc:q([{Id, ClientId, QoS, undefined, undefined, Module} ||
				   #mqtt_subscriber{id=Id, topic=Topic, client_id=ClientId, qos=QoS, module=Module}
					   <- mnesia:table(mqtt_subscriber),
				   Topic =:= Name]),
	Subscribers = mnesia:async_dirty(fun() -> qlc:e(Q) end),
	Fubar = case mnesia:dirty_read(mqtt_retained, Name) of
				[#mqtt_retained{topic=Name, fubar=Value}] -> Value;
				[] -> undefined
			end,
	case fubar_route:up(Name, ?MODULE) of
		ok ->
			fubar_log:resource(?MODULE, [Name, init]),
			{ok, State#?MODULE{subscribers=Subscribers, fubar=Fubar}};
		Error ->
			fubar_log:error(?MODULE, [Name, init, Error]),
			{stop, Error}
	end.

%% State query for admin operation.
handle_call(state, _, State) ->
	{reply, State, State};

handle_call({trace, Value}, _, State) ->
	{reply, ok, State#?MODULE{trace=Value}};

%% Subscribe request from a client session.
handle_call(Fubar=#fubar{payload={subscribe, QoS, Module, Pid}}, _, State=#?MODULE{name=Name}) ->
	case fubar:get(to, Fubar) of
		Name ->
			fubar_log:trace({Name, subscribe}, Fubar),
			Subscribers = subscribe(Name, {fubar:get(from, Fubar), Pid}, {QoS, Module}, State#?MODULE.subscribers),
			case State#?MODULE.fubar of
				undefined ->
					ok;
				Retained ->
					gen_server:cast(Pid, fubar:set([{to, fubar:get(from, Fubar)}, {via, Name}], Retained))
			end,
			{reply, {ok, QoS}, State#?MODULE{subscribers=Subscribers}};
		_ ->
			fubar_log:warning(?MODULE, [Name, "not mine", Fubar]),
			{reply, ok, State}
	end;

%% Unsubscribe request from a client session.
handle_call(Fubar=#fubar{payload=unsubscribe}, _, State=#?MODULE{name=Name}) ->
	case fubar:get(to, Fubar) of
		Name ->
			fubar_log:trace({Name, unsubscribe}, Fubar),
			Subscribers = unsubscribe(Name, fubar:get(from, Fubar), State#?MODULE.subscribers),
			{reply, ok, State#?MODULE{subscribers=Subscribers}};
		_ ->
			fubar_log:warning(?MODULE, [Name, "not mine", Fubar]),
			{reply, ok, State}
	end;

%% Fallback
handle_call(Request, From, State) ->
	fubar_log:debug(?MODULE, [State#?MODULE.name, "unknown call", Request, From]),
	{reply, ok, State}.

%% Subscribe request from a client session.
handle_cast(Fubar=#fubar{payload={subscribe, QoS, Module, Pid}}, State=#?MODULE{name=Name}) ->
	case fubar:get(to, Fubar) of
		Name ->
			fubar_log:trace({Name, subscribe}, Fubar),
			Subscribers = subscribe(Name, {fubar:get(from, Fubar), Pid}, {QoS, Module}, State#?MODULE.subscribers),
			case State#?MODULE.fubar of
				undefined ->
					ok;
				Retained ->
					gen_server:cast(Pid, fubar:set([{to, fubar:get(from, Fubar)}, {via, Name}], Retained))
			end,
			{noreply, State#?MODULE{subscribers=Subscribers}};
		_ ->
			fubar_log:warning(?MODULE, [Name, "not mine", Fubar]),
			{noreply, State}
	end;

%% Unsubscribe request from a client session.
handle_cast(Fubar=#fubar{payload=unsubscribe}, State=#?MODULE{name=Name}) ->
	case fubar:get(to, Fubar) of
		Name ->
			fubar_log:trace({Name, unsubscribe}, Fubar),
			Subscribers = unsubscribe(Name, fubar:get(from, Fubar), State#?MODULE.subscribers),
			{noreply, State#?MODULE{subscribers=Subscribers}};
		_ ->
			fubar_log:warning(?MODULE, [Name, "not mine", Fubar]),
			{noreply, State}
	end;

%% Publish request.
handle_cast(Fubar=#fubar{payload=#mqtt_publish{}}, State=#?MODULE{name=Name, trace=Trace}) ->
	case fubar:get(to, Fubar) of
		Name ->
			fubar_log:trace({Name, publish}, Fubar),
			{Fubar1, Subscribers} = publish(Name, Fubar, State#?MODULE.subscribers, Trace),
			Publish = fubar:get(payload,Fubar1),
			case Publish#mqtt_publish.retain of
				true ->
					mnesia:dirty_write(#mqtt_retained{topic=Name, fubar=Fubar1}),
					{noreply, State#?MODULE{fubar=Fubar1, subscribers=Subscribers}};
				_ ->
					{noreply, State#?MODULE{subscribers=Subscribers}}
			end;
		_ ->
			fubar_log:warning(?MODULE, [Name, "not mine", Fubar]),
			{noreply, State}
	end;

%% Fallback
handle_cast(Message, State) ->
	fubar_log:debug(?MODULE, [State#?MODULE.name, "unknown cast", Message]),
	{noreply, State}.

%% Likely to be a subscriber down event
handle_info({'DOWN', Monitor, _, Pid, Reason}, State=#?MODULE{name=Name}) ->
	case lists:keytake(Monitor, 4, State#?MODULE.subscribers) of
		{value, {Id, ClientId, QoS, Monitor, Pid, Module}, Subscribers} ->
			fubar_log:debug(?MODULE, [Name, "subscriber down", Pid, Reason]),
			{noreply, State#?MODULE{subscribers=[{Id, ClientId, QoS, undefined, undefined, Module} | Subscribers]}};
		false ->
			fubar_log:debug(?MODULE, [Name, "unknown down", Pid, Reason]),
			{noreply, State}
	end;
%% Fallback
handle_info(Info, State) ->
	fubar_log:debug(?MODULE, [State#?MODULE.name, "unknown info", Info]),
	{noreply, State}.

terminate(Reason, #?MODULE{name=Name}) ->
	case fubar_route:down(Name) of
		ok ->
			fubar_log:resource(?MODULE, [Name, terminate, Reason]);
		Error ->
			fubar_log:error(?MODULE, [Name, terminate, Reason, Error])
	end,
	Reason.
	
code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local
%%
publish(Name, Fubar, Subscribers, Trace) ->
	From = fubar:get(from, Fubar),
	Updates = [{from, Name}, {via, Name}],
	Fubar1 = case fubar:get(id, Fubar) of
				 undefined -> % non-tracing fubar
					 case Trace of
						 true -> fubar:set([{id, uuid:uuid4()} | Updates], Fubar);
						 _ -> fubar:set(Updates, Fubar)
					 end;
				 _ ->
					 fubar:set(Updates, Fubar)
			 end,
	Publish = fubar:get(payload, Fubar1),
	QoS = Publish#mqtt_publish.qos,
	F = fun({Id, ClientId, MaxQoS, Monitor, Pid, Module}) ->
			case ClientId of
				From ->
					% Don't send the message to the sender back.
					{Id, ClientId, MaxQoS, Monitor, Pid, Module};
				_ ->
					Publish1 = Publish#mqtt_publish{qos=mqtt:degrade(QoS, MaxQoS)},
					Fubar2 = fubar:set([{to, ClientId}, {payload, Publish1}], Fubar1),
					case Pid of
						undefined ->
							case fubar_route:ensure(ClientId, Module) of
								{ok, Addr} ->
									NewMonitor = monitor(process, Addr),
									catch gen_server:cast(Addr, Fubar2),
									{Id, ClientId, MaxQoS, NewMonitor, Addr, Module};
								_ ->
									fubar_log:error(?MODULE, [Name, "can't ensure a subscriber", ClientId]),
									{Id, ClientId, MaxQoS, undefined, undefined, Module}
							end;
						_ ->
							catch gen_server:cast(Pid, Fubar2),
							{Id, ClientId, MaxQoS, Monitor, Pid, Module}
					end
			end
		end,
	{Fubar1, lists:map(F, Subscribers)}.

subscribe(Name, {ClientId, Pid}, {QoS, Module}, Subscribers) ->
	% Check if it's a new subscription or not.
	case lists:keytake(ClientId, 2, Subscribers) of
		{value, {Id, ClientId, QoS, OldMonitor, _, Module}, Rest} ->
			% The same subscription from possibly different client.
			catch demonitor(OldMonitor, [flush]),
			Monitor = monitor(process, Pid),
			[{Id, ClientId, QoS, Monitor, Pid, Module} | Rest];
		{value, {Id, ClientId, _, OldMonitor, _, _}, Rest} ->
			% Need to update the subscription.
			catch demonitor(OldMonitor, [flush]),
			mnesia:dirty_write(#mqtt_subscriber{id=Id, topic=Name, client_id=ClientId, qos=QoS, module=Module}),
			Monitor = monitor(process, Pid),
			[{Id, ClientId, QoS, Monitor, Pid, Module} | Rest];
		false ->
			% Not found.  This is a new one.
			Id = uuid:uuid4(),
			mnesia:dirty_write(#mqtt_subscriber{id=Id, topic=Name, client_id=ClientId, qos=QoS, module=Module}),
			Monitor = monitor(process, Pid),
			[{Id, ClientId, QoS, Monitor, Pid, Module} | Subscribers]
	end.

unsubscribe(_Name, ClientId, Subscribers) ->
	case lists:keytake(ClientId, 2, Subscribers) of
		{value, {Id, ClientId, _, Monitor, _, _}, Rest} ->
			catch demonitor(Monitor, [flush]),
			mnesia:dirty_delete({mqtt_subscriber, Id}),
			Rest;
		false ->
			Subscribers
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.