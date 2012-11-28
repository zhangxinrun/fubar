%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar supervisor callback.
%%%
%%% Created : Nov 28, 2012
%%% -------------------------------------------------------------------
-module(mqtt_client_sup).
-author("Sungjin Park <jinni.park@gmail.com>").
-behaviour(supervisor).

%%
%% Includes
%%
-include("fubar.hrl").

%%
%% Macros
%%
-define(MAX_R, 3).
-define(MAX_T, 5).

%%
%% Exports
%%
-export([start_link/0, start_child/1, stop_child/1]).
-export([init/1]).

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start an mqtt client under supervisory.
-spec start_child(proplist(atom(), term())) -> {ok, pid()} | {error, reason()}.
start_child(Props) ->
	Id = proplists:get_value(client_id, Props),
	Spec = {Id, {mqtt_client, start_link, [Props]}, transient, 10, worker, dynamic},
	supervisor:start_child(?MODULE, Spec).

%% @doc Stop an mqtt client under supervisory.
-spec stop_child(binary()) -> ok | {error, reason()}.
stop_child(Id) ->
	supervisor:stop_child(?MODULE, Id).

%%
%% Supervisor callbacks
%%
init(_) ->
	{ok, {{one_for_one, ?MAX_R, ?MAX_T}, []}}.