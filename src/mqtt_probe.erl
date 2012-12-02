%% Author: jinni
%% Created: Dec 2, 2012
%% Description: TODO: Add description to mqtt_probe
-module(mqtt_probe).

%%
%% Include files
%%

%%
%% Exported Functions
%%
-export([start/3, stop/1, loop/3]).

%%
%% API Functions
%%
start(Client, Topics, Interval) ->
	proc_lib:spawn(?MODULE, loop, [Client, Topics, Interval]).

stop(Probe) ->
	Probe ! stop.

loop(Client, Topics, Interval) ->
	receive
		_ ->
			ok
	after Interval ->
			Topic = case is_list(Topics) of
						true ->
							N = random:uniform(length(Topics)),
							lists:nth(N, Topics);
						_ ->
							Topics
					end,
			Date = httpd_util:rfc1123_date(),
			Client ! mqtt:publish([{topic, Topic}, {payload, list_to_binary(Date)}]),
			?MODULE:loop(Client, Topics, Interval)
	end.

%%
%% Local Functions
%%

