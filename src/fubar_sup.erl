%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@sk.com>
%%%
%%% Description : fubar supervisor callback.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(fubar_sup).
-author("Sungjin Park <jinni.park@sk.com>").
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
-export([start_link/0]).
-export([init/1]).

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%
%% Supervisor callbacks
%%
init(_) ->
    {ok, {{one_for_one, ?MAX_R, ?MAX_T}, []}}.