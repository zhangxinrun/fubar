%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : fubar session provides persistency for client.
%%%
%%% Created : Nov 15, 2012
%%% -------------------------------------------------------------------
-module(fubar_session).
-author("Sungjin Park <jinni.park@sk.com>").
-behavior(gen_server).

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("log.hrl").
-include("props_to_record.hrl").

%%
%% Records and types
%%
-record(?MODULE, {id :: term(),
				  clean_session = false :: boolean(),
				  will_topic :: binary(),
				  will_message :: binary(),
				  will_qos = at_most_once :: at_most_once | at_least_once | exactly_once,
				  will_retain = false :: boolean(),
				  origin :: pid(),
				  client :: pid(),
				  subscriptions = [] :: [term()],
				  buffer = [] :: [#fubar{}],
				  fubars = 0 :: integer(),
				  max_fubars = 100 :: integer()}).

%%
%% Exports
%%
-export([bind/2, unbind/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Bind a client with existing session or create a new one.
-spec bind(term(), proplist(atom(), term())) -> {ok, pid()} | {error, reason()}.
bind(Id, Options) ->
	case fubar_route:resolve(Id) of
		{ok, Session} ->
			{gen_server:call(Session, {bind, Options}), Session};
		{error, not_found} ->
			gen_server:start_link(?MODULE, [{id, Id}, {client, self()} | Options], []);
		Error ->
			Error
	end.

%% @doc Unbind a client with the session.
-spec unbind(pid()) -> ok.
unbind(Session) ->
	gen_server:call(Session, unbind).

init(Props) ->
	State = ?PROPS_TO_RECORD(Props, ?MODULE),
	?DEBUG([init, State]),
	process_flag(trap_exit, true),
	% @todo implement migration from remote session when remote is set
	fubar_route:up(State#?MODULE.id),
	{ok, State}.

handle_call({bind, Props}, {NewClient, _}, State) ->
	?DEBUG(["client up", NewClient]),
	case State#?MODULE.client of
		undefined ->
			ok;
		OldClient ->
			?WARNING(["client ousted", OldClient, NewClient]),
			unlink(OldClient),
			exit(OldClient, kill)
	end,
	link(NewClient),
	{reply, ok, ?PROPS_TO_RECORD([{client, NewClient} | Props], ?MODULE, State)()};
handle_call(unbind, {Client, _}, State=#?MODULE{client=Client}) ->
	?DEBUG(["client left", Client]),
	unlink(Client),
	{reply, ok, State#?MODULE{client=undefined}};
handle_call(Request, From, State) ->
	?WARNING(["ignoring unknown call", Request, From, State]),
	{reply, ok, State}.

handle_cast(Message, State) ->
	?WARNING(["ignoring unknown cast", Message, State]),
	{noreply, State}.

handle_info({'EXIT', Client, Reason}, State=#?MODULE{client=Client}) ->
	?DEBUG(["client down", Reason]),
	% @todo implement clean session
	{noreply, State#?MODULE{client=undefined}};
handle_info(Info, State) ->
	?WARNING(["ignoring unknown info", Info, State]),
	{noreply, State}.

terminate(Reason, State) ->
	?DEBUG([terminate, Reason, State]),
	% @todo implement will announcement
	fubar_route:down(State#?MODULE.id).

code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.