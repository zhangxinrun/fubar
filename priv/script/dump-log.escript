#!/usr/bin/env escript
%% -*- erlang -*-
%%! -sname dump-log
main([Filename, ReportDir]) ->
	ok = application:start(sasl),
	{ok, _Pid} = rb:start([{report_dir, ReportDir}]),
	rb:start_log(Filename),
	rb:show(),
	rb:stop_log();
main(_) ->
	usage().

usage() ->
	io:format("Usage: ~s <filename> <report_dir>~n", [escript:script_name()]),
	halt(1).
