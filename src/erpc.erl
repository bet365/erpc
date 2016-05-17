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

-module(erpc).
-export([
         call/4,
         call/5,
         cast/4,
         multicall/4,
         multicall/5,
         multicast/4,
         conn_status/0,
         is_connected/1,
         incoming_conns/0,
         outgoing_conns/0,
         connect/1,
         connect/2,
         disconnect/1
        ]).

call(Name, M, F, A) when is_atom(Name),
                         is_atom(M),
                         is_atom(F),
                         is_list(A) ->
    call(Name, M, F, A, 5000).

call(Name, M, F, A, Timeout) when is_atom(Name),
                                  is_atom(M),
                                  is_atom(F),
                                  is_list(A),
                                  ((is_integer(Timeout) andalso (Timeout >= 0)) orelse
                                   (Timeout == infinity)) ->
    erpc_client:call(Name, M, F, A, Timeout).

cast(Name, M, F, A) when is_atom(Name),
                         is_atom(M),
                         is_atom(F),
                         is_list(A) ->
    erpc_client:cast(Name, M, F, A).

multicall(Names, M, F, A) ->
    multicall(Names, M, F, A, 5000).

multicall(Names, M, F, A, Timeout) when is_list(Names),
                                        is_atom(M),
                                        is_atom(F),
                                        is_list(A),
                                        ((is_integer(Timeout) andalso (Timeout >= 0)) orelse
                                         (Timeout == infinity)) ->
    Caller_pid = self(),
    Pids = lists:map(
             fun(X_name) ->
                     spawn(fun() ->
                                   Res = call(X_name, M, F, A, Timeout),
                                   Caller_pid ! {self(), X_name, Res}
                           end)
             end, Names),
    wait_for_pids(Pids, [], []).

wait_for_pids([Pid | T], Acc, Bad_nodes) ->
    receive
        {Pid, Conn_name, {badrpc, not_connected}} when is_pid(Pid) ->
            wait_for_pids(T, Acc, Bad_nodes ++ [Conn_name]);
        {Pid, _Conn_name, Res} when is_pid(Pid) ->
            wait_for_pids(T, Acc ++ [Res], Bad_nodes)
    end;
wait_for_pids([], Acc, Bad_nodes) ->
    {Acc, Bad_nodes}.

multicast(Names, M, F, A) ->
    lists:foreach(
      fun(X_name) ->
              spawn(erpc_client, cast, [X_name, M, F, A])
      end, Names).

incoming_conns() ->
    lists:usort(
      [Node || {_, _, Node} <- ets:tab2list(erpc_incoming_conns)]).

outgoing_conns() ->
    lists:usort(
      [Node || {_, _, Node} <- ets:tab2list(erpc_outgoing_conns)]).

is_connected(Name) ->
    erpc_lb:is_connected(Name).

conn_status() ->
    erpc_lb:conn_status().

connect(Conn_name) ->
    erpc_sup:connect(Conn_name).

connect(Conn_name, Conn_config) ->
    erpc_sup:connect(Conn_name, Conn_config).

disconnect(Conn_name) ->
    erpc_sup:disconnect(Conn_name).

