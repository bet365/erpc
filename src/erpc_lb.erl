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

-module(erpc_lb).

-behaviour(gen_server).

-export([
         %% API
         start_link/1,
         conn_status/0,
         is_connection_up/1,
         connected/3,
         disconnected/1,
         get_conn_pid/1,

         %% gen_server callbacks
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).


-record(state, {conn_name, node_config, workers}).

-record(erpc_lb, {name, num_conns = 0, conns = []}).

%%%===================================================================
%%% API
%%%===================================================================

start_link({Name, _} = Node) ->
    gen_server:start_link({local, Name}, ?MODULE, [Node], []).

connected(Name, TMod, Conn_handle) ->
    safe_call(Name, {connected, {self(), TMod, Conn_handle}}).

disconnected(Name) ->
    safe_call(Name, {disconnected, self()}).

is_connection_up(Name) ->
    case ets:lookup(erpc_lb, Name) of
        [#erpc_lb{num_conns = Num_conns}] when Num_conns > 0 ->
            true;
        _ ->
            false
    end.

conn_status() ->
    lists:map(fun(#erpc_lb{name = X_name}) ->
                      {X_name, is_connection_up(X_name)}
              end, ets:tab2list(erpc_lb)).

get_conn_pid(Name) ->
    case ets:lookup(erpc_lb, Name) of
        [#erpc_lb{conns = [Conn]}] ->
            {ok, Conn};
        [#erpc_lb{num_conns = Num_conns, conns = Conns}] when Num_conns > 0 ->
            N = generate_rand_int(Num_conns),
            {ok, lists:nth(N, Conns)};
        _ ->
            {badrpc, not_connected}
    end.

generate_rand_int(Range) ->
    {_, _, Int} = os:timestamp(),
    generate_rand_int(Range, Int).

generate_rand_int(Range, Int) ->
    (Int rem Range) + 1.

safe_call(Name, Args) ->
    case catch gen_server:call(Name, Args) of
        {'EXIT', {noproc, _}} ->
            {error, not_connected};
        Res ->
            Res
    end.
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([{Conn_name, Node_config}]) ->
    true = ets:insert(erpc_lb, #erpc_lb{name = Conn_name}),
    {ok, #state{conn_name   = Conn_name,
                node_config = Node_config,
                workers     = queue:new()
               }}.

handle_call({connected, Item}, _From,
            #state{workers   = Worker_q,
                   conn_name = Name} = State) ->
    Lb_rec = case ets:lookup(erpc_lb, Name) of
                 [] ->
                     erpc_monitor:broadcast_conn_up(Name),
                     #erpc_lb{name = Name, num_conns = 1, conns = [Item]};
                 [#erpc_lb{num_conns = Num_conns_old,
                           conns     = Conns_old} = Lb_rec_old] ->
                     Lb_rec_old#erpc_lb{num_conns = Num_conns_old + 1,
                                        conns     = Conns_old ++ [Item]}
             end,
    true = ets:insert(erpc_lb, Lb_rec),
    {reply, ok, State#state{workers = queue:in(Item, Worker_q)}};

handle_call({disconnected, Pid}, _From, #state{conn_name = Name} = State) ->
    case ets:lookup(erpc_lb, Name) of
        [] ->
            ok;
        [#erpc_lb{num_conns = Num_conns_old,
                  conns     = Conns_old} = Lb_rec_old] ->
            case lists:filter(
                   fun({X_pid, _, _}) ->
                           not (X_pid =:= Pid)
                   end, Conns_old) of
                Conns_old ->
                    ok;
                [] ->
                    ets:delete(erpc_lb, Name),
                    erpc_monitor:broadcast_conn_down(Name);
                Conns_old_1 ->
                    ets:insert(erpc_lb, Lb_rec_old#erpc_lb{num_conns = Num_conns_old - 1,
                                                           conns     = Conns_old_1})
            end
    end,
    {reply, ok, State};

handle_call(get_conn_pid, _From, #state{workers = Worker_q} = State) ->
    case queue:out(Worker_q) of
        {empty, _} ->
            {reply, not_connected, State};
        {{value, Item}, Worker_q_1} ->
            {reply, {ok, Item}, State#state{workers = queue:in(Item, Worker_q_1)}}
    end;

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
