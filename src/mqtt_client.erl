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
%% Records and types
%%
-record(?MODULE, {username :: binary(),
				password :: binary(),
				client_id :: binary(),
				keep_alive = 600000 :: timeout(),
				will_topic :: binary(),
				will_message :: binary(),
				will_qos = at_most_once :: mqtt_qos(),
				will_retain = false :: boolean(),
				clean_session = false :: boolean(),
				state = connecting :: connecting | connected | refreshing,
				timeout = 10000 :: timeout(),
				timestamp :: timestamp(),
				last_id = 0 :: integer(),
				buffer = [] :: [{mqtt_message(), pid()}],
				jobs = 0 :: integer(),
				max_jobs = 10 :: integer(),
				history = [] :: [{mqtt_message(), mqtt_message()}],
				histories = 0 :: integer(),
				max_histories = 10 :: integer()}).

-type state() :: #?MODULE{}.
-type event() :: any().

%%
%% Exports
%%
-export([start/1, stop/1, subscribe/2]).
-export([init/1, handle_message/2, handle_event/2, terminate/1]).

%% @doc Start an MQTT client with parameters.
%%      Parameters(defaults):
%%        host(localhost), port(1443), username(undefined), password(undefined),
%%        client_id(<<>>), keep_alive(infinity), will_topic(undefined),
%%        will_message(undefined), will_qos(at_most_once), will_retain(false),
%%        clean_session(false)
-spec start(proplist(atom(), term())) -> {ok, pid()} | {error, reason()}.
start(Props) ->
	mqtt_protocol:start([{dispatch, ?MODULE} | Props]).

%% @doc Stop an MQTT client process.
-spec stop(pid()) -> ok | {error, reason()}.
stop(Client) ->
	Client ! #mqtt_disconnect{},
	mqtt_protocol:stop(Pid).

%% @doc Let an MQTT client subscribe to a topic or topics.
-spec subscribe(pid(), binary() | {binary(), mqtt_qos()} | [binary() | {binary(), mqtt_qos()}]) -> ok.
subscribe(Client, Topics) ->
	Client ! mqtt:subscribe([{topics=Topics}]).

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
	% Send connect with given parameters and wait for connack.
	Message = mqtt:connect(Props),
	{reply, Message, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle MQTT messages.
%% This is called when a message arrives.
-spec handle_message(mqtt_message(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_message(#mqtt_connack{code=Code}, State=#?MODULE{state=connecting}) ->
	% Received connack while waiting for one.
	case Code of
		accepted ->
			?INFO(["CONNACK", accepted, State#?MODULE.client_id]),
			{noreply, State#?MODULE{state=connected, timestamp=now()}, timeout(State#?MODULE.keep_alive)};
		unavailable ->
			?ERROR(["CONNACK", unavailable, State#?MODULE.client_id]),
			{stop, unavailable, State};
		Error ->
			?ERROR(["CONNACK", Error, State#?MODULE.client_id]),
			% Normal exit so that the supervisor not restart this.
			{stop, normal, State}
	end;
handle_message(Message, State=#?MODULE{state=connecting}) ->
	?ERROR(["unexpected message while connecting", Message, State#?MODULE.client_id]),
	% No other message than CONNACK is expected.
	{stop, normal, State};
handle_message(#mqtt_pingresp{}, State) ->
	{noreply, State#?MODULE{state=connected, timestamp=now()}, timeout(State#?MODULE.keep_alive)};
handle_message(#mqtt_suback{message_id=MessageId}, State) ->
	?INFO(["SUBACK", MessageId, State#?MODULE.client_id]),
	{noreply, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.keep_alive)};
handle_message(#mqtt_publish{topic=Topic, payload=Payload}, State) ->
	?INFO(["PUBLISH", Topic, Payload, State#?MODULE.client_id]),
	{noreply, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.keep_alive)};
handle_message(#mqtt_puback{message_id=MessageId}, State) ->
	?INFO(["PUBACK", MessageId, State#?MODULE.client_id]),
	{noreply, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.keep_alive)};
handle_message(#mqtt_pubrec{message_id=MessageId}, State) ->
	?INFO(["PUBREC", MessageId, State#?MODULE.client_id]),
	{noreply, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.keep_alive)};
handle_message(#mqtt_pubcomp{message_id=MessageId}, State) ->
	?INFO(["PUBCOMP", MessageId, State#?MODULE.client_id]),
	{noreply, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.keep_alive)};
handle_message(Message, State) ->
	?ERROR(["bad message", Message, State]),
	{stop, normal, State}.

%% @doc Handle internal events.
-spec handle_event(event(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_event(timeout, State=#?MODULE{state=connecting}) ->
	?ERROR([State#?MODULE.client_id, "CONNECT timed out"]),
	{stop, timeout, State};
handle_event(_Event, State=#?MODULE{state=connecting}) ->
	?WARNING([State#?MODULE.client_id, "not connected yet"]),
	% Ignore events before being connected.
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_event(Event=#mqtt_disconnect{}, State) ->
	{reply, Event, State#?MODULE{timestamp=now()}, timeout(State#?MODULE.keep_alive)};
handle_event(timeout, State=#?MODULE{state=refreshing}) ->
	?ERROR([State#?MODULE.client_id, "no PINGRESP"]),
	% Timed out waiting for pong.
	{stop, timeout, State};
handle_event(_Event, State=#?MODULE{state=refreshing}) ->
	?WARNING([State#?MODULE.client_id, "refreshing the connection"]),
	% Ignore events while refreshing.
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_event(timeout, State) ->
	?DEBUG([State#?MODULE.client_id, "PINGREQ"]),
	{reply, mqtt:pingreq([]), State#?MODULE{state=refreshing, timestamp=now()}, State#?MODULE.timeout};
handle_event(#mqtt_publish{}, State) ->
	?WARNING([State#?MODULE.client_id, "PUBLISH not implemented yet"]),
	{noreply, State, timeout(State#?MODULE.keep_alive, State#?MODULE.timestamp)};
handle_event(#mqtt_subscribe{}, State) ->
	?WARNING([State#?MODULE.client_id, "SUBSCRIBE not implemented yet"]),
	{noreply, State, timeout(State#?MODULE.keep_alive, State#?MODULE.timestamp)};
handle_event(Event, State) ->
	?WARNING([State#?MODULE.client_id, "ignoring unknown event", Event]),
	{noreply, State, timeout(State#?MODULE.keep_alive, State#?MODULE.timestamp)}.

%% @doc Finalize the client process.
-spec terminate(state()) -> ok.
terminate(State) ->
	?DEBUG([terminate, State]),
	State.

%%
%% Local Functions
%%
timeout(infinity) ->
	infinity;
timeout(Seconds) ->
	Seconds*1000.

timeout(infinity, _) ->
	infinity;
timeout(Seconds, Timestamp) ->
	Elapsed = timer:now_diff(now(), Timestamp) div 1000,
	Timeout = Seconds*1000 - Elapsed,
	case Timeout of
		Expired when Expired < 0 ->
			0;
		Milliseconds ->
			Milliseconds
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.