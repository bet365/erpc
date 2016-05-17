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

-module(erpc_server).

-behaviour(gen_server).

%% API
-export([start_link/0, connection_accepted/1, accept_failed/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {listen_socket, acceptor_pid, tmod}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

connection_accepted(_Pid) ->
    ?SERVER ! accept_connection.

accept_failed() ->
    ?SERVER ! accept_failed.
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Server_config = application:get_env(erpc, server_config, []),
    Listen_port   = proplists:get_value(listen_port, Server_config, 9090),
    TMod          = case proplists:get_value(transport, Server_config, tcp) of
                        tcp -> erpc_tcp;
                        ssl -> erpc_ssl
                    end,
    {ok, L_sock}  = TMod:listen(Listen_port, Server_config),
    process_flag(trap_exit, true),
    self() ! accept_connection,
    {ok, #state{listen_socket = L_sock, tmod = TMod}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(accept_connection, #state{listen_socket = L_sock,
                                      tmod          = TMod} = State) ->
    {ok, Pid} = erpc_server_socket:accept_connection(L_sock, TMod),
    {noreply, State#state{acceptor_pid = Pid}};

handle_info({'EXIT', Pid, Rsn}, #state{acceptor_pid = A_pid} = State) when Pid =:= A_pid ->
    {stop, Rsn, State};

handle_info(accept_failed, State) ->
    {stop, accept_failed, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
