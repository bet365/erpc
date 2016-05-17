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

-module(erpc_tcp).
-export([
         listen/2,
         accept/1,
         connect/1,
         send/2,
         setopts/2,
         host/1,
         close/1
        ]).

-record(erpc_tcp_socket, {socket, host, port}).

listen(Port, _Conn_config) ->
    Options = [{active, once},
               binary,
               {packet, 4},
               {reuseaddr, true}],
    gen_tcp:listen(Port, Options).

accept(Listen_socket) ->
    case gen_tcp:accept(Listen_socket) of
        {ok, Socket} ->
            {ok, {Peer_host, Peer_port}} = inet:peername(Socket),
            {ok, #erpc_tcp_socket{socket = Socket,
                                  host   = Peer_host,
                                  port   = Peer_port}};
        Err ->
            Err
    end.

connect(Conn_config) ->
    {Host, Port}   = case proplists:get_value(host, Conn_config) of
                         {Host_1, Port_1} when is_integer(Port_1) ->
                             {Host_1, Port_1};
                         Host_1 ->
                             {Host_1, 9090}
                     end,
    Socket_options = [{active, once}, binary, {packet, 4}],
    case gen_tcp:connect(Host, Port, Socket_options) of
        {ok, Socket} ->
            {ok, #erpc_tcp_socket{host = Host, port = Port, socket = Socket}};
        Err ->
            Err
    end.

send(#erpc_tcp_socket{socket = Socket} = _Conn_handle, Data) ->
    gen_tcp:send(Socket, Data).

close(#erpc_tcp_socket{socket = Socket}) ->
    catch gen_tcp:close(Socket).

setopts(#erpc_tcp_socket{socket = Socket}, Opts) ->
    inet:setopts(Socket, Opts).

host(#erpc_tcp_socket{host = Host}) ->
    Host.
