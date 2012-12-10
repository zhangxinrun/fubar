%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT access control list module.
%%%
%%% Created : Dec 10, 2012
%%% -------------------------------------------------------------------
-module(mqtt_acl).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("sasl_log.hrl").

%%
%% Records
%%

%% @doc MQTT acl database schema.
-record(?MODULE, {addr = '_' :: binary(),
				  allow = '_' :: binary()}).

%%
%% Exports
%%
-export([boot/0, cluster/1, verify/1, update/2, delete/1]).

%% @doc Master mode bootstrap logic.
boot() ->
	case mnesia:create_table(?MODULE, [{attributes, record_info(fields, ?MODULE)},
									   {disc_copies, [node()]}, {type, set}]) of
		{atomic, ok} ->
			?INFO({"table created", ?MODULE}),
			ok;
		{aborted, {already_exists, ?MODULE}} ->
			ok
	end,
	ok = mnesia:wait_for_tables([?MODULE], 10000),
	?INFO({"table loaded", ?MODULE}).

%% @doc Slave mode bootstrap logic.
cluster(_MasterNode) ->
	{atomic, ok} = mnesia:add_table_copy(?MODULE, node(), disc_copies),
	?INFO({"table replicated", ?MODULE}).

%% @doc Verify credential.
-spec verify(term()) -> ok | {error, reason()}.
verify(Addr) ->
	case catch mnesia:dirty_read(?MODULE, Addr) of
		[] ->
			{error, not_found};
		[#?MODULE{allow=true}] ->
			ok;
		[#?MODULE{}] ->
			{error, forbidden};
		Error ->
			Error
	end.

%% @doc Update account.
-spec update(binary(), binary()) -> ok | {aborted, reason()}.
update(Addr, Allow) ->
	catch mnesia:dirty_write(#?MODULE{addr=Addr, allow=Allow}).

%% @doc Delete account.
-spec delete(binary()) -> ok | {aborted, reason()}.
delete(Addr) ->
	catch mnesia:dirty_delete(?MODULE, Addr).

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.