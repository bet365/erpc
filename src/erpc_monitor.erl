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

-module(erpc_monitor).

-behaviour(gen_server).

%% API
-export([
         start_link/0,
         broadcast_conn_down/1,
         broadcast_conn_up/1,
         broadcast_node_down/1,
         broadcast_node_up/1,
         demonitor_connection/2,
         demonitor_node/2,
         monitor_connection/2,
         monitor_node/2
        ]).

%% gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-define(SERVER,  ?MODULE).
-define(ETS_TAB, erpc_monitors).

-record(state, {node_up_list = [], node_down_list = [],
                conn_up_list = [], conn_down_list = []}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

monitor_node(Node_name, Calling_pid) ->
    call({monitor_node, Node_name, Calling_pid}).

monitor_connection(Conn_name, Calling_pid) ->
    call({monitor_conn, Conn_name, Calling_pid}).

demonitor_node(Node_name, Calling_pid) ->
    call({demonitor_node, Node_name, Calling_pid}).

demonitor_connection(Conn_name, Calling_pid) ->
    call({demonitor_conn, Conn_name, Calling_pid}).

broadcast_conn_up(Name) ->
    broadcast({erpc_conn_up, Name}, {conn, Name}).

broadcast_conn_down(Name) ->
    broadcast({erpc_conn_down, Name}, {conn, Name}).

broadcast_node_up(Node) ->
    broadcast({erpc_node_up, Node}, {node, Node}).

broadcast_node_down(Node) ->
    broadcast({erpc_node_down, Node}, {node, Node}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    _ = ets:new(?ETS_TAB, [named_table, protected, bag]),
    {ok, #state{}}.

handle_call({monitor_node, Node_name, Calling_pid}, _From, State) ->
    case ets:lookup(?ETS_TAB, Calling_pid) of
        [] ->
            Mref = erlang:monitor(process, Calling_pid),
            ets:insert(?ETS_TAB, {{mref, Calling_pid}, Mref});
        _ ->
            ok
    end,
    ets:insert(?ETS_TAB, {Calling_pid, {node, Node_name}}),
    {reply, ok, State};

handle_call({monitor_conn, Conn_name, Calling_pid}, _From, State) ->
    case ets:lookup(?ETS_TAB, Calling_pid) of
        [] ->
            Mref = erlang:monitor(process, Calling_pid),
            ets:insert(?ETS_TAB, {{mref, Calling_pid}, Mref});
        _ ->
            ok
    end,
    ets:insert(?ETS_TAB, {Calling_pid, {conn, Conn_name}}),
    {reply, ok, State};

handle_call({demonitor_node, Node_name, Calling_pid}, _From, State) ->
    ets:delete_object(?ETS_TAB, {Calling_pid, {node, Node_name}}),
    case ets:lookup(?ETS_TAB, Calling_pid) of
        [] ->
            [{_, Mref}] = ets:lookup(?ETS_TAB, {mref, Calling_pid}),
            catch erlang:demonitor(Mref, [flush]);
        _ ->
            ok
    end,
    {reply, ok, State};

handle_call({demonitor_conn, Node_name, Calling_pid}, _From, State) ->
    ets:delete_object(?ETS_TAB, {Calling_pid, {conn, Node_name}}),
    case ets:lookup(?ETS_TAB, Calling_pid) of
        [] ->
            [{_, Mref}] = ets:lookup(?ETS_TAB, {mref, Calling_pid}),
            catch erlang:demonitor(Mref, [flush]);
        _ ->
            ok
    end,
    {reply, ok, State};

handle_call({erpc_node_up, Node}, _From, #state{node_up_list   = Up_list,
                                                node_down_list = Down_list} = State) ->
    {Reply, Up_list_1} = should_broadcast(Node, Up_list),
    {reply, Reply, State#state{node_up_list   = Up_list_1,
                               node_down_list = Down_list -- [Node]}};

handle_call({erpc_node_down, Node}, _From, #state{node_up_list   = Up_list,
                                                  node_down_list = Down_list} = State) ->
    {Reply, Down_list_1} = should_broadcast(Node, Down_list),
    {reply, Reply, State#state{node_down_list   = Down_list_1,
                               node_up_list     = Up_list -- [Node]}};


handle_call({erpc_conn_up, Conn}, _From, #state{conn_up_list   = Up_list,
                                                conn_down_list = Down_list} = State) ->
    {Reply, Up_list_1} = should_broadcast(Conn, Up_list),
    {reply, Reply, State#state{conn_up_list   = Up_list_1,
                               conn_down_list = Down_list -- [Conn]}};

handle_call({erpc_conn_down, Conn}, _From, #state{conn_up_list   = Up_list,
                                                  conn_down_list = Down_list} = State) ->
    {Reply, Down_list_1} = should_broadcast(Conn, Down_list),
    {reply, Reply, State#state{conn_down_list   = Down_list_1,
                               conn_up_list     = Up_list -- [Conn]}};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, process, Pid, _Info}, State) ->
    ets:delete(?ETS_TAB, Pid),
    ets:delete(?ETS_TAB, {mref, Pid}),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
call(Msg) ->
    gen_server:call(?SERVER, Msg).

broadcast(Msg, Search_key) ->
    case call(Msg) of
        broadcast ->
            Pids = ets:select(?ETS_TAB, [{{'$1', Search_key}, [], ['$1']}]),
            lists:foreach(fun(X) ->
                                  catch X ! Msg
                          end, Pids);
        dont_broadcast ->
            ok
    end.

should_broadcast(Entry, List) ->
    case lists:member(Entry, List) of
        true ->
            {dont_broadcast, List};
        false ->
            {broadcast, [Entry | List]}
    end.
