%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : MQTT server.
%%%    This is designed to run under mqtt_protocol as a dispather.
%%% CONNECT and PINGREQ messages can be processed without a session but
%%% others not.  Therefore all the other messages are just delivered to
%%% the session which is a separate process that typically survives
%%% longer.  Note that this performs just as a delivery channel and
%%% most of the logics are implemented in mqtt_session.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(mqtt_server).
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
%% Types and records
%%
-record(?MODULE, {client_id :: binary(),
				session :: pid(),
				timeout = 10000 :: timeout(),
				timestamp :: timestamp()}).

-type state() :: #?MODULE{}.
-type event() :: any().

%%
%% Exports
%%
-export([init/1, handle_message/2, handle_event/2, terminate/1]).

%%
%% Calback Functions
%%

%% @doc Initialize the server process.
%% This is called when the connection is established.
-spec init(proplist(atom(), term())) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason()}.
init(Props) ->
	Settings = fubar:settings(?MODULE)++Props,
	?DEBUG([init, Settings]),
	State = ?PROPS_TO_RECORD(Settings, ?MODULE),
	% Don't respond anything against tcp connection and apply small initial timeout.
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle MQTT messages.
%% This is called when an MQTT message arrives.
-spec handle_message(mqtt_message(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_message(#mqtt_connect{username=undefined}, State=#?MODULE{session=undefined}) ->
	?WARNING([State#?MODULE.client_id, "CONNECT without credential"]),
	% Give another chance to connect with right credential again.
	{reply, mqtt:connack([{code, unauthorized}]), State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_message(Message=#mqtt_connect{client_id=ClientId, username=Username}, State=#?MODULE{session=undefined}) ->
	% Connection with credential.
	case mqtt_account:verify(Username, Message#mqtt_connect.password) of
		ok ->
			?DEBUG([ClientId, "=> CONNECT accepted", Username]),
			% The client is authorized.
			% Now bind with the session or create a new one.
			% Once bound, the session will detect process termination.
			% Timeout value should be set as requested.
			Will = case Message#mqtt_connect.will_topic of
					   undefined -> [];
						   Topic -> [{will, {Topic, Message#mqtt_connect.will_message,
											 Message#mqtt_connect.will_qos, Message#mqtt_connect.will_retain}}]
				   end,
			case mqtt_session:bind(ClientId, [{clean_session, Message#mqtt_connect.clean_session} | Will]) of
				{ok, Session} ->
					Timeout = case Message#mqtt_connect.keep_alive of
								  infinity -> infinity;
								  KeepAlive -> KeepAlive*2000
							  end,
					{reply, mqtt:connack([{code, accepted}]),
					 State#?MODULE{client_id=ClientId, session=Session, timeout=Timeout, timestamp=now()}, Timeout};
				Error ->
					?ERROR([ClientId, Error, "session bind failure"]),
					% Timeout immediately to close just after reply.
					{reply, mqtt:connack([{code, unavailable}]), State, 0}
			end;
		{error, not_found} ->
			?WARNING([ClientId, "=> CONNECT not found", Username]),
			{reply, mqtt:connack([{code, id_rejected}]), State#?MODULE{timestamp=now()}, 0};
		{error, forbidden} ->
			?WARNING([ClientId, "=> CONNECT forbidden", Username]),
			{reply, mqtt:connack([{code, forbidden}]), State#?MODULE{timestamp=now()}, 0};
		Error ->
			?ERROR([ClientId, "=> CONNECT error", Error, Username]),
			{reply, mqtt:connack([{code, unavailable}]), State#?MODULE{timestamp=now()}, 0}
	end;
handle_message(Message, State=#?MODULE{session=undefined}) ->
	% All the other messages are not allowed without session.
	?ERROR([State#?MODULE.client_id, "=>", Message, "dropping sessionless message"]),
	{stop, normal, State#?MODULE{timestamp=now()}};
handle_message(#mqtt_pingreq{}, State) ->
	% Reflect ping and refresh timeout.
	?DEBUG([State#?MODULE.client_id, "=> PINGREQ"]),
	?DEBUG([State#?MODULE.client_id, "<= PINGRESP"]),
	{reply, #mqtt_pingresp{}, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_publish{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_puback{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubrec{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubrel{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubcomp{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_subscribe{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_unsubscribe{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_disconnect{}, State=#?MODULE{session=Session}) ->
	?DEBUG([State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{stop, normal, State#?MODULE{timestamp=now()}};

%% Fallback
handle_message(Message, State) ->
	?WARNING([State#?MODULE.client_id, "=>", Message, "dropping unknown message"]),
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle internal events from, supposedly, the session.
-spec handle_event(event(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_event(timeout, State) ->
	% General timeout
	?WARNING([State#?MODULE.client_id, "timed out"]),
	{stop, normal, State};
handle_event(Event, State=#?MODULE{session=undefined}) ->
	?WARNING([State#?MODULE.client_id, Event, "dropping sessionless event"]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_event(Event=#mqtt_publish{}, State) ->
	?DEBUG([State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_puback{}, State) ->
	?DEBUG([State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubrec{}, State) ->
	?DEBUG([State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubrel{}, State) ->
	?DEBUG([State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubcomp{}, State) ->
	?DEBUG([State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_suback{}, State) ->
	?DEBUG([State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_unsuback{}, State) ->
	?DEBUG([State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};

%% Fallback
handle_event(Event, State) ->
	?WARNING([State#?MODULE.client_id, Event, "dropping unknown event"]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)}.

%% @doc Finalize the server process.
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