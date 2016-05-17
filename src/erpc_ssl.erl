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

-module(erpc_ssl).
-export([
         listen/2,
         accept/1,
         connect/1,
         send/2,
         setopts/2,
         host/1,
         close/1
        ]).

-record(erpc_ssl_socket, {socket, host, port}).

listen(Port, Conn_config) ->
    Socket_options = [{active, once},
                      binary,
                      {packet, 4},
                      {reuseaddr, true}],
    SSL_options    = proplists:get_value(ssl_options, Conn_config, []),
    Options        = Socket_options ++ SSL_options,
    ssl:listen(Port, Options).

accept(Listen_socket) ->
    case ssl:transport_accept(Listen_socket) of
        {ok, Ssl_socket} ->
            case ssl:ssl_accept(Ssl_socket) of
                ok ->
                    {ok, {Peer_host, Peer_port}} = ssl:peername(Ssl_socket),
                    {ok, #erpc_ssl_socket{socket = Ssl_socket,
                                          host   = Peer_host,
                                          port   = Peer_port}};
                Err ->
                    Err
            end;
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
    SSL_options    = proplists:get_value(ssl_options, Conn_config, []),
    Socket_options = [{active, once}, binary, {packet, 4}],
    Conn_options   = Socket_options ++ SSL_options,
    case ssl:connect(Host, Port, Conn_options, 5000) of
        {ok, Socket} ->
            {ok, #erpc_ssl_socket{host = Host, port = Port, socket = Socket}};
        Err ->
            Err
    end.

send(#erpc_ssl_socket{socket = Socket} = _Conn_handle, Data) ->
    ssl:send(Socket, Data).

close(#erpc_ssl_socket{socket = Socket}) ->
    catch ssl:close(Socket).

setopts(#erpc_ssl_socket{socket = Socket}, Opts) ->
    ssl:setopts(Socket, Opts).

host(#erpc_ssl_socket{host = Host}) ->
    Host.
