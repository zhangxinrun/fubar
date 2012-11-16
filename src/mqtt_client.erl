%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : MQTT tty client prints messages received to tty.
%%%
%%% Created : Nov 15, 2012
%%% -------------------------------------------------------------------
-module(mqtt_client).
-author("Sungjin Park <jinni.park@sk.com>").

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
%% Macros, records and types
%%
-define(TIMEOUT, 30000).

-type timer() :: term().

-record(?MODULE, {client_id :: binary(),
				will :: {binary(), binary(), mqtt_qos(), boolean()},
				clean_session = false :: boolean(),
				timeout = 30000 :: timeout(),
				timestamp :: timestamp(),
				timer :: timer(),
				state = connecting :: connecting | connected | disconnecting,
				message_id = 0 :: integer(),
				transactions = [] :: [{integer(), mqtt_message(), integer(), timer()}],
				max_retries = 3 :: integer,
				retry_after = 10000 :: timeout(),
				recbuf = [] :: [{integer(), mqtt_message(), integer(), timer()}]}).

-type state() :: #?MODULE{}.
-type event() :: any().

%%
%% Exports
%%
-export([start/1, stop/1, state/1]).
-export([init/1, handle_message/2, handle_event/2, terminate/1]).

%% @doc Start an MQTT client with parameters.
%%      Parameters(defaults):
%%        host(localhost), port(1443), username(undefined), password(undefined),
%%        client_id(<<>>), keep_alive(600), will_topic(undefined),
%%        will_message(undefined), will_qos(at_most_once), will_retain(false),
%%        clean_session(false)
-spec start(proplist(atom(), term())) -> pid().
start(Props) ->
	{ok, Client} = mqtt_protocol:start([{dispatch, ?MODULE}]),
	Client ! mqtt:connect(Props),
	Client.

%% @doc Stop an MQTT client process.
-spec stop(pid()) -> ok.
stop(Client) ->
	Client ! #mqtt_disconnect{},
	mqtt_protocol:stop(Client).

%% @doc Get internal state of an MQTT client process.
-spec state(pid()) -> {ok, #?MODULE{}} | {error, reason()}.
state(Client) ->
	Client ! {state, self()},
	receive
		Any ->
			{ok, Any}
		after 5000 ->
			{error, timeout}
	end.

%%
%% Callback Functions
%%

%% @doc Initialize the client process.
%% This is called when the connection is established.
-spec init(proplist(atom(), term())) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason()}.
init(Props) ->
	?DEBUG([init, Props]),
	State = ?PROPS_TO_RECORD(Props, ?MODULE),
	% Setting timeout is default for ping.
	% Set timestamp as now() and timeout to reset next ping schedule.
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle MQTT messages.
%% This is called when a message arrives.
-spec handle_message(mqtt_message(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_message(Message, State=#?MODULE{client_id=undefined}) ->
	% Drop messages from the server before CONNECT.
	% Ping schedule can be reset because we got a packet anyways.
	?WARNING([undefined, "<=", Message, "dropping"]),
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_connack{code=Code}, State=#?MODULE{client_id=ClientId, state=connecting}) ->
	% Received connack while waiting for one.
	case Code of
		accepted ->
			?INFO([ClientId, "<=", Message]),
			{noreply, State#?MODULE{state=connected, timestamp=now()}, State#?MODULE.timeout};
		unavailable ->
			?WARNING([ClientId, "<=", Message, "need to restart"]),
			{stop, unavailable, State};
		_ ->
			?ERROR([ClientId, "<=", Message, "stopping"]),
			{stop, normal, State}
	end;
handle_message(Message, State=#?MODULE{client_id=ClientId, state=connecting}) ->
	% Drop messages from the server before CONNACK.
	?WARNING([ClientId, "<=", Message, "dropping"]),
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message, State=#?MODULE{client_id=ClientId, state=disconnecting}) ->
	% Drop messages after DISCONNECT.
	?WARNING([ClientId, "<=", Message, "dropping"]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_message(#mqtt_pingresp{}, State) ->
	% Cancel expiration schedule if there is one.
	timer:cancel(State#?MODULE.timer),
	?DEBUG([State#?MODULE.client_id, "<= PINGRESP"]),
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_suback{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	timer:cancel(State#?MODULE.timer),
	% Release the subscribe transaction.
	case lists:keytake(MessageId, 1, State#?MODULE.transactions) of
		{value, {MessageId, Request, _, Timer}, Rest} ->
			?INFO([ClientId, "<=", Message, "for", Request, "transaction complete"]),
			timer:cancel(Timer),
			{noreply, State#?MODULE{timestamp=now(), transactions=Rest}, State#?MODULE.timeout};
		_ ->
			?WARNING([ClientId, "<=", Message, "transaction not found"]),
			{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}
	end;
handle_message(Message=#mqtt_publish{message_id=MessageId, dup=false}, State=#?MODULE{client_id=ClientId}) ->
	timer:cancel(State#?MODULE.timer),
	% This is the very point to print a message received.
	?INFO([ClientId, "<=", Message]),
	case Message#mqtt_publish.qos of
		exactly_once ->
			% Transaction via 3-way handshake.
			Reply = #mqtt_pubrec{message_id=MessageId},
			{ok, Timer} = timer:send_after(State#?MODULE.retry_after*State#?MODULE.max_retries, {retry, MessageId}),
			Recbuf = [{MessageId, Reply, State#?MODULE.max_retries, Timer} | State#?MODULE.recbuf],
			?DEBUG([ClientId, "=>", Reply, "transaction start"]),
			{reply, Reply, State#?MODULE{timestamp=now(), recbuf=Recbuf}, State#?MODULE.timeout};
		at_least_once ->
			% Transaction via 1-way handshake.
			{reply, #mqtt_puback{message_id=MessageId}, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
		_ ->
			{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}
	end;
handle_message(Message=#mqtt_publish{message_id=MessageId}, State) ->
	timer:cancel(State#?MODULE.timer),
	% Duplicate message.  Check receive buffer.
	case lists:keyfind(MessageId, 1, State#?MODULE.recbuf) of
		false ->
			% Not found.  Treate it as a new message.
			handle_message(Message#mqtt_publish{dup=false}, State);
		_ ->
			% Otherwise, just ignore it.
			?DEBUG([State#?MODULE.client_id, "<=", Message, "dropping duplicate"]),
			{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}
	end;
handle_message(Message=#mqtt_puback{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	timer:cancel(State#?MODULE.timer),
	% Complete a 1-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?MODULE.transactions) of
		{value, {MessageId, Request, _, Timer}, Rest} ->
			?INFO([ClientId, "<=", Message, "for", Request, "transaction complete"]),
			timer:cancel(Timer),
			{noreply, State#?MODULE{timestamp=now(), transactions=Rest}, State#?MODULE.timeout};
		_ ->
			?WARNING([ClientId, "<=", Message, "transaction not found"]),
			{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}
	end;
handle_message(Message=#mqtt_pubrec{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	timer:cancel(State#?MODULE.timer),
	% Commit a 3-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?MODULE.transactions) of
		{value, {MessageId, Request, _, Timer}, Rest} ->
			?DEBUG([ClientId, "<=", Message, "for", Request, "transaction ready"]),
			timer:cancel(Timer),
			Reply = #mqtt_pubrel{message_id=MessageId},
			{ok, Timer} = timer:send_after(State#?MODULE.retry_after*State#?MODULE.max_retries, {retry, MessageId}),
			Pool = [{MessageId, Reply, State#?MODULE.max_retries, Timer} | Rest],
			?DEBUG([ClientId, "=>", Reply, "for", Message, "transaction commit"]),
			{reply, Reply, State#?MODULE{timestamp=now(), transactions=Pool}, State#?MODULE.timeout};
		_ ->
			?WARNING([ClientId, "<=", Message, "transaction not found"]),
			{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}
	end;
handle_message(Message=#mqtt_pubrel{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	timer:cancel(State#?MODULE.timer),
	% Complete a server-driven 3-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?MODULE.recbuf) of
		{value, {MessageId, Request, _, Timer}, Rest} ->
			?DEBUG([ClientId, "<=", Message, "for", Request, "transaction fire"]),
			timer:cancel(Timer),
			Reply = #mqtt_pubcomp{message_id=MessageId},
			?DEBUG([ClientId, "=>", Reply, "for", Message]),
			{reply, Reply, State#?MODULE{timestamp=now(), recbuf=Rest}, State#?MODULE.timeout};
		_ ->
			?WARNING([ClientId, "<=", Message, "transaction not found"]),
			{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}
	end;
handle_message(Message=#mqtt_pubcomp{message_id=MessageId}, State=#?MODULE{client_id=ClientId}) ->
	timer:cancel(State#?MODULE.timer),
	% Complete a 3-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?MODULE.transactions) of
		{value, {MessageId, Request, _, Timer}, Rest} ->
			?INFO([ClientId, "<=", Message, "for", Request, "transaction complete"]),
			timer:cancel(Timer),
			{noreply, State#?MODULE{timestamp=now(), transactions=Rest}, State#?MODULE.timeout};
		_ ->
			?WARNING([ClientId, "<=", Message, "transaction not found"]),
			{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}
	end;
handle_message(Message, State) ->
	% Drop unknown messages from the server.
	?WARNING([State#?MODULE.client_id, "<=", Message, "dropping unknown message"]),
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle internal events.
-spec handle_event(event(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_event({state, From}, State) ->
	From ! State,
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_event(Event=#mqtt_connect{}, State=#?MODULE{client_id=undefined}) ->
	?INFO([Event#mqtt_connect.client_id, "=>", Event]),
	{reply, Event, State#?MODULE{client_id=Event#mqtt_connect.client_id,
								 will=case Event#mqtt_connect.will_topic of
										  undefined -> undefined;
										  Topic -> {Topic, Event#mqtt_connect.will_message,
													Event#mqtt_connect.will_qos, Event#mqtt_connect.will_retain}
									  end,
								 clean_session=Event#mqtt_connect.clean_session,
								 timeout=case Event#mqtt_connect.keep_alive of
											 infinity -> infinity;
											 KeepAlive -> KeepAlive*1000
										 end,
								 timestamp=now(),
								 state=connecting}, State#?MODULE.timeout};
handle_event(timeout, State=#?MODULE{client_id=undefined}) ->
	?ERROR([unidentified, timeout, "this is impossible"]),
	{stop, normal, State};
handle_event(timeout, State=#?MODULE{client_id=ClientId, state=connecting}) ->
	?WARNING([ClientId, "CONNECT timed out"]),
	{stop, no_connack, State};
handle_event(Event, State=#?MODULE{client_id=ClientId, state=connecting}) ->
	?WARNING([ClientId, Event, "not connected yet, dropping"]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_event(timeout, State) ->
	?DEBUG([State#?MODULE.client_id, "=> PINGREQ"]),
	{ok, Timer} = timer:send_after(State#?MODULE.retry_after, no_pingresp),
	{reply, #mqtt_pingreq{}, State#?MODULE{timestamp=now(), timer=Timer}, State#?MODULE.timeout};
handle_event(no_pingresp, State=#?MODULE{client_id=ClientId}) ->
	?WARNING([ClientId, "PINGREQ timed out"]),
	{stop, no_pingresp, State};
handle_event(Event=#mqtt_subscribe{}, State) ->
	?DEBUG([State#?MODULE.client_id, "=>", Event]),
	case Event#mqtt_subscribe.qos of
		at_most_once ->
			% This is out of spec. but trying.  Why not?
			timer:cancel(State#?MODULE.timer),
			{reply, Event, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
		_ ->
			MessageId = State#?MODULE.message_id rem 16#ffff + 1,
			Message = Event#mqtt_subscribe{message_id=MessageId, qos=at_least_once},
			Dup = Message#mqtt_subscribe{dup=true},
			{ok, Timer} = timer:send_after(State#?MODULE.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | State#?MODULE.transactions],
			{reply, Message,
			 State#?MODULE{timestamp=now(), message_id=MessageId, transactions=Pool}, State#?MODULE.timeout}
	end;
handle_event(Event=#mqtt_publish{}, State) ->
	?DEBUG([State#?MODULE.client_id, "=>", Event]),
	case Event#mqtt_publish.qos of
		at_most_once ->
			timer:cancel(State#?MODULE.timer),
			{reply, Event, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
		_ ->
			MessageId = State#?MODULE.message_id rem 16#ffff + 1,
			Message = Event#mqtt_publish{message_id=MessageId},
			Dup = Message#mqtt_publish{dup=true},
			{ok, Timer} = timer:send_after(State#?MODULE.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | State#?MODULE.transactions],
			{reply, Message,
			 State#?MODULE{timestamp=now(), message_id=MessageId, transactions=Pool}, State#?MODULE.timeout}
	end;
handle_event(Event=#mqtt_disconnect{}, State) ->
	?DEBUG([State#?MODULE.client_id, "=> DISCONNECT"]),
	{reply, Event, State#?MODULE{state=disconnecting, timestamp=now(), timeout=0}, 0};
handle_event({retry, MessageId}, State=#?MODULE{client_id=ClientId}) ->
	case lists:keytake(MessageId, 1, State#?MODULE.transactions) of
		{value, {MessageId, Message, Retry, _}, Rest} ->
			case Retry < State#?MODULE.max_retries of
				true ->
					?DEBUG([ClientId, "=>", Message, "retry", Retry]),
					{ok, Timer} = timer:send_after(State#?MODULE.retry_after, {retry, MessageId}),
					Pool = [{MessageId, Message, Retry+1, Timer}| Rest],
					{reply, Message, State#?MODULE{timestamp=now(), transactions=Pool}, State#?MODULE.timeout};
				_ ->
					?WARNING([ClientId, "=>", Message, "dropping after retry", Retry]),
					{noreply, State#?MODULE{transactions=Rest}, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)}
			end;
		_ ->
			?ERROR([ClientId, MessageId, "not found in transactions"]),
			{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)}
	end;
handle_event(Event, State) ->
	?WARNING([State#?MODULE.client_id, Event, "dropping unknown event"]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)}.

%% @doc Finalize the client process.
-spec terminate(state()) -> ok.
terminate(State) ->
	?DEBUG([terminate, State]),
	State.

%%
%% Local Functions
%%
timeout(infinity, _) ->
	infinity;
timeout(Milliseconds, Timestamp) ->
	Elapsed = timer:now_diff(now(), Timestamp) div 1000,
	case Milliseconds > Elapsed of
		true -> Milliseconds - Elapsed;
		_ -> 0
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.