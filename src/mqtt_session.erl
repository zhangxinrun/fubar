%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : MQTT session provides persistency for clients.
%%%
%%% Created : Nov 15, 2012
%%% -------------------------------------------------------------------
-module(mqtt_session).
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
-record(?MODULE, {client_id :: binary(),
				  clean_session = false :: boolean(),
				  will :: {binary(), binary(), mqtt_qos(), boolean()},
				  subscriptions = [] :: [{binary(), mqtt_qos()}],
				  client :: pid(),
				  transactions = [] :: [{integer(), pid(), mqtt_message()}],
				  transaction_timeout = 60000 :: timeout(),
				  message_id = 0 :: integer(),
				  buffer = [] :: [#fubar{}],
				  buffer_limit = 10 :: integer(),
				  retry_pool = [] :: [{integer(), #fubar{}, integer(), term()}],
				  max_retries = 5 :: integer(),
				  retry_after = 10000 :: timeout()}).

%%
%% Exports
%%
-export([start/1, bind/2, state/1, transaction_loop/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Start an unbound session.
-spec start(proplist(atom(), term())) -> {ok, pid()} | {error, reason()}.
start(Props) ->
	gen_server:start(?MODULE, Props, []).

%% @doc Bind a client with existing session or create a new one.
-spec bind(term(), proplist(atom(), term())) -> {ok, pid()} | {error, reason()}.
bind(ClientId, Options) ->
	case fubar_route:resolve(ClientId) of
		{ok, {undefined, ?MODULE}} ->
			{ok, Pid} = gen_server:start(?MODULE, [{client_id, ClientId} | Options], []),
			ok = gen_server:call(Pid, {bind, Options}),
			{ok, Pid};
		{ok, {Session, ?MODULE}} ->
			ok = gen_server:call(Session, {bind, Options}),
			{ok, Session};
		{error, not_found} ->
			{ok, Pid} = gen_server:start(?MODULE, [{client_id, ClientId} | Options], []),
			ok = gen_server:call(Pid, {bind, Options}),
			{ok, Pid};
		Error ->
			Error
	end.

%% @doc Get session state.
-spec state(pid()) -> #?MODULE{}.
state(Session) ->
	gen_server:call(Session, state).

init(Props) ->
	State = ?PROPS_TO_RECORD(Props++fubar:settings(?MODULE), ?MODULE),
	?DEBUG([init, State]),
	process_flag(trap_exit, true),
	% @todo implement migration from remote session when remote is set
	fubar_route:up(State#?MODULE.client_id, ?MODULE),
	{ok, State}.

%% State query for admin operation.
handle_call(state, _, State) ->
	{reply, State, State};

%% Client binding logic for mqtt_server.
handle_call({bind, Props}, {Client, _}, State=#?MODULE{client=undefined, buffer=Buffer}) ->
	?DEBUG([State#?MODULE.client_id, Client, "client up"]),
	link(Client),
	% Now flush buffer.
	lists:foreach(fun(Fubar) -> gen_server:cast(self(), Fubar) end, lists:reverse(Buffer)),
	{reply, ok, ?PROPS_TO_RECORD(Props, ?MODULE, State#?MODULE{client=Client, buffer=[]})()};
handle_call({bind, Props}, {Client, _}, State=#?MODULE{client=OldClient, buffer=Buffer}) ->
	?WARNING([State#?MODULE.client_id, Client, "client replaces", OldClient]),
	catch unlink(OldClient),
	exit(OldClient, kill),
	link(Client),
	% Now flush buffer.
	lists:foreach(fun(Fubar) -> gen_server:cast(self(), Fubar) end, lists:reverse(Buffer)),
	{reply, ok, ?PROPS_TO_RECORD(Props, ?MODULE, State#?MODULE{client=Client, buffer=[]})()};

%% Message delivery logic to the client (sync version).
handle_call(Fubar=#fubar{}, _, State=#?MODULE{client_id=ClientId, client=undefined, buffer=Buffer, buffer_limit=N}) ->
	% Got a message to deliver to the client.
	% But it's offline now, keep the message in buffer for later delivery.
	fubar:profile(ClientId, Fubar),
	{reply, ok, State#?MODULE{buffer=lists:sublist([Fubar | Buffer], N)}};
handle_call(Fubar=#fubar{}, _, State=#?MODULE{client_id=ClientId, client=Client}) ->
	% Got a message and the client is alive.
	% Let's send it to the client.
	fubar:profile(ClientId, Fubar),
	case fubar:get(payload, Fubar) of
		Message=#mqtt_publish{} ->
			case Message#mqtt_publish.qos of
				at_most_once ->
					Client ! Message,
					{reply, ok, State};
				_ ->
					MessageId = (State#?MODULE.message_id rem 16#ffff) + 1,
					NewMessage= Message#mqtt_publish{message_id=MessageId},
					Client ! NewMessage,
					{ok, Timer} = timer:send_after(State#?MODULE.retry_after, {retry, MessageId}),
					Dup = NewMessage#mqtt_publish{dup=true},
					Pool = [{MessageId, fubar:set([{payload, Dup}], Fubar), 1, Timer} | State#?MODULE.retry_pool],
					{reply, ok, State#?MODULE{message_id=MessageId, retry_pool=Pool}}
			end;
		Unknown ->
			?WARNING([ClientId, Unknown, "dropping unknown fubar"]),
			{reply, ok, State}
	end;

%% Fallback
handle_call(Request, From, State) ->
	?WARNING([State#?MODULE.client_id, Request, From, "dropping unknown call"]),
	{reply, ok, State}.

%% Message delivery logic to the client (async version).
handle_cast(Fubar=#fubar{}, State=#?MODULE{client_id=ClientId, client=undefined, buffer=Buffer, buffer_limit=N}) ->
	% Got a message to deliver to the client.
	% But it's offline now, keep the message in buffer for later delivery.
	fubar:profile(ClientId, Fubar),
	{noreply, State#?MODULE{buffer=lists:sublist([Fubar | Buffer], N)}};
handle_cast(Fubar=#fubar{}, State=#?MODULE{client_id=ClientId, client=Client}) ->
	% Got a message and the client is alive.
	% Let's send it to the client.
	fubar:profile(ClientId, Fubar),
	case fubar:get(payload, Fubar) of
		Message=#mqtt_publish{} ->
			case Message#mqtt_publish.qos of
				at_most_once ->
					Client ! Message,
					{noreply, State};
				_ ->
					MessageId = (State#?MODULE.message_id rem 16#ffff) + 1,
					NewMessage= Message#mqtt_publish{message_id=MessageId},
					Client ! NewMessage,
					{ok, Timer} = timer:send_after(State#?MODULE.retry_after, {retry, MessageId}),
					Dup = NewMessage#mqtt_publish{dup=true},
					Pool = [{MessageId, fubar:set([{payload, Dup}], Fubar), 1, Timer} | State#?MODULE.retry_pool],
					{noreply, State#?MODULE{message_id=MessageId, retry_pool=Pool}}
			end;
		Unknown ->
			?WARNING([ClientId, Unknown, "dropping unknown fubar"]),
			{noreply, State}
	end;

%% Fallback
handle_cast(Message, State) ->
	?WARNING([State#?MODULE.client_id, Message, "dropping unknown cast"]),
	{noreply, State}.

%% Message delivery logic to the client (QoS retry).
handle_info({retry, MessageId}, State=#?MODULE{client=undefined, buffer=Buffer, buffer_limit=N}) ->
	% This is a retry schedule.
	% But the client is offline.
	% Store the job back to the buffer again.
	case lists:keytake(MessageId, 1, State#?MODULE.retry_pool) of
		{value, {MessageId, Fubar, Retry, _}, Pool} ->
			case Retry < State#?MODULE.max_retries of
				true ->
					{noreply, State#?MODULE{buffer=lists:sublist([Fubar | Buffer], N, retry_pool=Pool)}};
				_ ->
					?WARNING([State#?MODULE.client_id, MessageId, "dropping after retry"]),
					{noreply, State#?MODULE{retry_pool=Pool}}
			end;
		_ ->
			?ERROR([State#?MODULE.client_id, MessageId, "not found in retry pool"]),
			{noreply, State}
	end;
handle_info({retry, MessageId}, State=#?MODULE{client=Client}) ->
	% Retry schedule arrived.
	% It is for one of publish, pubrel and pubcomp.
	case lists:keytake(MessageId, 1, State#?MODULE.retry_pool) of
		{value, {MessageId, Fubar, Retry, _}, Pool} ->
			case Retry < State#?MODULE.max_retries of
				true ->
					Client ! fubar:get(payload, Fubar),
					{ok, Timer} = timer:send_after(State#?MODULE.retry_after, {retry, MessageId}),
					{noreply, State#?MODULE{retry_pool=[{MessageId, Fubar, Retry+1, Timer} | Pool]}};
				_ ->
					?WARNING([State#?MODULE.client_id, MessageId, "dropping after retry"]),
					{noreply, State#?MODULE{retry_pool=Pool}}
			end;
		_ ->
			?ERROR([State#?MODULE.client_id, MessageId, "not found in retry pool"]),
			{noreply, State}
	end;

%% Transaction logic from the client.
handle_info(Info=#mqtt_publish{message_id=MessageId, dup=true}, State) ->
	% This is inbound duplicate publish.
	case lists:keyfind(MessageId, 1, State#?MODULE.transactions) of
		false ->
			% Not found, not very likely but treat this as a new request.
			handle_info(Info#mqtt_publish{dup=false}, State);
		{MessageId, _, _} ->
			% Found one, drop this.
			?DEBUG([State#?MODULE.client_id, MessageId, "dropping duplicate"]),
			{noreply, State}
	end;
handle_info(Info=#mqtt_publish{message_id=MessageId}, State=#?MODULE{client_id=ClientId, transactions=Transactions}) ->
	case Info#mqtt_publish.qos of
		exactly_once ->
			% Start 3-way handshake transaction.
			State#?MODULE.client ! #mqtt_pubrec{message_id=MessageId},
			Worker = proc_lib:spawn_link(?MODULE, transaction_loop, [ClientId, Info, State#?MODULE.transaction_timeout]),
			Complete = #mqtt_pubcomp{message_id=MessageId},
			{noreply, State#?MODULE{transactions=[{MessageId, Worker, Complete} | Transactions]}};
		at_least_once ->
			% Start 1-way handshake transaction.
			Worker = proc_lib:spawn_link(?MODULE, transaction_loop, [ClientId, Info, State#?MODULE.transaction_timeout]),
			Worker ! release,
			State#?MODULE.client ! #mqtt_puback{message_id=MessageId},
			{noreply, State#?MODULE{transactions=[{MessageId, Worker, undefined} | Transactions]}};
		_ ->
			catch do_async_transaction(ClientId, Info),
			{noreply, State}
	end;
handle_info(Info=#mqtt_puback{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	% The message id is supposed to be in the retry pool.
	% Find and cancel the retry schedule.
	case lists:keytake(MessageId, 1, State#?MODULE.retry_pool) of
		{value, {MessageId, Fubar, _, Timer}, Pool} ->
			timer:cancel(Timer),
			fubar:profile({ClientId, "PUBACK"}, Fubar),
			{noreply, State#?MODULE{retry_pool=Pool}};
		false ->
			?WARNING([ClientId, Info, "publish might have been abandoned"]),
			{noreply, State}
	end;
handle_info(Info=#mqtt_pubrec{message_id=MessageId}, State=#?MODULE{client_id=ClientId, client=Client}) ->
	% The message id is supposed to be in the retry pool.
	% Find, cancel the retry schedule, send pubrel and wait for pubcomp.
	case lists:keytake(MessageId, 1, State#?MODULE.retry_pool) of
		{value, {MessageId, Fubar, _, Timer}, Pool} ->
			timer:cancel(Timer),
			fubar:profile({ClientId, "PUBREC"}, Fubar),
			Reply = #mqtt_pubrel{message_id=MessageId},
			Client ! Reply,
			Fubar1 = fubar:set([{via, ClientId}, {payload, Reply}], Fubar),
			{ok, Timer1} = timer:send_after(#?MODULE.retry_after*#?MODULE.max_retries, {retry, MessageId}),
			{noreply, State#?MODULE{retry_pool=[{MessageId, Fubar1, #?MODULE.max_retries, Timer1} | Pool]}};
		false ->
			?WARNING([ClientId, Info, "publish might have been abandoned"]),
		 	{noreply, State}
	end;
handle_info(Info=#mqtt_pubrel{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	case lists:keyfind(MessageId, 1, State#?MODULE.transactions) of
		false ->
			?WARNING([ClientId, Info, "no such transaction"]),
			{noreply, State};
		{MessageId, Worker, _} ->
			Worker ! release,
			{noreply, State}
	end;
handle_info(Info=#mqtt_pubcomp{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	% The message id is supposed to be in the retry pool.
	% Find, cancel the retry schedule.
	case lists:keytake(MessageId, 1, State#?MODULE.retry_pool) of
		{value, {MessageId, Fubar, _, Timer}, Pool} ->
			timer:cancel(Timer),
			fubar:profile({ClientId, "PUBCOMP"}, Fubar),
			{noreply, State#?MODULE{retry_pool=Pool}};
		false ->
			?WARNING([ClientId, Info, "pubrel might have been abandoned"]),
			{noreply, State}
	end;
handle_info(#mqtt_subscribe{dup=true}, State) ->
	% Subscribe is performed synchronously.
	% Just drop duplicate requests.
	{noreply, State};
handle_info(Info=#mqtt_subscribe{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	QoSs = case Info#mqtt_subscribe.qos of
			   at_most_once -> % This is out-of-spec but experimental extension.
				   do_async_transaction(ClientId, Info);
			   _ ->
				   R = do_transaction(ClientId, Info, State#?MODULE.transaction_timeout),
				   State#?MODULE.client ! #mqtt_suback{message_id=MessageId, qoss=R},
				   R
		   end,
	{Topics, _} = lists:unzip(Info#mqtt_subscribe.topics),
	F = fun({Topic, QoS}, Subscriptions) ->
			lists:keystore(Topic, 1, Subscriptions, {Topic, QoS})
		end,
	{noreply, State#?MODULE{subscriptions=lists:foldl(F, State#?MODULE.subscriptions, lists:zip(Topics, QoSs))}};
handle_info(#mqtt_unsubscribe{dup=true}, State) ->
	% Unsubscribe is performed synchronously.
	% Just drop duplicate requests.
	{noreply, State};
handle_info(Info=#mqtt_unsubscribe{message_id=MessageId, topics=Topics}, State=#?MODULE{client_id=ClientId}) ->
	case Info#mqtt_unsubscribe.qos of
		at_most_once -> % This is out-of-spec but experimental extension.
			do_async_transaction(ClientId, Info);
		_ ->
			do_transaction(ClientId, Info, State#?MODULE.transaction_timeout),
			State#?MODULE.client ! #mqtt_unsuback{message_id=MessageId}
	end,
	F = fun(Topic, Subscriptions) ->
			lists:keydelete(Topic, 1, Subscriptions)
		end,
	{noreply, State#?MODULE{subscriptions=lists:foldl(F, State#?MODULE.subscriptions, Topics)}};
handle_info({'EXIT', Client, Reason}, State=#?MODULE{client=Client}) ->
	?DEBUG([State#?MODULE.client_id, Client, Reason, "client down"]),
	case State#?MODULE.clean_session of
		true ->
			{stop, normal, State#?MODULE{client=undefined}};
		_ ->
			{noreply, State#?MODULE{client=undefined}}
	end;
handle_info({'EXIT', Worker, normal}, State=#?MODULE{client_id=ClientId}) ->
	% Likely to be a transaction completion signal.
	case lists:keytake(Worker, 2, State#?MODULE.transactions) of
		{value, {MessageId, Worker, Complete}, Rest} ->
			?DEBUG([ClientId, MessageId, "transaction complete"]),
			case Complete of
				undefined -> ok;
				_ -> State#?MODULE.client ! Complete
			end,
			{noreply, State#?MODULE{transactions=Rest}};
		false ->
			?WARNING([ClientId, Worker, "transaction not found"]),
			{noreply, State}
	end;
handle_info({'EXIT', Worker, Reason}, State=#?MODULE{client_id=ClientId}) ->
	% Likely to be a transaction failure signal.
	case lists:keytake(Worker, 2, State#?MODULE.transactions) of
		{value, {MessageId, Worker, _}, Rest} ->
			?WARNING([ClientId, MessageId, Reason, "transaction failure"]),
			{noreply, State#?MODULE{transactions=Rest}};
		false ->
			?WARNING([ClientId, Worker, "transaction not found"]),
			{noreply, State}
	end;

%% Fallback
handle_info(Info, State) ->
	?WARNING([State#?MODULE.client_id, Info, "dropping unknown info"]),
	{noreply, State}.

terminate(Reason, State=#?MODULE{client_id=ClientId}) ->
	?DEBUG([ClientId, Reason, terminate]),
	MessageId = State#?MODULE.message_id rem 16#ffff + 1,
	{Topics, _} = lists:unzip(State#?MODULE.subscriptions),
	do_transaction(ClientId, mqtt:unsubscribe([{message_id, MessageId}, {topics, Topics}]), State#?MODULE.transaction_timeout),
	% @todo implement will announcement
	fubar_route:down(ClientId).

code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local
%%
transaction_loop(ClientId, Message, Timeout) ->
	?DEBUG([ClientId, mqtt:message_id(Message), "transaction open"]),
	receive
		release ->
			?DEBUG([ClientId, mqtt:message_id(Message), "transaction fired"]),
			do_transaction(ClientId, Message, Timeout)
		after Timeout ->
			exit(timeout)
	end.

do_transaction(ClientId, Message=#mqtt_publish{topic=Name}, Timeout) ->
	Fubar = fubar:create([{origin, ClientId}, {from, ClientId}, {to, Name}, {via, ClientId}, {payload, Message}]),
	case fubar_route:resolve(Name) of
		{ok, {undefined, mqtt_topic}} ->
			case mqtt_topic:start([{name, Name}]) of
				{ok, Topic} ->
					case gen_server:call(Topic, Fubar, Timeout) of
						ok -> ok;
						Error2 -> exit(Error2)
					end;
				Error3 ->
					exit(Error3)
			end;
		{ok, {undefined, _}} ->
			exit(not_found);
		{ok, {Pid, _}} ->
			case gen_server:call(Pid, Fubar, Timeout) of
				ok ->
					ok;
				Error1 ->
					exit(Error1)
			end;
		Error ->
			exit(Error)
	end;
do_transaction(ClientId, #mqtt_subscribe{topics=Topics}, Timeout) ->
	F = fun({Topic, QoS}) ->
			?DEBUG([Topic, QoS]),
			Fubar = fubar:create([{origin, ClientId}, {from, ClientId}, {to, Topic},
								  {via, ClientId}, {payload, {subscribe, QoS}}]),
			case fubar_route:ensure(Topic, mqtt_topic) of
				{ok, Pid} ->
					case catch gen_server:call(Pid, Fubar, Timeout) of
						{ok, NewQoS} -> NewQoS;
						_ -> undefined
					end;
				_ ->
					undefined
			end
		end,
	lists:map(F, Topics);
do_transaction(ClientId, #mqtt_unsubscribe{topics=Topics}, Timeout) ->
	F = fun(Topic) ->
			Fubar = fubar:create([{origin, ClientId}, {from, ClientId}, {to, Topic},
								  {via, ClientId}, {payload, unsubscribe}]),
			case fubar_route:resolve(Topic) of
				{ok, {Pid, mqtt_topic}} ->
					catch gen_server:call(Pid, Fubar, Timeout);
				_ ->
					{error, not_found}
			end
		end,
	lists:foreach(F, Topics).

do_async_transaction(ClientId, Message=#mqtt_publish{topic=Name}) ->
	Fubar = fubar:create([{origin, ClientId}, {from, ClientId}, {to, Name}, {via, ClientId}, {payload, Message}]),
	case fubar_route:resolve(Name) of
		{ok, {undefined, mqtt_topic}} ->
			case mqtt_topic:start([{name, Name}]) of
				{ok, Topic} ->
					case gen_server:cast(Topic, Fubar) of
						ok -> ok;
						Error2 -> exit(Error2)
					end;
				Error3 ->
					exit(Error3)
			end;
		{ok, {undefined, _}} ->
			exit(not_found);
		{ok, {Pid, _}} ->
			gen_server:cast(Pid, Fubar);
		Error ->
			exit(Error)
	end;
do_async_transaction(ClientId, #mqtt_subscribe{topics=Topics}) ->
	F = fun({Topic, QoS}) ->
			?DEBUG([Topic, QoS]),
			Fubar = fubar:create([{origin, ClientId}, {from, ClientId}, {to, Topic},
								  {via, ClientId}, {payload, {subscribe, QoS}}]),
			case fubar_route:ensure(Topic, mqtt_topic) of
				{ok, Pid} ->
					case catch gen_server:cast(Pid, Fubar) of
						{ok, NewQoS} -> NewQoS;
						_ -> undefined
					end;
				_ ->
					undefined
			end
		end,
	lists:map(F, Topics);
do_async_transaction(ClientId, #mqtt_unsubscribe{topics=Topics}) ->
	F = fun(Topic) ->
			Fubar = fubar:create([{origin, ClientId}, {from, ClientId}, {to, Topic},
								  {via, ClientId}, {payload, unsubscribe}]),
			case fubar_route:resolve(Topic) of
				{ok, {Pid, mqtt_topic}} ->
					catch gen_server:cast(Pid, Fubar);
				_ ->
					{error, not_found}
			end
		end,
	lists:foreach(F, Topics).

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.