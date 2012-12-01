#!/usr/bin/env escript
%% -*- erlang -*-
%%! -sname dump-log
main([Prefix]) ->
	% Find log dir and settings.
	application:load(fubar),
	Props = fubar:settings(fubar_log),
	Dir = filename:join(proplists:get_value(dir, Props), Prefix),
	% Dump sasl log.
	ok = application:start(sasl),
	{ok, _Pid} = rb:start([{report_dir, Dir}]),
	{{Y, M, D}, {H, Min, S}} = calendar:universal_time(),
	Base = io_lib:format("~s-~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0B-", [Prefix, Y, M, D, H, Min, S]),
	rb:start_log(Base++"sasl.log"),
	rb:show(),
	rb:stop_log(),
	rb:stop();
main(_) ->
	usage().

usage() ->
	io:format("Usage: ~s <log_dir> <prefix>~n", [escript:script_name()]),
	halt(1).
