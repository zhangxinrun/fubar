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
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("mqtt.hrl").
-include("sasl_log.hrl").
-include("props_to_record.hrl").

%%
%% Records and types
%%
-record(?MODULE, {name :: binary(),
				  subscribers = [] :: [{binary(), mqtt_qos(), pid(), module()}],
				  fubar :: #fubar{},
				  trace = false :: boolean()}).

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
-export([boot/0, cluster/1, start/1, state/1, trace/2]).
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

%% @doc Start or stop tracing.
trace(Topic, Value) ->
	gen_server:call(Topic, {trace, Value}).

init(State=#?MODULE{name=Name}) ->
	fubar_log:log(resource, ?MODULE, [Name, init]),
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

handle_call({trace, Value}, _, State) ->
	{reply, ok, State#?MODULE{trace=Value}};

%% Subscribe request from a client session.
handle_call(Fubar=#fubar{payload={subscribe, QoS, Module}}, {Pid, _}, State=#?MODULE{name=Name}) ->
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
			fubar_log:log(warning, ?MODULE, [Name, "not mine", Fubar]),
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
			fubar_log:log(warning, ?MODULE, [Name, "not mine", Fubar]),
			{reply, ok, State}
	end;

%% Fallback
handle_call(Request, From, State) ->
	fubar_log:log(noise, ?MODULE, [State#?MODULE.name, "unknown call", Request, From]),
	{reply, ok, State}.

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
			fubar_log:log(warning, ?MODULE, [Name, "not mine", Fubar]),
			{noreply, State}
	end;

%% Fallback
handle_cast(Message, State) ->
	fubar_log:log(noise, ?MODULE, [State#?MODULE.name, "unknown cast", Message]),
	{noreply, State}.

%% Likely to be a subscriber down event
handle_info({'EXIT', Pid, Reason}, State=#?MODULE{name=Name}) ->
	case lists:keytake(Pid, 3, State#?MODULE.subscribers) of
		{value, {ClientId, QoS, Pid, Module}, Subscribers} ->
			{noreply, State#?MODULE{subscribers=[{ClientId, QoS, undefined, Module} | Subscribers]}};
		false ->
			fubar_log:log(noise, ?MODULE, [Name, "unknown exit", Pid, Reason]),
			{noreply, State}
	end;
%% Fallback
handle_info(Info, State) ->
	fubar_log:log(noise, ?MODULE, [State#?MODULE.name, "unknown info", Info]),
	{noreply, State}.

terminate(Reason, #?MODULE{name=Name}) ->
	fubar_log:log(resource, ?MODULE, [Name, terminate, Reason]),
	fubar_route:down(Name),
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
									catch link(Addr),
									catch gen_server:cast(Addr, Fubar2),
									{ClientId, MaxQoS, Addr, Module};
								_ ->
									fubar_log:log(warning, ?MODULE, [Name, "can't ensure a subscriber", ClientId]),
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