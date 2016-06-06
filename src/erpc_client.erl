%%
%% %CopyrightBegin%
%%
%% Copyright Hillside Technology Ltd. 2016. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

-module(erpc_client).

-behaviour(gen_server).

-export([
         %% API
         start_link/1,
         call/5,
         block_call/5,
         abcast/3,
         cast/4,
         sbcast/3,

         %% gen_server callbacks
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-import(erpc_lib, [log_msg/2]).

-record(client_state, {conn_name, tmod, %% host, port = 9090,
                       conn_config,
                       conn_handle,
                       heartbeat_ref,
                       missed_heartbeats = 0,
                       peer_node
                      }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Conn_config) ->
    gen_server:start_link(?MODULE, [Conn_config], []).

call(Name, M, F, A, Timeout) ->
    case erpc_lb:get_conn_pid(Name) of
        {ok, {_Pid, TMod, Conn_handle}} ->
            Call_ref = make_call_ref(),
            ok = TMod:send(Conn_handle, term_to_binary({call, Call_ref, M, F, A})),
            Resp = wait_for_reply(Timeout, Call_ref),
            Resp;
        _ ->
            {badrpc, not_connected}
    end.

block_call(Name, M, F, A, Timeout) ->
    case erpc_lb:get_conn_pid(Name) of
        {ok, {_Pid, TMod, Conn_handle}} ->
            Call_ref = make_call_ref(),
            ok = TMod:send(Conn_handle, term_to_binary({block_call, Call_ref, M, F, A})),
            Resp = wait_for_reply(Timeout, Call_ref),
            Resp;
        _ ->
            {badrpc, not_connected}
    end.

make_call_ref() ->
    case catch erlang:unique_integer([monotonic]) of
        {'EXIT', _} ->
            {os:timestamp(), self()};
        Int ->
            {Int, self()}
    end.

wait_for_reply(Timeout, Call_ref) ->
    receive
        {call_result, Call_ref, Res} ->
            Res;
        {conn_closed, Call_ref} ->
            {badrpc, conn_closed}
    after Timeout ->
            {badrpc, timeout}
    end.

cast(Name, M, F, A) ->
    case erpc_lb:get_conn_pid(Name) of
        {ok, {_Pid, TMod, Conn_handle}} ->
            ok = TMod:send(Conn_handle, term_to_binary({cast, M, F, A}));
        _ ->
            {badrpc, not_connected}
    end.

abcast([], _Proc_name, _Msg) ->
    abcast;
abcast([Name | T], Proc_name, Msg) ->
    case erpc_lb:get_conn_pid(Name) of
        {ok, {_Pid, TMod, Conn_handle}} ->
            ok = TMod:send(Conn_handle, term_to_binary({abcast, Proc_name, Msg}));
        _ ->
            ok
    end,
    abcast(T, Proc_name, Msg).

sbcast(Names, Proc_name, Msg) when is_list(Names) ->
    Parent_pid = self(),
    Pids = lists:map(
             fun(X_name) ->
                     spawn(
                       fun() ->
                               sbcast(Parent_pid, X_name, Proc_name, Msg)
                       end)
             end, Names),
    wait_for_sbcast_results(Pids).

sbcast(Parent_pid, Name, Proc_name, Msg) when is_atom(Name) ->
    case erpc_lb:get_conn_pid(Name) of
        {ok, {_Pid, TMod, Conn_handle}} ->
            Call_ref = make_call_ref(),
            ok = TMod:send(Conn_handle, term_to_binary({sbcast, Call_ref, Proc_name, Msg})),
            Resp = wait_for_sbcast_reply(Parent_pid, Name, Call_ref),
            Resp;
        _ ->
            Parent_pid ! {sbcast_failed, self(), Name}
    end.

wait_for_sbcast_reply(Parent_pid, Name, Call_ref) ->
    receive
        {sbcast_success, Call_ref} ->
            Parent_pid ! {sbcast_success, self(), Name};
        {sbcast_failed, Call_ref} ->
            Parent_pid ! {sbcast_failed, self(), Name}
    end.

wait_for_sbcast_results(Pids) ->
    wait_for_sbcast_results(Pids, [], []).

wait_for_sbcast_results([], Good, Bad) ->
    {Good, Bad};
wait_for_sbcast_results([Pid | T], Good, Bad) ->
    receive
        {sbcast_success, Pid, Name} ->
            wait_for_sbcast_results(T, [Name | Good], Bad);
        {sbcast_failed, Pid, Name} ->
            wait_for_sbcast_results(T, Good, [Name | Bad])
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([{Conn_name, Conn_config}]) ->
    process_flag(trap_exit, true),
    self() ! retry_connect,
    TMod = case proplists:get_value(transport, Conn_config, tcp) of
               tcp -> erpc_tcp;
               ssl -> erpc_ssl
           end,
    {ok, #client_state{conn_name   = Conn_name,
                       tmod        = TMod,
                       conn_config = Conn_config
                      }}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, _Socket, Data}, State) ->
    Result = handle_incoming_data(State, Data),
    Result;

handle_info({ssl, _Socket, Data}, State) ->
    Result = handle_incoming_data(State, Data),
    Result;

handle_info(retry_connect, #client_state{conn_handle = Conn_handle,
                                         conn_config = Conn_config,
                                         tmod        = TMod
                                        } = State) when Conn_handle =:= undefined ->
    case TMod:connect(Conn_config) of
        {ok, Conn_handle_new} ->
            true      = ets:insert(erpc_outgoing_conns, {self(), TMod:host(Conn_handle_new), undefined}),
            {ok, Ref} = timer:send_interval(5000, self(), heartbeat),
            State_1   = State#client_state{conn_handle   = Conn_handle_new,
                                           heartbeat_ref = Ref},
            send_node_identity(State_1),
            {noreply, State_1};
        _Err ->
            erlang:send_after(5000, self(), retry_connect),
            {noreply, State}
    end;

handle_info({tcp_closed, _Socket}, State) ->
    State_1 = handle_conn_closed(State, tcp_closed),
    {noreply, State_1};

handle_info({tcp_error, _Socket, _Err}, State) ->
    State_1 = handle_conn_closed(State, {tcp_error, _Err}),
    {noreply, State_1};

handle_info({ssl_closed, _Socket}, State) ->
    State_1 = handle_conn_closed(State, ssl_closed),
    {noreply, State_1};

handle_info({ssl_error, _Socket, _Err}, State) ->
    State_1 = handle_conn_closed(State, {ssl_error, _Err}),
    {noreply, State_1};

handle_info(heartbeat, #client_state{conn_handle = undefined} = State) ->
    {noreply, State};

handle_info(heartbeat, #client_state{conn_handle       = Conn_handle,
                                     tmod              = TMod,
                                     missed_heartbeats = M,
                                     peer_node         = Peer_node
                                    } = State) ->
    %% log_msg("Sending heartbeat to server : ~p~n", [Host]),
    ok = TMod:send(Conn_handle, heartbeat()),
    M_1 = M + 1,
    case M_1 > 3 of
        true ->
            log_msg("Missed ~p heartbeats from ~p. Closing connection~n", [M_1, Peer_node]),
            State_1 = cleanup(State),
            {noreply, State_1};
        false ->
            {noreply, State#client_state{missed_heartbeats = M_1}}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    log_msg("Client process terminating. Reason: ~p~n", [_Reason]),
    _ = cleanup(_State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_incoming_data(#client_state{conn_handle = Conn_handle,
                                   conn_name   = Conn_name,
                                   tmod        = TMod} = State,
                     Data) ->
    TMod:setopts(Conn_handle, [{active, once}]),
    case catch binary_to_term(Data) of
        heartbeat ->
            {noreply, State#client_state{missed_heartbeats = 0}};
        {call_result, {_, Caller_pid} = _Call_ref, _Res} = Call_result ->
            Caller_pid ! Call_result,
            {noreply, State};
        {sbcast_failed, {_, Caller_pid} = _Call_ref} = Call_result ->
            Caller_pid ! Call_result,
            {noreply, State};
        {sbcast_success, {_, Caller_pid} = _Call_ref} = Call_result ->
            Caller_pid ! Call_result,
            {noreply, State};
        {identity, Peer_node} ->
            log_msg("Client connected to peer-node ~p[~p]~n", [Conn_name, Peer_node]),
            ets:insert(erpc_outgoing_conns, {self(), TMod:host(Conn_handle), Peer_node}),
            erpc_monitor:broadcast_node_up(Peer_node),
            ok = erpc_lb:connected(Conn_name, TMod, Conn_handle),
            {noreply, State#client_state{peer_node = Peer_node}};
        _Err ->
            {stop, normal, State}
    end.

handle_conn_closed(#client_state{conn_name = Conn_name,
                                 peer_node = Peer_node} = State,
                   Reason) ->
    log_msg("Lost client connection to ~p[~p]: ~p~n", [Conn_name, Peer_node, Reason]),
    State_1 = cleanup(State),
    State_1.

cleanup(#client_state{tmod          = TMod,
                      conn_name     = Conn_name,
                      conn_handle   = Conn_handle,
                      heartbeat_ref = Heart_ref,
                      peer_node     = Peer_node} = State) ->
    ets:delete(erpc_outgoing_conns, self()),
    erpc_monitor:broadcast_node_down(Peer_node),
    erpc_lb:disconnected(Conn_name),
    catch TMod:close(Conn_handle),
    catch timer:cancel(Heart_ref),
    erlang:send_after(1000, self(), retry_connect),
    State#client_state{conn_handle       = undefined,
                       heartbeat_ref     = undefined,
                       missed_heartbeats = 0}.

heartbeat() ->
    term_to_binary(heartbeat).

send_node_identity(#client_state{conn_handle = Conn_handle,
                                 tmod        = TMod}) ->
    ok = TMod:send(Conn_handle, term_to_binary({identity, node()})).
