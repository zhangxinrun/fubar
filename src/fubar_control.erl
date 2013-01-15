%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar command line control functions. 
%%%
%%% Created : Jan 14, 2013
%%% -------------------------------------------------------------------
-module(fubar_control).

%% ====================================================================
%% API functions
%% ====================================================================
-export([call/1]).

call([Node, state]) ->
	case catch rpc:call(Node, fubar, state, []) of
		{ok, State} ->
			io:format("~n== ~p running ==~n", [Node]),
			pretty_print(State);
		Error ->
			io:format("~n== ~p error ==~n~p~n~n", [Node, Error])
	end,
	halt();
call([Node, stop]) ->
	io:format("~n== ~p stopping ==~n", [Node]),
	io:format("~p~n~n", [catch rpc:call(Node, fubar, stop, [])]),
	halt();
call(_) ->
	io:format(standard_error, "Available commands: state, stop", []),
	halt().

%% ====================================================================
%% Internal functions
%% ====================================================================
pretty_print([]) ->
	io:format("~n");
pretty_print([{Key, Value} | More]) ->
	io:format("~12s : ~p~n", [Key, Value]),
	pretty_print(More).