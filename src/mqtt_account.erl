%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT account module.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(mqtt_account).
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

%% @doc MQTT account database schema.
-record(?MODULE, {username = '_' :: binary(),
				  password = '_' :: binary()}).

%%
%% Exports
%%
-export([boot/0, cluster/1, verify/2, update/2, delete/1]).

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
-spec verify(binary(), binary()) -> ok | {error, reason()}.
verify(Username, Password) ->
	case catch mnesia:dirty_read(?MODULE, Username) of
		[] ->
			{error, not_found};
		[#?MODULE{password=Password}] ->
			ok;
		[#?MODULE{}] ->
			{error, forbidden};
		Error ->
			Error
	end.

%% @doc Update account.
-spec update(binary(), binary()) -> ok | {aborted, reason()}.
update(Username, Password) ->
	catch mnesia:dirty_write(#?MODULE{username=Username, password=Password}).

%% @doc Delete account.
-spec delete(binary()) -> ok | {aborted, reason()}.
delete(Username) ->
	catch mnesia:dirty_delete(?MODULE, Username).

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.