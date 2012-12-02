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
start(Client, Topic, Interval) ->
	proc_lib:spawn(?MODULE, loop, [Client, Topic, Interval]).

stop(Probe) ->
	Probe ! stop.

loop(Client, Topic, Interval) ->
	receive
		_ ->
			ok
	after Interval ->
			Date = httpd_util:rfc1123_date(),
			Client ! mqtt:publish([{topic, Topic}, {payload, list_to_binary(Date)}]),
			?MODULE:loop(Client, Topic, Interval)
	end.

%%
%% Local Functions
%%

