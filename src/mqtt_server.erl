%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT server.
%%%    This is designed to run under mqtt_protocol as a dispather.
%%% CONNECT, PINGREQ and DISCONNECT messages are processed here but
%%% others not.  All the other messages are just delivered to
%%% the session which is a separate process that typically survives
%%% longer.  Note that this performs just as a delivery channel and
%%% most of the logics are implemented in mqtt_session.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(mqtt_server).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

%%
%% Types and records
%%
-record(?MODULE, {client_id :: binary(),
				  auth :: module(),
				  clean_session = false :: boolean(),
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
	fubar_log:log(debug, ?MODULE, [undefined, init, Settings]),
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
handle_message(Message=#mqtt_connect{client_id=ClientId, username=undefined},
			   State=#?MODULE{session=undefined, timeout=Timeout, timestamp=Timestamp}) ->
	case State#?MODULE.auth of
		undefined ->
			fubar_log:log(info, ?MODULE, [ClientId, "=> CONNECT accepted", undefined]),
			bind_session(Message, State);
		_ ->
			fubar_log:log(info, ?MODULE, [ClientId, "=> CONNECT without credential"]),
			% Give another chance to connect with right credential again.
			{reply, mqtt:connack([{code, unauthorized}]), State, timeout(Timeout, Timestamp)}
	end;
handle_message(Message=#mqtt_connect{client_id=ClientId, username=Username}, State=#?MODULE{session=undefined}) ->
	case State#?MODULE.auth of
		undefined ->
			fubar_log:log(info, ?MODULE, [ClientId, "=> CONNECT accepted", Username]),
			bind_session(Message, State);
		Auth ->
			% Connection with credential.
			case Auth:verify(Username, Message#mqtt_connect.password) of
				ok ->
					fubar_log:log(info, ?MODULE, [ClientId, "=> CONNECT accepted", Username]),
					% The client is authorized.
					% Now bind with the session or create a new one.
					bind_session(Message, State);
				{error, not_found} ->
					fubar_log:log(info, ?MODULE, [ClientId, "=> CONNECT not found", Username]),
					{reply, mqtt:connack([{code, id_rejected}]), State#?MODULE{timestamp=now()}, 0};
				{error, forbidden} ->
					fubar_log:log(info, ?MODULE, [ClientId, "=> CONNECT forbidden", Username]),
					{reply, mqtt:connack([{code, forbidden}]), State#?MODULE{timestamp=now()}, 0};
				Error ->
					fubar_log:log(info, ?MODULE, [ClientId, "=> CONNECT error", Username, Error]),
					{reply, mqtt:connack([{code, unavailable}]), State#?MODULE{timestamp=now()}, 0}
			end
	end;
handle_message(Message, State=#?MODULE{session=undefined}) ->
	% All the other messages are not allowed without session.
	fubar_log:log(warning, ?MODULE, [State#?MODULE.client_id, "=> no session", Message]),
	{stop, normal, State#?MODULE{timestamp=now()}};
handle_message(#mqtt_pingreq{}, State) ->
	% Reflect ping and refresh timeout.
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "=> PINGREQ"]),
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "<= PINGRESP"]),
	{reply, #mqtt_pingresp{}, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_publish{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(info, ?MODULE, [State#?MODULE.client_id, "=> PUBLISH", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_puback{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "=> PUBACK"]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubrec{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "=> PUBREC"]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubrel{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "=> PUBREL"]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubcomp{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "=> PUBCOMP"]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_subscribe{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(info, ?MODULE, [State#?MODULE.client_id, "=>SUBSCRIBE", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_unsubscribe{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(info, ?MODULE, [State#?MODULE.client_id, "=> UNSUBSCRIBE", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(#mqtt_disconnect{}, State=#?MODULE{session=Session}) ->
	fubar_log:log(info, ?MODULE, [State#?MODULE.client_id, "=> DISCONNECT"]),
	case State#?MODULE.clean_session of
		true ->
			mqtt_session:clean(Session);
		_ ->
			ok
	end,
	{stop, normal, State#?MODULE{timestamp=now()}};

%% Fallback
handle_message(Message, State) ->
	fubar_log:log(warning, ?MODULE, [State#?MODULE.client_id, "=> UNKNOWN", Message]),
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle internal events from, supposedly, the session.
-spec handle_event(event(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_event(timeout, State) ->
	% General timeout
	fubar_log:log(info, ?MODULE, [State#?MODULE.client_id, "timed out"]),
	{stop, normal, State};
handle_event(Event, State=#?MODULE{session=undefined}) ->
	fubar_log:log(warning, ?MODULE, [State#?MODULE.client_id, "no session", Event]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_event(Event=#mqtt_publish{}, State) ->
	fubar_log:log(info, ?MODULE, [State#?MODULE.client_id, "<= PUBLISH", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_puback{}, State) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "<= PUBACK"]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubrec{}, State) ->
	fubar_log:log(debug, [State#?MODULE.client_id, "<= PUBREC"]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubrel{}, State) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "<= PUBREL"]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubcomp{}, State) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "<= PUBCOMP"]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_suback{}, State) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "<= SUBACK"]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_unsuback{}, State) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "<= UNSUBACK"]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};

%% Fallback
handle_event(Event, State) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, "unknown event", Event]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)}.

%% @doc Finalize the server process.
-spec terminate(state()) -> ok.
terminate(State) ->
	fubar_log:log(debug, ?MODULE, [State#?MODULE.client_id, terminate]),
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

bind_session(Message=#mqtt_connect{client_id=ClientId}, State) ->
	% Once bound, the session will detect process termination.
	% Timeout value should be set as requested.
	Will = case Message#mqtt_connect.will_topic of
			   undefined -> undefined;
			   Topic -> {Topic, Message#mqtt_connect.will_message,
						 Message#mqtt_connect.will_qos, Message#mqtt_connect.will_retain}
		   end,
	case mqtt_session:bind(ClientId, Will) of
		{ok, Session} ->
			Timeout = case Message#mqtt_connect.keep_alive of
						  infinity -> infinity;
						  KeepAlive -> KeepAlive*1500
					  end,
			{reply, mqtt:connack([{code, accepted}]),
			 State#?MODULE{client_id=ClientId, clean_session=Message#mqtt_connect.clean_session,
						   session=Session, timeout=Timeout, timestamp=now()}, Timeout};
		Error ->
			fubar_log:log(error, ?MODULE, [ClientId, "session bind failure", Error]),
			% Timeout immediately to close just after reply.
			{reply, mqtt:connack([{code, unavailable}]),
			 State#?MODULE{client_id=ClientId, clean_session=Message#mqtt_connect.clean_session,
						   timestamp=now()}, 0}
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.