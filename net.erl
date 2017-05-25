-module(net).
-export([listenForClients/1]).
-include("configuration.hrl").
-include("constants.hrl").

-define(TCP_OPTIONS, [binary, {active, false}, {reuseaddr, true}]).

listenForClients(World) ->
	{ok, Socket} = gen_tcp:listen(?SERVER_PORT, ?TCP_OPTIONS),
	accept(Socket, World).

accept(ServerSock, World) ->
	{ok, ClientSock} = gen_tcp:accept(ServerSock),
	NewClientPid = spawn(fun() -> clientLogin(ClientSock, World) end),
	% Make sure *child* receives events when socket is put in active mode
	gen_tcp:controlling_process(ClientSock, NewClientPid), 
	accept(ServerSock, World).

clientLogin(Sock, World) ->
	gen_tcp:send(Sock, "Login: "),
	case gen_tcp:recv(Sock, 0) of
		{ok, RawUsername} ->
			Username = string:to_lower(re:replace(RawUsername, "\\s+", "", [global,{return,list}])),
			World ! {newplayer, Username, self()},
			gen_tcp:send(Sock, ?BANNER),
			clientLoop(Sock, Username, World);
		{error, closed} ->
			ok
	end.	

clientLoop(Sock, Username, World) ->
	gen_tcp:send(Sock, ["Instructions, ", Username, "? "]),
	inet:setopts(Sock, [{active, once}]),
	receive
		{tcp, Sock, <<"quit", _/binary>>} -> 
			gen_tcp:close(Sock),
			World ! {lostplayer, Username};
		{tcp_closed, Sock} ->
			World ! {lostplayer, Username};
		{tcp_error, Sock, Reason} ->
			io:format("Error on socket ~p reason: ~p~n", [Sock, Reason]),
			World ! {lostplayer, Username};
		{tcp, Sock, Msg} ->
			parseCommand(Sock, Username, World, strings:rstrip(Msg)),
			clientLoop(Sock, Username, World)
		{message, From, Msg} ->
			gen_tcp:send(Sock, ["Message from '", From, "': \"", Msg, "\"\n"]);
		{announce, Msg} ->
			gen_tcp:send(Sock, ["Server announcement: \"", Msg, "\"\n"])
	end.

parseCommand(Sock, Username, World, Line) ->
	case strings:lcTokens(Line, " ") of
		["go", Direction] ->
			io:format("'~s' is traveling '~s'~n", [Username, Direction]),
			World ! {travel, Username, Direction, self()},
			receive
				{ok, NewLocation} ->
					gen_tcp:send(Sock, ["You are now at '", NewLocation, "'\n"]);
				{no_exit} ->
					gen_tcp:send(Sock, ["There is no exit to the '", Direction, "'\n"])
			end;
		["take", Item] ->
			io:format("'~s' is picking up '~s'~n", Username, Item),
			World ! {take, Username, Item, self()};
		["look"] ->
			World ! {getRoomDescription, Username, self()},
			receive
				{ok, Description} ->
					gen_tcp:send(Sock, [Description, "\n"]);
				{error, Description} ->
					gen_tcp:send(Sock, "Something has gone wrong -- cannot get room description\n")
			end;
		["help"] ->
			gen_tcp:send(Sock, [?INSTRUCTIONS, "\n"]);
		["who", "am", "i"] ->
			gen_tcp:send(Sock, ["Your name is ", Username, "\n"]);
		_Else ->
			gen_tcp:send(Sock, [getRandomDidNotUnderstand(), "\n"]),
			io:format("Stuck parsing: '~p'~n", [string:tokens(Line, " ")])
	end.

getRandomDidNotUnderstand() ->
	Responses = [
		"I didn't understand that.",
		"What's that?",
		"Reply hazy, try again later.",
		"Speak up, I can't hear you."
		],
	Index = rand:uniform(length(Responses)),
	lists:nth(Index, Responses).
