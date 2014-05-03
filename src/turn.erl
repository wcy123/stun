%%%-------------------------------------------------------------------
%%% File    : turn.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Handles TURN allocations, see RFC5766
%%% Created : 23 Aug 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% stun, Copyright (C) 2002-2014   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%-------------------------------------------------------------------
-module(turn).

-define(GEN_FSM, gen_fsm).
-behaviour(?GEN_FSM).

%% API
-export([start_link/1, start/1, stop/1, route/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4,
	 handle_info/3, terminate/3, code_change/4]).

%% gen_fsm states
-export([wait_for_allocate/2, active/2]).

-include("stun.hrl").

%%-define(debug, true).
-ifdef(debug).
-define(dbg(Str, Args), error_logger:info_msg(Str, Args)).
-else.
-define(dbg(Str, Args), ok).
-endif.

-define(MAX_LIFETIME, 3600000). %% 1 hour
-define(DEFAULT_LIFETIME, 300000). %% 5 minutes
-define(PERMISSION_LIFETIME, 300000). %% 5 minutes
-define(CHANNEL_LIFETIME, 600000). %% 10 minutes
-define(DICT, dict).

-record(state, {sock_mod,
		sock,
		addr,
		owner,
		username,
		realm,
		key,
		permissions = ?DICT:new(),
		channels = ?DICT:new(),
		max_permissions,
		relay_ip,
		port_range,
		relay_addr,
		relay_sock,
		last_trid,
		last_pkt,
		seq = 1,
		life_timer}).

%%====================================================================
%% API
%%====================================================================
start_link(Opts) ->
    ?GEN_FSM:start_link(?MODULE, [Opts], []).

start(Opts) ->
    supervisor:start_child(turn_tmp_sup, [Opts]).

stop(Pid) ->
    ?GEN_FSM:send_all_state_event(Pid, stop).

route(Pid, Msg) ->
    ?GEN_FSM:send_event(Pid, Msg).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
init([Opts]) ->
    Owner = proplists:get_value(owner, Opts),
    Username = proplists:get_value(username, Opts),
    Realm = proplists:get_value(realm, Opts),
    AddrPort = proplists:get_value(addr, Opts),
    State = #state{sock_mod = proplists:get_value(sock_mod, Opts),
		   sock = proplists:get_value(sock, Opts),
		   key = proplists:get_value(key, Opts),
		   relay_ip = proplists:get_value(relay_ip, Opts),
		   port_range = proplists:get_value(port_range, Opts),
		   max_permissions = proplists:get_value(max_permissions, Opts),
		   realm = Realm, addr = AddrPort,
		   username = Username, owner = Owner},
    MaxAllocs = proplists:get_value(max_allocs, Opts),
    if is_pid(Owner) ->
	    erlang:monitor(process, Owner);
       true ->
	    ok
    end,
    TRef = erlang:start_timer(?DEFAULT_LIFETIME, self(), stop),
    {A1, A2, A3} = now(),
    random:seed(A1, A2, A3),
    case turn_sm:add_allocation(AddrPort, Username, Realm, MaxAllocs, self()) of
	ok ->
	    {ok, wait_for_allocate, State#state{life_timer = TRef}};
	{error, Reason} ->
	    {stop, Reason}
    end.

wait_for_allocate(#stun{class = request,
			method = ?STUN_METHOD_ALLOCATE} = Msg,
		  State) ->
    Resp = stun_codec:prepare_response(Msg),
    if Msg#stun.'REQUESTED-TRANSPORT' == undefined ->
	    R = Resp#stun{class = error,
			  'ERROR-CODE' = stun_codec:error(400)},
	    {stop, normal, send(State, R)};
       Msg#stun.'REQUESTED-TRANSPORT' == unknown ->
	    R = Resp#stun{class = error,
			  'ERROR-CODE' = stun_codec:error(442)},
	    {stop, normal, send(State, R)};
       Msg#stun.'DONT-FRAGMENT' == true ->
	    R = Resp#stun{class = error,
			  'UNKNOWN-ATTRIBUTES' = [?STUN_ATTR_DONT_FRAGMENT],
			  'ERROR-CODE' = stun_codec:error(420)},
	    {stop, normal, send(State, R)};
       true ->
	    case allocate_addr(State#state.port_range) of
		{ok, RelayPort, RelaySock} ->
		    Lifetime = time_left(State#state.life_timer),
		    AddrPort = State#state.addr,
		    RelayAddr = {State#state.relay_ip, RelayPort},
		    error_logger:info_msg(
		       "created TURN allocation for ~s@~s: ~s <-> ~s",
		       [State#state.username, State#state.realm,
			addr_to_str(AddrPort), addr_to_str(RelayAddr)]),
		    R = Resp#stun{class = response,
				  'XOR-RELAYED-ADDRESS' = RelayAddr,
				  'LIFETIME' = Lifetime,
				  'XOR-MAPPED-ADDRESS' = AddrPort},
		    NewState = send(State, R),
		    {next_state, active,
		     NewState#state{relay_sock = RelaySock,
				    relay_addr = RelayAddr}};
		Err ->
		    error_logger:error_msg(
		      "unable to allocate relay port for ~s@~s: ~s",
		      [State#state.username, State#state.realm,
		       format_error(Err)]),
		    R = Resp#stun{class = error,
				  'ERROR-CODE' = stun_codec:error(508)},
		    {stop, normal, send(State, R)}
	    end
    end;
wait_for_allocate(Event, State) ->
    error_logger:error_msg("unexpected event in wait_for_allocate: ~p", [Event]),
    {next_state, wait_for_allocate, State}.

active(#stun{trid = TrID}, #state{last_trid = TrID} = State) ->
    send(State, State#state.last_pkt),
    {next_state, active, State};
active(#stun{class = request,
	     method = ?STUN_METHOD_ALLOCATE} = Msg, State) ->
    Resp = stun_codec:prepare_response(Msg),
    R = Resp#stun{class = error,
		  'ERROR-CODE' = stun_codec:error(437)},
    {next_state, active, send(State, R)};
active(#stun{class = request,
	     method = ?STUN_METHOD_REFRESH} = Msg, State) ->
    Resp = stun_codec:prepare_response(Msg),
    case Msg#stun.'LIFETIME' of
	0 ->
	    R = Resp#stun{class = response, 'LIFETIME' = 0},
	    {stop, normal, send(State, R)};
	LifeTime ->
	    cancel_timer(State#state.life_timer),
	    MSecs = if LifeTime == undefined ->
			    ?DEFAULT_LIFETIME;
		       true ->
			    lists:min([LifeTime*1000, ?MAX_LIFETIME])
		    end,
	    TRef = erlang:start_timer(MSecs, self(), stop),
	    R = Resp#stun{class = response,
			  'LIFETIME' = (MSecs div 1000)},
	    {next_state, active, send(State#state{life_timer = TRef}, R)}
    end;
active(#stun{class = request,
	     'XOR-PEER-ADDRESS' = XorPeerAddrs,
	     method = ?STUN_METHOD_CREATE_PERMISSION} = Msg, State) ->
    Resp = stun_codec:prepare_response(Msg),
    PermLen = ?DICT:size(State#state.permissions) + length(XorPeerAddrs),
    if XorPeerAddrs == [] ->
	    R = Resp#stun{class = error,
			  'ERROR-CODE' = stun_codec:error(400)},
	    {next_state, active, send(State, R)};
       PermLen < State#state.max_permissions ->
	    Perms = lists:foldl(
		      fun({Addr, _Port}, Acc) ->
			      Channel = case ?DICT:find(Addr, Acc) of
					    {ok, {Chan, OldTRef}} ->
						cancel_timer(OldTRef),
						Chan;
					    error ->
						undefined
					end,
			      TRef = erlang:start_timer(
				       ?PERMISSION_LIFETIME, self(),
				       {permission_timeout, Addr}),
			      ?DICT:store(Addr, {Channel, TRef}, Acc)
		      end, State#state.permissions, XorPeerAddrs),
	    NewState = State#state{permissions = Perms},
	    R = Resp#stun{class = response},
	    {next_state, active, send(NewState, R)};
       true ->
	    R = Resp#stun{class = error,
			  'ERROR-CODE' = stun_codec:error(508)},
	    {next_state, active, send(State, R)}
    end;
active(#stun{class = indication,
	     method = ?STUN_METHOD_SEND,
	     'XOR-PEER-ADDRESS' = [{Addr, Port}],
	     'DATA' = Data}, State) when is_binary(Data) ->
    case ?DICT:find(Addr, State#state.permissions) of
	{ok, _} ->
	    gen_udp:send(State#state.relay_sock, Addr, Port, Data);
	error ->
	    ok
    end,
    {next_state, active, State};
active(#stun{class = request,
	     'CHANNEL-NUMBER' = Channel,
	     'XOR-PEER-ADDRESS' = [{Addr, Port}],
	     method = ?STUN_METHOD_CHANNEL_BIND} = Msg, State)
  when is_integer(Channel), Channel >= 16#4000, Channel =< 16#7ffe ->
    Resp = stun_codec:prepare_response(Msg),
    AddrPort = {Addr, Port},
    case ?DICT:find(Channel, State#state.channels) of
	{ok, {AddrPort, OldTRef}} ->
	    cancel_timer(OldTRef),
	    TRef = erlang:start_timer(?CHANNEL_LIFETIME, self(),
				      {channel_timeout, Channel}),
	    Chans = ?DICT:store(Channel, {AddrPort, TRef},
				State#state.channels),
	    NewState = State#state{channels = Chans},
	    R = Resp#stun{class = response},
	    {next_state, active, send(NewState, R)};
	error ->
	    case ?DICT:find(Addr, State#state.permissions) of
		{ok, {undefined, PermTRef}} ->
		    ChanTRef = erlang:start_timer(
				 ?CHANNEL_LIFETIME, self(),
				 {channel_timeout, Channel}),
		    Perms = ?DICT:store(Addr, {Channel, PermTRef},
					State#state.permissions),
		    Chans = ?DICT:store(Channel, {AddrPort, ChanTRef},
					State#state.channels),
		    NewState = State#state{channels = Chans,
					   permissions = Perms},
		    R = Resp#stun{class = response},
		    {next_state, active, send(NewState, R)};
		_ ->
		    R = Resp#stun{class = error,
				  'ERROR-CODE' = stun_codec:error(400)},
		    {next_state, active, send(State, R)}
	    end
    end;
active(#stun{class = request,
	     method = ?STUN_METHOD_CHANNEL_BIND} = Msg, State) ->
    Resp = stun_codec:prepare_response(Msg),
    R = Resp#stun{class = error,
		  'ERROR-CODE' = stun_codec:error(400)},
    {next_state, active, send(State, R)};
active(#turn{channel = Channel, data = Data}, State) ->
    case ?DICT:find(Channel, State#state.channels) of
	{ok, {{Addr, Port}, _}} ->
	    gen_udp:send(State#state.relay_sock,
			 Addr, Port, Data),
	    {next_state, active, State};
	error ->
	    {next_state, active, State}
    end;
active(Event, State) ->
    error_logger:error_msg("got unexpected event in active: ~p", [Event]),
    {next_state, active, State}.

handle_event(stop, _StateName, State) ->
    {stop, normal, State};
handle_event(Event, StateName, State) ->
    error_logger:error_msg("got unexpected event in ~s: ~p", [StateName, Event]),
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, {error, badarg}, StateName, State}.

handle_info({udp, Sock, Addr, Port, Data}, StateName, State) ->
    inet:setopts(Sock, [{active, once}]),
    case ?DICT:find(Addr, State#state.permissions) of
	{ok, {undefined, _}} ->
	    Seq = State#state.seq,
	    Ind = #stun{class = indication,
			method = ?STUN_METHOD_DATA,
			trid = Seq,
			'XOR-PEER-ADDRESS' = [{Addr, Port}],
			'DATA' = Data},
	    {next_state, StateName, send(State#state{seq = Seq+1}, Ind)};
	{ok, {Channel, _}} ->
	    TurnMsg = #turn{channel = Channel, data = Data},
	    {next_state, StateName, send(State, TurnMsg)};
	error ->
	    {next_state, StateName, State}
    end;
handle_info({timeout, _Tref, stop}, _StateName, State) ->
    {stop, normal, State};
handle_info({timeout, _Tref, {permission_timeout, Addr}},
	    StateName, State) ->
    ?dbg("permission for ~s timed out", [Addr]),
    case ?DICT:find(Addr, State#state.permissions) of
	{ok, {Channel, _}} ->
	    Perms = ?DICT:erase(Addr, State#state.permissions),
	    Chans = case ?DICT:find(Channel, State#state.channels) of
			{ok, {_, TRef}} ->
			    cancel_timer(TRef),
			    ?DICT:erase(Channel, State#state.channels);
			error ->
			    State#state.channels
		    end,
	    {next_state, StateName, State#state{permissions = Perms,
						channels = Chans}};
	error ->
	    {next_state, StateName, State}
    end;
handle_info({timeout, _Tref, {channel_timeout, Channel}},
	    StateName, State) ->
    ?dbg("channel ~p timed out", [Channel]),
    case ?DICT:find(Channel, State#state.channels) of
	{ok, {{Addr, _Port}, _}} ->
	    Chans = ?DICT:erase(Channel, State#state.channels),
	    Perms = case ?DICT:find(Addr, State#state.permissions) of
			{ok, {_, TRef}} ->
			    ?DICT:store(Addr, {undefined, TRef},
					State#state.permissions);
			error ->
			    State#state.permissions
		    end,
	    {next_state, StateName, State#state{channels = Chans,
						permissions = Perms}};
	error ->
	    {next_state, StateName, State}
    end;
handle_info({'DOWN', _Ref, _, _, _}, _StateName, State) ->
    {stop, normal, State};
handle_info(Info, StateName, State) ->
    error_logger:error_msg("got unexpected info in ~p: ~p", [StateName, Info]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, State) ->
    AddrPort = State#state.addr,
    Username = State#state.username,
    Realm = State#state.realm,
    case State#state.relay_addr of
	undefined ->
	    ok;
	RAddrPort ->
	    error_logger:info_msg(
	      "deleting TURN allocation for ~s@~s: ~s <-> ~s",
	      [Username, Realm, addr_to_str(AddrPort), addr_to_str(RAddrPort)])
    end,
    stun:stop(State#state.owner),
    turn_sm:del_allocation(AddrPort, Username, Realm).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
send(State, Pkt) when is_binary(Pkt) ->
    SockMod = State#state.sock_mod,
    Sock = State#state.sock,
    if SockMod == gen_udp ->
	    {Addr, Port} = State#state.addr,
	    gen_udp:send(Sock, Addr, Port, Pkt);
       true ->
	    case SockMod:send(Sock, Pkt) of
		ok -> ok;
		_  -> exit(normal)
	    end
    end;
send(State, Msg) ->
    ?dbg("send:~n~s", [stun_codec:pp(Msg)]),
    Key = State#state.key,
    case Msg of
	#stun{class = indication} ->
	    send(State, stun_codec:encode(Msg)),
	    State;
	#stun{class = response} ->
	    Pkt = stun_codec:encode(Msg, Key),
	    send(State, Pkt),
	    State#state{last_trid = Msg#stun.trid,
			last_pkt = Pkt};
	_ ->
	    send(State, stun_codec:encode(Msg, Key)),
	    State
    end.

time_left(TRef) ->
    erlang:read_timer(TRef) div 1000.

%% Simple port randomization algorithm from
%% draft-ietf-tsvwg-port-randomization-04
allocate_addr({Min, Max}) ->
    Count = Max - Min + 1,
    Next = Min + random:uniform(Count) - 1,
    allocate_addr(Min, Max, Next, Count).

allocate_addr(_Min, _Max, _Next, 0) ->
    {error, eaddrinuse};
allocate_addr(Min, Max, Next, Count) ->
    case gen_udp:open(Next, [binary, {active, once}]) of
	{ok, Sock} ->
	    case inet:sockname(Sock) of
		{ok, {_, Port}} ->
		    {ok, Port, Sock};
		Err ->
		    Err
	    end;
	{error, eaddrinuse} ->
	    if Next == Max ->
		    allocate_addr(Min, Max, Min, Count-1);
	       true ->
		    allocate_addr(Min, Max, Next+1, Count-1)
	    end;
	Err ->
	    Err
    end.

format_error({error, Reason}) ->
    case inet:format_error(Reason) of
	"unknown POSIX error" ->
	    Reason;
	Res ->
	    Res
    end.

addr_to_str({Addr, Port}) ->
    [inet_parse:ntoa(Addr), $:, integer_to_list(Port)];
addr_to_str(Addr) ->
    inet_parse:ntoa(Addr).

cancel_timer(undefined) ->
    ok;
cancel_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
	false ->
	    receive
                {timeout, TRef, _} ->
                    ok
            after 0 ->
                    ok
            end;
        _ ->
            ok
    end.