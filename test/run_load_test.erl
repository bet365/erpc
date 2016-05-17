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

-module(run_load_test).
-export([start/0]).

-define(TEST_NODE_1, erpc_test_1@localhost).
-define(TEST_NODE_2, erpc_test_2@localhost).

start() ->
    N_workers = get_arg_val(num_workers, 100),
    N_reqs    = get_arg_val(num_requests_per_worker, 100),
    N_conns   = get_arg_val(num_connections_per_node, 5),
    Rpc_type  = get_arg_val(rpc_type, erpc),
    N_nodes   = get_arg_val(num_erpc_server_nodes, 1),
    start(N_workers, N_reqs, N_conns, N_nodes, Rpc_type).

get_arg_val(Tag, Def_val) ->
    try
        [Val_str] = proplists:get_value(Tag, init:get_arguments()),
        case Tag of
            rpc_type ->
                Val_atom  = list_to_atom(Val_str),
                true      = ((Val_atom == native) orelse (Val_atom == erpc)),
                Val_atom;
            _ ->
                Val_int   = list_to_integer(Val_str),
                true      = is_integer(Val_int),
                true      = (Val_int > 0),
                Val_int
        end
    catch _:_ ->
            Def_val
    end.

start(Num_workers, Num_reqs, N_conns, N_nodes, Rpc_type) ->
    application:ensure_all_started(erpc),
    put(num_server_nodes, N_nodes),
    initialise_connection(Rpc_type, N_conns),
    ets:new(ts_counters, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    ets:new(counters,    [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    ets:new(worker_pids, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    log_msg("Starting spawn of ~p workers...~n", [Num_workers]),
    spawn_workers(Num_workers, Num_reqs, Rpc_type),
    log_msg("Finished spawning workers~n", []),
    wait_for_finish(),
    print_results(),
    erlang:halt().

initialise_connection(erpc = Rpc_type, N_conns) ->
    Hosts = case get(num_server_nodes) of
                1 -> [{"localhost", 9091}];
                _ -> [{"localhost", 9091}, {"localhost", 9092}]
            end,
    erpc:connect('LOAD_TEST', [{transport, tcp},
                               {num_connections, N_conns},
                               {hosts, Hosts}]),
    ok = wait_for_connections(Rpc_type, get(num_server_nodes));
initialise_connection(native, _) ->
    net_adm:ping(?TEST_NODE_1),
    wait_for_connections(native, undefined).

wait_for_connections(erpc, N_nodes) ->
    Out_conns = erpc:outgoing_conns(),
    case length(Out_conns) == N_nodes of
        true ->
            ok;
        false ->
            log_msg("Conn_status: ~p. Waiting...~n", [Out_conns]),
            timer:sleep(5000),
            wait_for_connections(erpc, N_nodes)
    end;
wait_for_connections(native, _) ->
    case lists:member(?TEST_NODE_1, erlang:nodes(connected)) of
        true ->
            ok;
        false ->
            log_msg("Retrying ping in 5 seconds...~n", []),
            timer:sleep(5000),
            initialise_connection(native, undefined)
    end.

spawn_workers(0, _, _) ->
    ok;
spawn_workers(Num_workers, Num_reqs, Rpc_type) ->
    Pid = spawn(fun() ->
                        worker_init(Num_reqs, Rpc_type)
                end),
    ets:insert(worker_pids, {Pid, []}),
    Pid ! start,
    spawn_workers(Num_workers - 1, Num_reqs, Rpc_type).

wait_for_finish() ->
    case ets:info(worker_pids, size) of
        0 ->
            ok;
        N ->
            log_msg("Waiting for ~p workers to finish...~n", [N]),
            timer:sleep(5000),
            wait_for_finish()
    end.

worker_init(Num_reqs, Rpc_type) ->
    receive
        start ->
            worker_loop(Num_reqs, Rpc_type)
    end.

worker_loop(0, _) ->
    ets:delete(worker_pids, self()),
    ok;
worker_loop(N, Rpc_type) ->
    update_counter(req_attempted, 1),
    case do_rpc(Rpc_type) of
        Node when is_atom(Node) ->
            update_ts_counter(Node, 1),
            update_ts_counter(success, 1);
        {badrpc, Reason} ->
            update_ts_counter(Reason, 1)
    end,
    worker_loop(N - 1, Rpc_type).

do_rpc(erpc) ->
    erpc:call('LOAD_TEST', erlang, node, []);
do_rpc(native) ->
    rpc:call(?TEST_NODE_1, erlang, node, []).

update_ts_counter(Key, Val) ->
    Key_ts = {calendar:local_time(), Key},
    ets:update_counter(ts_counters, Key_ts, {2, Val}, {Key_ts, 0}).

update_counter(Key, Val) ->
    ets:update_counter(counters, Key, {2, Val}, {Key, 0}).

log_msg(Fmt, Args) ->
    io:format("~s -- " ++ Fmt, [printable_ts(calendar:local_time()) | Args]).

print_results() ->
    Dict = lists:foldl(
               fun({{Ts, Key}, Val}, X_dict) ->
                       dict:update(Ts, 
                                   fun(Res_tvl) ->
                                           [{Key, Val} | Res_tvl]
                                   end, [{Key, Val}], X_dict)
               end, dict:new(), ets:tab2list(ts_counters)),
    Res_tvl         = lists:keysort(1, dict:to_list(Dict)),
    Start_time      = element(1, hd(Res_tvl)),
    End_time        = element(1, hd(lists:reverse(Res_tvl))),
    {TT_d, TT_s}    = calendar:time_difference(Start_time, End_time),
    TT_secs         = TT_d*86400 + calendar:time_to_seconds(TT_s),
    [{_, Num_reqs}] = ets:lookup(counters, req_attempted),
    io:format("~n", []),
    io:format("Start time                   : ~s~n", [printable_ts(Start_time)]),
    io:format("End time                     : ~s~n", [printable_ts(End_time)]),
    io:format("Elapsed time (seconds)       : ~p~n", [TT_secs]),
    io:format("Number of attempted requests : ~p~n", [Num_reqs]),
    io:format("Req/sec                      : ~p~n", [trunc(Num_reqs/TT_secs)]),
    io:format("~n", []),
    io:format("~-30.30.\ss success, node_1, node_2, timeout, not_connected~n", ["Timestamp"]),
    lists:foreach(fun({X_key, X_vals}) ->
                          X_succ     = proplists:get_value(success, X_vals, 0),
                          X_node_1   = proplists:get_value(?TEST_NODE_1, X_vals, 0),
                          X_node_2   = proplists:get_value(?TEST_NODE_2, X_vals, 0),
                          X_timeout  = proplists:get_value(timeout, X_vals, 0),
                          X_not_conn = proplists:get_value(not_connected, X_vals, 0),
                          io:format("~s\t\t~6.6.\sw, ~6.6.\sw, ~6.6.\sw, ~6.6.\sw, ~p~n", 
                                    [printable_ts(X_key),
                                     X_succ, X_node_1, X_node_2,
                                     X_timeout, X_not_conn])
                  end, Res_tvl).
printable_ts({{Y, M, D}, {H, Mi, S}}) ->
    io_lib:format("~p-~2.2.0w-~2.2.0w_~2.2.0w:~2.2.0w:~2.2.0w", [Y, M, D, H, Mi, S]).
