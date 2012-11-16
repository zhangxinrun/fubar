%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : Routing functions for fubar.
%%%
%%% Created : Nov 16, 2012
%%% -------------------------------------------------------------------
-module(fubar_route).
-author("Sungjin Park <jinni.park@sk.com>").

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("log.hrl").

%% @doc Routing table schema
-record(?MODULE, {name = '_' :: term(),
				  addr = '_' :: pid()}).

%%
%% Exports
%%
-export([boot/0, cluster/1, resolve/1, up/1, down/1]).

boot() ->
	case mnesia:create_table(?MODULE, [{attributes, record_info(fields, ?MODULE)},
									   {disc_copies, [node()]}, {type, set}]) of
		{atomic, ok} ->
			?INFO({"table created", ?MODULE}),
			ok;
		{aborted, {already_exists, ?MODULE}} ->
			ok
	end,
	mnesia:wait_for_tables([?MODULE], 10000),
	?INFO({"table loaded", ?MODULE}).

%% @doc Slave mode bootstrap logic.
cluster(_MasterNode) ->
	{atomic, ok} = mnesia:add_table_copy(?MODULE, node(), disc_copies),
	?INFO({"table replicated", ?MODULE}).

%% @doc Resovle given name into address.
-spec resolve(term()) -> {ok, pid()} | {error, reason()}.
resolve(Name) ->
	% @todo implement remoting
	case catch mnesia:dirty_read(?MODULE, Name) of
		[#?MODULE{name=Name, addr=Addr}] ->
			{ok, Addr};
		[] ->
			{error, not_found};
		Error ->
			{error, Error}
	end.

%% @doc Update route with fresh name and address.
-spec up(term()) -> ok | {error, reason()}.
up(Name) ->
	Pid = self(),
	Route = #?MODULE{name=Name, addr=Pid},
	case catch mnesia:dirty_read(?MODULE, Name) of
		[#?MODULE{name=Name, addr=Addr}] when Addr =:= Pid ->
			% Ignore duplicate up call.
			ok;
		[#?MODULE{name=Name, addr=Addr}] ->
			exit(Addr, kill),
			easy_write(Route);
		[] ->
			easy_write(Route);
		Error ->
			{error, Error}
	end.

%% @doc Update route with stale name and address.
-spec down(term()) -> ok | {error, reason()}.
down(Name) ->
	mnesia:dirty_delete(?MODULE, Name).

%%
%% Local
%%		
easy_write(Record) ->
	case catch mnesia:dirty_write(Record) of
		{atomic, ok} ->
			ok;
		Error ->
			{error, Error}
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.