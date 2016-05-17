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

-module(erpc_sup).
-behaviour(supervisor).

-export([start_link/0, connect/1, connect/2, disconnect/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    _ = ets:new(erpc_incoming_conns, [named_table, public]),
    _ = ets:new(erpc_outgoing_conns, [named_table, public]),
    _ = ets:new(erpc_lb,             [named_table, public,
                                      {read_concurrency, true},
                                      {keypos, 2}]),
    Client_config  = application:get_env(erpc, client_config, []),
    Client_specs   = client_child_specs(Client_config),
    Server_spec    = erpc_server_spec(),
    {ok, {{one_for_one, 1, 5}, [Server_spec | Client_specs]}}.

client_child_specs(Client_config) ->
    lists:flatten
      (
      lists:map
        (
        fun({Conn_name, Conn_options}) when is_atom(Conn_name),
                                            is_list(Conn_options) ->
                client_child_specs(Conn_name, Conn_options);
           (Conn_name) when is_atom(Conn_name) ->
                [_, Host] = string:tokens(atom_to_list(Conn_name), "@"),
                client_child_specs(Conn_name, [{hosts, [{Host, 9090}]}])
        end, Client_config
       )
     ).

erpc_server_spec() ->
    Restart  = permanent,
    Shutdown = 2000,
    Type     = worker,
    {'erpc_server',
     {'erpc_server', start_link, []},
     Restart, Shutdown, Type, ['erpc_server']}.

connect(Conn_name) when is_atom(Conn_name) ->
    [_, Host] = string:tokens(atom_to_list(Conn_name), "@"),
    connect(Conn_name, [{hosts, [{Host, 9090}]}]).

connect(Conn_name, Conn_options) ->
    [Lb_spec | Child_specs] = client_child_specs(Conn_name, Conn_options),
    case supervisor:start_child(?MODULE, Lb_spec) of
        {error, already_present} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {ok, _} ->
            lists:foreach(fun(X) ->
                                  supervisor:start_child(?MODULE, X)
                          end, Child_specs)
    end.

disconnect(Conn_name) ->
    Children = supervisor:which_children(?MODULE),
    lists:foreach(
      fun({{'erpc_client', X_conn_name, _, _} = X_id, _, _, _}) when X_conn_name == Conn_name ->
              _ = supervisor:terminate_child(?MODULE, X_id),
              _ = supervisor:delete_child(?MODULE, X_id);
         (_) ->
              ok
      end, Children),
    lists:foreach(
      fun({{'erpc_lb', X_conn_name} = X_id, _, _, _})  when X_conn_name == Conn_name ->
              _ = supervisor:terminate_child(?MODULE, X_id),
              _ = supervisor:delete_child(?MODULE, X_id);
         (_) ->
              ok
      end, Children),
    ok.

client_child_specs(Conn_name, Conn_options) ->
    Restart  = permanent,
    Shutdown = 2000,
    Type     = worker,
    Lb_spec = {{'erpc_lb', Conn_name},
               {'erpc_lb', start_link, [{Conn_name, Conn_options}]},
               Restart, Shutdown, Type, ['erpc_lb']},
    Num_conns = proplists:get_value(num_connections, Conn_options, 1),
    Hosts     = proplists:get_value(hosts, Conn_options),
    case (Num_conns > 0) of
        true ->
            ok;
        false ->
            exit({invalid_config, {erpc, num_connections, Num_conns}})
    end,
    Client_specs = lists:map(
                     fun({X_host, X_port}) ->
                             Conn_options_1 = lists:keydelete(hosts, 1, Conn_options),
                             Conn_options_2 = [{host, {X_host, X_port}} | Conn_options_1],
                             lists:map(
                               fun(X_conn_num) ->
                                       {{'erpc_client', Conn_name, {X_host, X_port}, X_conn_num},
                                        {'erpc_client', start_link, [{Conn_name, Conn_options_2}]},
                                        Restart, Shutdown, Type, ['erpc_client']}
                               end, lists:seq(1, Num_conns));
                        (X_host) ->
                             Conn_options_1 = lists:keydelete(hosts, 1, Conn_options),
                             Conn_options_2 = [{host, X_host} | Conn_options_1],
                             lists:map(
                               fun(X_conn_num) ->
                                       {{'erpc_client', Conn_name, X_host, X_conn_num},
                                        {'erpc_client', start_link, [{Conn_name, Conn_options_2}]},
                                        Restart, Shutdown, Type, ['erpc_client']}
                               end, lists:seq(1, Num_conns))
                     end, Hosts),
    [Lb_spec | lists:flatten(Client_specs)].
