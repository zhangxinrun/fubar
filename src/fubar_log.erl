%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Fubar log manager.
%%%
%%% Created : Nov 30, 2012
%%% -------------------------------------------------------------------
-module(fubar_log).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("sasl_log.hrl").
-include("props_to_record.hrl").

%%
%% Macros, records and types
%%
-record(?MODULE, {dir = "priv/log" :: string(),
				  max_bytes = 10485760 :: integer(),
				  max_files = 10 :: integer(),
				  classes = [] :: [{atom(), term(), null | standard_io | pid()}],
				  interval = 500 :: timeout()}).

%%
%% Exports
%%
-export([start_link/0, log/3, trace/2, dump/0, dump/2,
		 open/1, close/1, show/0, show/1, hide/0, hide/1, interval/1, state/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Start a log manager.
%%      The log manager process manages disk_logs and polls them.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
	State = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?MODULE),
	[Name | _] = string:tokens(lists:flatten(io_lib:format("~s", [node()])), "@"),
	Path = filename:join(State#?MODULE.dir, Name),
	ok = filelib:ensure_dir(Path++"/"),
	gen_server:start({local, ?MODULE}, ?MODULE, State#?MODULE{dir=Path}, []).

%% @doc Leave a log.
%%      The log is dropped unless the class is open in advance.
%% @sample fubar_log:log(debug, my_module, Term).
-spec log(atom(), term(), term()) -> ok | {error, reason()}.
log(Class, Tag, Term) ->
	{{Y, M, D}, {H, Min, S}} = calendar:universal_time(),
	Timestamp = lists:flatten(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
											[Y, M, D, H, Min, S])),
	catch disk_log:log(Class, {{Class, Timestamp}, {Tag, self()}, Term}).

%% @doc Leave a special trace type log.
%% @sample fubar_log:trace(my_module, Fubar).
-spec trace(term(), #fubar{}) -> ok.
trace(_, #fubar{id=undefined}) ->
	ok;
trace(Tag, #fubar{id=Id, origin={Origin, T1}, from={From, T2}, via={Via, T3}, payload=Payload}) ->
	Now = now(),
	Calendar = calendar:now_to_universal_time(Now),
	Timestamp = httpd_util:rfc1123_date(Calendar),
	catch disk_log:log(trace, {{trace, Timestamp}, {Tag, self()},
							   {fubar, Id},
							   {since, {Origin, timer:now_diff(Now, T1)/1000},
									   {From, timer:now_diff(Now, T2)/1000},
									   {Via, timer:now_diff(Now, T3)/1000}},
							   {payload, Payload}}).

%% @doc Dump all log classes to text log files.
dump() ->
	case state() of
		#?MODULE{dir=Dir, classes=Classes} ->
			[Name | _] = string:tokens(lists:flatten(io_lib:format("~s", [node()])), "@"),
			{{Y, M, D}, {H, Min, S}} = calendar:universal_time(),
			Base = io_lib:format("~s-~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0B-",
								 [Name, Y, M, D, H, Min, S]),
			lists:map(fun({Class, _, _}) ->
							  Filename = io_lib:format("~s~s.log", [Base, Class]),
							  {Class, catch dump(Dir, Class, lists:flatten(Filename))}
					  end, Classes);
		Error ->
			Error
	end.

%% @doc Dump a log class to a text log file.
dump(Class, Filename) ->
	case state() of
		#?MODULE{dir=Dir} ->
			dump(Dir, Class, Filename);
		Error ->
			Error
	end.

%% @doc Open a log class.
%%      Opening a log class doesn't mean the logs in the class is shown in tty.
%%      Need to call show/1 explicitly to do that.
-spec open(atom()) -> ok | {error, reason()}.
open(Class) ->
	gen_server:call(?MODULE, {open, Class}).

%% @doc Close a log class.
%%      Closing a log class mean that the logs in the class is no longer stored.
-spec close(atom()) -> ok.
close(Class) ->
	gen_server:call(?MODULE, {close, Class}).

%% @doc Print logs in a class to tty.
-spec show() -> ok.
show() ->
	gen_server:call(?MODULE, show).

-spec show(atom()) -> ok.
show(Class) ->
	gen_server:call(?MODULE, {show, Class}).

%% @doc Hide logs in a class from tty.
-spec hide() -> ok.
hide() ->
	gen_server:call(?MODULE, hide).

-spec hide(atom()) -> ok.
hide(Class) ->
	gen_server:call(?MODULE, {hide, Class}).

%% @doc Set tty refresh interval.
-spec interval(timeout()) -> ok.
interval(T) ->
	gen_server:call(?MODULE, {interval, T}).

%% @doc Get the log manager state.
-spec state() -> #?MODULE{}.
state() ->
	gen_server:call(?MODULE, state).

%%
%% Callback Functions
%%
init(State=#?MODULE{dir=Dir, max_bytes=L, max_files=N, classes=Classes, interval=T}) ->
	?INFO(["log manager started", State]),
	Open = fun({Class, Show}, Acc) ->
				   case open(Class, Dir, L, N) of
					   {ok, {Class, Current}} ->
						   ?INFO(["disk_log open", Class]),
						   Acc++[{Class, Current, case Show of
													  show -> standard_io;
													  _ -> null
												  end}];
					   Error ->
						   ?ERROR(["can't open disk_log", Class, Error]),
						   Acc
				   end
		   end,
	{ok, State#?MODULE{classes=lists:foldl(Open, [], Classes)}, T}.

handle_call({open, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case open(Class, State#?MODULE.dir, State#?MODULE.max_bytes, State#?MODULE.max_files) of
		{ok, {Class, Current}} ->
			?INFO(["disk_log open", Class]),
			{reply, ok, State#?MODULE{classes=[{Class, Current, null} | Classes]}, T};
		Error ->
			?ERROR(["can't open disk_log", Class]),
			{reply, Error, State, T}
	end;
handle_call({close, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case lists:keytake(Class, 1, Classes) of
		{value, {Class, _, _}, Rest} ->
			case disk_log:close(Class) of
				ok ->
					?INFO(["disk_log closed", Class]),
					{reply, ok, State#?MODULE{classes=Rest}, T};
				Error ->
					?ERROR(["can't close disk_log", Class]),
					{reply, Error, State, T}
			end;
		false ->
			{reply, {error, not_found}, State, T}
	end;
handle_call(show, _, State=#?MODULE{interval=T}) ->
	Classes = [{Class, Current, standard_io} || {Class, Current, _} <- State#?MODULE.classes],
	{reply, ok, State#?MODULE{classes=Classes}, T};
handle_call({show, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case lists:keytake(Class, 1, Classes) of
		{value, {Class, Current, _}, Rest} ->
			{reply, ok, State#?MODULE{classes=[{Class, Current, standard_io} | Rest]}, T};
		false ->
			{reply, {error, not_found}, State, T}
	end;
handle_call(hide, _, State=#?MODULE{interval=T}) ->
	Classes = [{Class, Current, null} || {Class, Current, _} <- State#?MODULE.classes],
	{reply, ok, State#?MODULE{classes=Classes}, T};
handle_call({hide, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case lists:keytake(Class, 1, Classes) of
		{value, {Class, Current, _}, Rest} ->
			{reply, ok, State#?MODULE{classes=[{Class, Current, null} | Rest]}, T};
		false ->
			{reply, {error, not_found}, State, T}
	end;
handle_call({interval, T}, _, State=#?MODULE{interval=_}) ->
	{reply, ok, State#?MODULE{interval=T}, T};
handle_call(state, _, State=#?MODULE{interval=T}) ->
	{reply, State, State, T};
handle_call(Request, From, State) ->
	log(debug, ?MODULE, ["unknwon call", Request, From]),
	{reply, {error, unknown}, State}.

handle_cast(Message, State) ->
	log(debug, ?MODULE, ["unknown cast", Message]),
	{noreply, State}.

handle_info(timeout, State) ->
	F = fun({Class, Last, Io}, Acc) ->
			case consume_log(Class, Last, Io) of
				{ok, Current} ->
					Acc ++ [{Class, Current, Io}];
				Error ->
					?ERROR(["can't consume disk_log", Class, Error]),
					Acc
			end
		end,
	Classes = lists:foldl(F, [], State#?MODULE.classes),
	{noreply, State#?MODULE{classes=Classes}, State#?MODULE.interval};
handle_info(Info, State) ->
	log(debug, ?MODULE, ["unknown info", Info]),
	{noreply, State}.

terminate(Reason, State) ->
	Close = fun({Class, _, _}) ->
				disk_log:close(Class)
			end,
	lists:foreach(Close, State#?MODULE.classes),
	Reason.

code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local Functions
%%
open(Class, Dir, L, N) ->
   File = filename:join(Dir, io_lib:format("~s", [Class])),
   case disk_log:open([{name, Class}, {file, File}, {type, wrap}, {size, {L, N}}]) of
	   {error, Reason} ->
		   {error, Reason};
	   _ ->
		   {ok, Current} = consume_log(Class, start, null),
		   {ok, {Class, Current}}
   end.

consume_log(Log, Last, Io) ->
	case disk_log:chunk(Log, Last) of
		{error, Reason} ->
			{error, Reason};
		eof ->
			{ok, Last};
		{Current, Terms} ->
			case Io of
				null ->
					ok;
				_ ->
					Print = fun(Term) -> io:format(Io, "~1000p~n", [Term]) end,
					lists:foreach(Print, Terms)
			end,
			consume_log(Log, Current, Io)
	end.

dump(Dir, Class, Filename) ->
	Path = filename:join(Dir, io_lib:format("~s", [Class])),
	case disk_log:open([{name, Class}, {file, Path}, {type, wrap}]) of
		{error, Reason} ->
			{error, Reason};
		_ ->
			case file:open(Filename, [write]) of
				{ok, File} ->
					consume_log(Class, start, File),
					file:close(File);
				Error1 ->
					Error1
			end,
			disk_log:close(Class)
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.