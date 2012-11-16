%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : MQTT server for ppcm.
%%%               Used as a dispatcher in ranch:start_listener/6.
%%%               The dispatcher callback is invoked by the protocol
%%%               handler, which is mqtt_protocol.
%%%               Refer mqtt_protocol.erl
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

-include("mqtt.hrl").
-include("log.hrl").
-include("props_to_record.hrl").
-include("fubar.hrl").

%%
%% Types and records
%%
-record(?MODULE, {session :: pid(),
				timeout = 10000 :: timeout(),
				client_id :: binary(),
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
	{noreply, State, State#?MODULE.timeout}.

%% @doc Handle MQTT messages.
%% This is called when an MQTT message arrives.
-spec handle_message(mqtt_message(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_message(#mqtt_connect{username=undefined}, State=#?MODULE{session=undefined}) ->
	?WARNING("CONNECT without credential"),
	% Give another chance to connect with right credential again.
	{reply, mqtt:connack([{code, unauthorized}]), State, State#?MODULE.timeout};
handle_message(Message = #mqtt_connect{username=Username, client_id=ClientId},
			   State=#?MODULE{session=undefined}) ->
	% Connection with credential.
	case mqtt_account:verify(Username, Message#mqtt_connect.password) of
		ok ->
			?DEBUG(["CONNECT accepted", Username, ClientId]),
			% The client is authorized.
			% Now bind with the session or create a new one.
			% Once bound, the session will detect process termination.
			% Timeout value should be set as requested.
			Will = case Message#mqtt_connect.will_topic of
					   undefined -> [];
						   Topic -> [{will, {Topic, Message#mqtt_connect.will_message,
											 Message#mqtt_connect.will_qos, Message#mqtt_connect.will_retain}}]
				   end,
			case fubar_session:bind(ClientId, [{clean_session, Message#mqtt_connect.clean_session} | Will]) of
				{ok, Session} ->
					Timeout = case Message#mqtt_connect.keep_alive of
								  infinity -> infinity;
								  KeepAlive -> KeepAlive*2000
							  end,
					{reply, mqtt:connack([{code, accepted}]),
					 State#?MODULE{client_id=ClientId, timeout=Timeout, session=Session}, Timeout};
				Error ->
					?ERROR(["session bind failure", Error, ClientId]),
					% Timeout immediately to close just after reply.
					{reply, mqtt:connack([{code, unavailable}]), State, 0}
			end;
		{error, not_found} ->
			?WARNING(["CONNECT with unknown username", Username]),
			{reply, mqtt:connack([{code, id_rejected}]), State, 0};
		{error, forbidden} ->
			?WARNING(["CONNECT with bad credential", Username]),
			{reply, mqtt:connack([{code, forbidden}]), State, 0};
		Error ->
			?ERROR(["account error", Error, Username]),
			{reply, mqtt:connack([{code, unavailable}]), State, 0}
	end;
handle_message(#mqtt_disconnect{}, State) ->
	?DEBUG(["DISCONNECT", State#?MODULE.client_id]),
	{stop, normal, State};
handle_message(Message, State=#?MODULE{session=undefined}) ->
	% All the other messages are not allowed without session.
	?ERROR(["unexpected message before session binding", Message, State]),
	{stop, normal, State};
handle_message(#mqtt_pingreq{}, State) ->
	% Reflect ping and refresh timeout.
	{reply, #mqtt_pingresp{}, State, State#?MODULE.timeout};
handle_message(Message=#mqtt_publish{dup=true}, State) ->
	handle_dup_message(Message, State);
handle_message(#mqtt_publish{}, State) ->
	?DEBUG(["PUBLISH", State#?MODULE.client_id]),
	{noreply, State, State#?MODULE.timeout};
handle_message(Message=#mqtt_subscribe{dup=true}, State) ->
	handle_dup_message(Message, State);
handle_message(#mqtt_subscribe{}, State) ->
	?DEBUG(["SUBSCRIBE", State#?MODULE.client_id]),
	{noreply, State, State#?MODULE.timeout};
handle_message(Message=#mqtt_unsubscribe{dup=true}, State) ->
	handle_dup_message(Message, State);
handle_message(#mqtt_unsubscribe{}, State) ->
	?DEBUG(["UNSUBSCRIBE", State#?MODULE.client_id]),
	{noreply, State, State#?MODULE.timeout};
handle_message(Message, State) ->
	?ERROR(["bad message", Message, State]),
	{stop, normal, State}.

%% @doc Handle internal events from, supposedly, the session.
-spec handle_event(event(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_event(Fubar=#fubar{}, State) ->
	% Need to forward as a PUBLISH to the peer.
	fubar:profile(?MODULE, Fubar),
	{noreply, State, State#?MODULE.timeout};
handle_event(timeout, State) ->
	% General timeout
	?WARNING(["NO PINGREQ timeout", State#?MODULE.client_id]),
	{stop, normal, State};
handle_event(Event, State) ->
	?WARNING(["ignoring unknown event", Event, State]),
	{noreply, State, State#?MODULE.timeout}.

%% @doc Finalize the server process.
-spec terminate(state()) -> ok.
terminate(State) ->
	?DEBUG([terminate, State]),
	fubar_session:unbind(State#?MODULE.session).

%%
%% Local Functions
%%
handle_dup_message(Message, State=#?MODULE{history=History}) ->
	?DEBUG(["DUP", Message]),
	% Duplicate messages can be handled autonomously.
	% Search for corresponding response in history.
	Pred = fun(Request) -> mqtt:is_same(Message, Request) end,
	case keyfind_first_if(Pred, 1, History) of
		{ok, {_, Reply}} ->
			% There is one.  Reply it.
			{reply, Reply, State, State#?MODULE.timeout};
		_ ->
			% Not found.  Just drop it.
			{noreply, State, State#?MODULE.timeout}
	end.

keyfind_first_if(_, _, []) ->
	{error, not_found};
keyfind_first_if(Pred, N, [H | T]) ->
	case Pred(lists:nth(N, tuple_to_list(H))) of
		true ->
			{ok, H};
		_ ->
			keyfind_first_if(Pred, N, T)
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.