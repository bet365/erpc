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

-module(erpc_server_socket).

-behaviour(gen_server).

%% API
-export([accept_connection/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-import(erpc_lib, [log_msg/2]).

-record(state, {listen_socket,
                tmod,
                conn_handle,
                peer_host,
                peer_node,
                acl,
                missed_heartbeats = 0,
                heart_ref
               }).

-include("erpc.hrl").

%%%===================================================================
%%% API
%%%===================================================================

accept_connection(Listen_socket, TMod) ->
    gen_server:start_link(?MODULE, [Listen_socket, TMod], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Listen_socket, TMod]) ->
    self() ! accept_connection,
    process_flag(trap_exit, true),
    {ok, #state{listen_socket = Listen_socket,
                tmod          = TMod}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(accept_connection,
            #state{tmod          = TMod,
                   listen_socket = L_sock} = State) ->
    case TMod:accept(L_sock) of
        {ok, Conn_handle} ->
            erpc_server:connection_accepted(self()),
            Peer_host = TMod:host(Conn_handle),
            Host_acl  = get_host_acl(Peer_host),
            case is_host_allowed(Host_acl) of
                true ->
                    ets:insert(erpc_incoming_conns, {self(), Peer_host, undefined}),
                    ok  = TMod:setopts(Conn_handle, [{active, once}]),
                    Ref = timer:send_interval(5000, self(), heartbeat),
                    {noreply, State#state{conn_handle = Conn_handle,
                                          peer_host   = Peer_host,
                                          acl         = Host_acl,
                                          heart_ref   = Ref
                                         }};
                false ->
                    TMod:close(Conn_handle),
                    {stop, normal, State}
            end;
        {error, closed} ->
            catch erpc_server:accept_failed(),
            {stop, normal, State};
        Err ->
            log_msg("Accept failed. Reason: ~p~n", [Err]),
            catch erpc_server:accept_failed(),
            {stop, normal, State}
    end;

handle_info({tcp, _Socket, Data}, State) ->
    Result = handle_incoming_data(Data, State),
    Result;

handle_info({ssl, _Socket, Data}, State) ->
    Result = handle_incoming_data(Data, State),
    Result;

handle_info(heartbeat, #state{conn_handle = undefined} = State) ->
    {noreply, State};

handle_info(heartbeat,
            #state{conn_handle       = Conn_handle,
                   missed_heartbeats = M,
                   tmod              = TMod,
                   peer_host         = Peer_host} = State) ->
    %% log_msg("Sending heartbeat to client : ~p~n", [Peer_host]),
    ok = TMod:send(Conn_handle, heartbeat()),
    M_1 = M + 1,
    case M_1 > 3 of
        true ->
            log_msg("Missed ~p heartbeats from ~p. Closing connection~n", [M_1, Peer_host]),
            _ = cleanup(State),
            {stop, normal, State};
        false ->
            {noreply, State#state{missed_heartbeats = M_1}}
    end;

handle_info({tcp_closed, _Socket}, State) ->
    State_1 = handle_conn_closed(State, tcp_closed),
    {stop, normal, State_1};

handle_info({tcp_error, _Socket, Rsn}, State) ->
    State_1 = handle_conn_closed(State, {tcp_error, Rsn}),
    {stop, normal, State_1};

handle_info({ssl_closed, _Socket}, State) ->
    State_1 = handle_conn_closed(State, ssl_closed),
    {stop, normal, State_1};

handle_info({ssl_error, _Socket, Rsn}, State) ->
    State_1 = handle_conn_closed(State, {ssl_error, Rsn}),
    {stop, normal, State_1};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = cleanup(_State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_incoming_data(Data,
                     #state{acl         = ACL,
                            peer_host   = Peer_host,
                            tmod        = TMod,
                            conn_handle = Conn_handle} = State) ->
    TMod:setopts(Conn_handle, [{active, once}]),
    case binary_to_term(Data) of
        heartbeat ->
            %% log_msg("Recvd heartbeat from client : ~p~n", [Peer_host]),
            {noreply, State#state{missed_heartbeats = 0}};
        {?CALL, Call_ref, Mod, Fun, Args} ->
            _ = case is_mf_allowed(Mod, Fun, ACL) of
                    true ->
                        spawn(fun() ->
                                      worker(Call_ref, TMod, Mod, Fun, Args, Conn_handle)
                              end);
                    false ->
                        ok
                end,
            {noreply, State};
        {?BLOCK_CALL, Call_ref, Mod, Fun, Args} ->
            _ = case is_mf_allowed(Mod, Fun, ACL) of
                    true ->
                        worker(Call_ref, TMod, Mod, Fun, Args, Conn_handle);
                    false ->
                        ok
                end,
            {noreply, State};
        {?CAST, Mod, Fun, Args} ->
            _ = case is_mf_allowed(Mod, Fun, ACL) of
                    true ->
                        spawn(fun() ->
                                      worker(Mod, Fun, Args)
                              end);
                    false ->
                        ok
                end,
            {noreply, State};
        {?ABCAST, Proc_name, Msg} ->
            catch Proc_name ! Msg,
            {noreply, State};
        {?SBCAST, Call_ref, Proc_name, Msg} ->
            _ = worker(Call_ref, Proc_name, Msg, TMod, Conn_handle),
            {noreply, State};
        {?IDENTITY, Peer_node} ->
            log_msg("Server connected to peer node: ~p~n", [Peer_node]),
            ets:insert(erpc_incoming_conns, {self(), Peer_host, Peer_node}),
            send_node_identity(State),
            ACL_node = get_node_acl(Peer_node, State#state.acl),
            case ACL_node of
                deny ->
                    ok = TMod:close(Conn_handle),
                    _  = cleanup(State),
                    {stop, normal, State};
                _ ->
                    {noreply, State#state{acl = ACL_node, peer_node = Peer_node}}
            end
    end.

handle_conn_closed(State, Rsn) ->
    log_msg("Connection from ~p closed. Reason: ~p~n", [State#state.peer_host, Rsn]),
    State_1 = cleanup(State),
    State_1.

cleanup(State) ->
    catch ets:delete(erpc_incoming_conns, self()),
    catch timer:cancel(State#state.heart_ref),
    State#state{heart_ref = undefined}.

worker(Mod, Fun, Args) ->
    apply(Mod, Fun, Args).

worker(Call_ref, TMod, Mod, Fun, Args, Conn_handle) ->
    Res = (catch apply(Mod, Fun, Args)),
    Reply = term_to_binary({?CALL_RESULT, Call_ref, Res}),
    ok = TMod:send(Conn_handle, Reply).

worker(Call_ref, Proc_name, Msg, TMod, Conn_handle) ->
    Res = case catch Proc_name ! Msg of
                {'EXIT', _} ->
                    {?SBCAST_FAILED, Call_ref};
                Msg ->
                    {?SBCAST_SUCCESS, Call_ref}
            end,
    Reply = term_to_binary(Res),
    ok = TMod:send(Conn_handle, Reply).

get_host_acl(Host) ->
    Server_config = application:get_env(erpc, server_config, []),
    ACLs          = proplists:get_value(host_acls, Server_config, []),
    case lists:keyfind(Host, 1, ACLs) of
        false ->
            application:get_env(erpc, default_host_acl, allow);
        {_, ACL} ->
            ACL
    end.

get_node_acl(Node, Host_acl) ->
    Server_config = application:get_env(erpc, server_config, []),
    ACLs          = proplists:get_value(node_acls, Server_config, []),
    case lists:keyfind(Node, 1, ACLs) of
        false ->
            case application:get_env(erpc, default_node_acl) of
                {ok, deny} ->
                    deny;
                {ok, ACL} ->
                    ACL;
                undefined ->
                    Host_acl
            end;
        {_, ACL} ->
            ACL
    end.

is_host_allowed(deny) -> false;
is_host_allowed(_)    -> true.

is_mf_allowed(_, _, allow) -> true;
is_mf_allowed(_M, _F, all) -> true;
is_mf_allowed(M, F, ACL) when is_list(ACL) ->
    lists:member(M, ACL)       
        orelse 
    lists:member({M, F}, ACL).

heartbeat() ->
    term_to_binary(heartbeat).

send_node_identity(#state{conn_handle = Conn_handle,
                          tmod        = TMod}) ->
    ok = TMod:send(Conn_handle, term_to_binary({?IDENTITY, node()})).
