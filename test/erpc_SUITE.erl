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

-module(erpc_SUITE).

-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

-include_lib("common_test/include/ct.hrl").

-define(TEST_NODE_1, erpc_test_1@localhost).
-define(TEST_NODE_2, erpc_test_2@localhost).
-define(SELF_CONN,     node()).
-define(SELF_CONN_2,   node()).
%%--------------------------------------------------------------------
%% @spec suite() -> Info
%% Info = [tuple()]
%% @end
%%--------------------------------------------------------------------
suite() ->
    [{timetrap,{seconds,30}}].

%%--------------------------------------------------------------------
%% @spec init_per_suite(Config0) ->
%%     Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
init_per_suite(Config) ->
    configure_test_nodes(),
    application:load(erpc),
    application:set_env(erpc, server_config, [{transport, tcp},
                                              {listen_port, 9090},
                                              {default_node_acl, allow}]),
    _Res = application:ensure_all_started(erpc),
    ok = erpc:connect(?TEST_NODE_1, [{transport, tcp},
                                     {hosts, [{"localhost", 9091}]}]),
    ok = erpc:connect(?TEST_NODE_2, [{transport, tcp},
                                     {hosts, [{"localhost", 9092}]}]),
    ok = erpc:connect(?SELF_CONN,   [{transport, tcp},
                                     {hosts, [{"localhost", 9090}]}]),
    ok = erpc:connect(?SELF_CONN_2, [{transport, tcp},
                                     {hosts, [{"localhost", 9090}]}]),
    timer:sleep(1000),
    Config.

%%--------------------------------------------------------------------
%% @spec end_per_suite(Config0) -> void() | {save_config,Config1}
%% Config0 = Config1 = [tuple()]
%% @end
%%--------------------------------------------------------------------
end_per_suite(_Config) ->
    application:stop(erpc),
    %% Slave_nodes = get_value(slave_nodes, Config),
    %% lists:foreach(
    %%   fun(X) ->
    %%           rpc:async_call(X, init, stop, [])
    %%   end, Slave_nodes),
    ok.

%%--------------------------------------------------------------------
%% @spec init_per_group(GroupName, Config0) ->
%%               Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%% GroupName = atom()
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
init_per_group(_GroupName, Config) ->
    Config.

%%--------------------------------------------------------------------
%% @spec end_per_group(GroupName, Config0) ->
%%               void() | {save_config,Config1}
%% GroupName = atom()
%% Config0 = Config1 = [tuple()]
%% @end
%%--------------------------------------------------------------------
end_per_group(_GroupName, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% @spec init_per_testcase(TestCase, Config0) ->
%%               Config1 | {skip,Reason} | {skip_and_save,Reason,Config1}
%% TestCase = atom()
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% @spec end_per_testcase(TestCase, Config0) ->
%%               void() | {save_config,Config1} | {fail,Reason}
%% TestCase = atom()
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% @spec groups() -> [Group]
%% Group = {GroupName,Properties,GroupsAndTestCases}
%% GroupName = atom()
%% Properties = [parallel | sequence | Shuffle | {RepeatType,N}]
%% GroupsAndTestCases = [Group | {group,GroupName} | TestCase]
%% TestCase = atom()
%% Shuffle = shuffle | {shuffle,{integer(),integer(),integer()}}
%% RepeatType = repeat | repeat_until_all_ok | repeat_until_all_fail |
%%              repeat_until_any_ok | repeat_until_any_fail
%% N = integer() | forever
%% @end
%%--------------------------------------------------------------------
groups() ->
    %% [{client, [], [test_list]}].
    [].

%%--------------------------------------------------------------------
%% @spec all() -> GroupsAndTestCases | {skip,Reason}
%% GroupsAndTestCases = [{group,GroupName} | TestCase]
%% GroupName = atom()
%% TestCase = atom()
%% Reason = term()
%% @end
%%--------------------------------------------------------------------
all() -> 
    [erpc_connect_test,
     erpc_call_test,
     erpc_cast_test,
     erpc_multicall_test,
     erpc_multicast_test,
     erpc_disconnect_test,
     erpc_reconnect_test].

%%--------------------------------------------------------------------
%% @spec TestCase(Config0) ->
%%               ok | exit() | {skip,Reason} | {comment,Comment} |
%%               {save_config,Config1} | {skip_and_save,Reason,Config1}
%% Config0 = Config1 = [tuple()]
%% Reason = term()
%% Comment = term()
%% @end
%%--------------------------------------------------------------------
erpc_connect_test(_Config) ->
    Outgoing_conn_status = erpc:outgoing_conns(),
    %% ct:pal("Outgoing_conn_status: ~p~n", [Outgoing_conn_status]),
    lists:foreach(
      fun(X) ->
              ?assertEqual(true, lists:member(X, Outgoing_conn_status))
      end, [?TEST_NODE_1, ?TEST_NODE_2, node()]).

erpc_call_test(_Config) ->
    ?assertEqual(?TEST_NODE_1, erpc:call(?TEST_NODE_1, erlang, node, [])),
    ?assertEqual(?TEST_NODE_2, erpc:call(?TEST_NODE_2, erlang, node, [])).

erpc_multicall_test(_Config) ->
    ?assertEqual({[?TEST_NODE_1, ?TEST_NODE_2], []},
                 erpc:multicall([?TEST_NODE_1, ?TEST_NODE_2], erlang, node, [])),
    ?assertEqual({[?TEST_NODE_2, ?TEST_NODE_1], []}, 
                 erpc:multicall([?TEST_NODE_2, ?TEST_NODE_1], erlang, node, [])).

erpc_cast_test(_Config) ->
    Tab = erpc_cast_test_ets,
    ets:new(Tab, [named_table, public]),
    ok = erpc:cast(?SELF_CONN, ?MODULE, cast_callback, []),
    timer:sleep(500),
    ?assertEqual(cast_callback_data(), ets:tab2list(Tab)).

cast_callback() ->
    ets:insert(erpc_cast_test_ets, cast_callback_data()).

cast_callback_data() ->
    [{answer, 42}].

erpc_multicast_test(_Config) ->
    Tab = erpc_multicast_test_ets,
    ets:new(Tab, [named_table, public, bag]),
    ok = erpc:multicast([?SELF_CONN, ?SELF_CONN_2], ?MODULE, multicast_callback, [Tab]),
    timer:sleep(500),
    [{Key1, _}, {Key2, _}] = ets:tab2list(Tab),
    ?assertEqual([a,a], [Key1,Key2]).

multicast_callback(Tab) ->
    ets:insert(Tab, {a, erlang:unique_integer([])}).

erpc_disconnect_test(_Config) ->
    ok = erpc:disconnect(?TEST_NODE_1),
    ?assertEqual({badrpc, not_connected}, erpc:call(?TEST_NODE_1, erlang, node, [])),
    ?assertEqual(?TEST_NODE_2, erpc:call(?TEST_NODE_2, erlang, node, [])),
    ?assertEqual({badrpc, not_connected}, erpc:cast(?TEST_NODE_1, erlang, node, [])),
    ?assertEqual({[?TEST_NODE_2], [?TEST_NODE_1]},
                 erpc:multicall([?TEST_NODE_2, ?TEST_NODE_1], erlang, node, [])).

erpc_reconnect_test(_Config) ->
    ok = erpc:connect(?TEST_NODE_1, [{hosts, [{"localhost", 9091}]}]),
    timer:sleep(1000),
    erpc_connect_test(_Config),
    erpc_call_test(_Config),
    erpc_cast_test(_Config).

configure_test_nodes() ->
    Node_1 = erpc_test_1@localhost,
    rpc:call(Node_1, application, stop, [erpc]),
    rpc:call(Node_1, application, load, [erpc]),
    rpc:call(Node_1, application, set_env, [erpc, server_config, 
                                            [{transport, tcp},
                                             {listen_port, 9091},
                                             {default_node_acl, allow}]]),
    rpc:call(Node_1, application, ensure_all_started, [erpc]),

    Node_2 = erpc_test_2@localhost,
    rpc:call(Node_2, application, stop, [erpc]),
    rpc:call(Node_2, application, load, [erpc]),
    rpc:call(Node_2, application, set_env, [erpc, server_config, 
                                            [{transport, tcp},
                                             {listen_port, 9092},
                                             {default_node_acl, allow}]]),
    rpc:call(Node_2, application, ensure_all_started, [erpc]).
