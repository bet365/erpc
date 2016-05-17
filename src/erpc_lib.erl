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

-module(erpc_lib).
-export([
         log_msg/2
        ]).

log_msg(Fmt, Args) ->
    case application:get_env(erpc, logger_mf) of
        {ok, {Mod, Fun}} when is_atom(Mod), is_atom(Fun) ->
            catch apply(Mod, Fun, ["~1000.p -- " ++ Fmt, [calendar:local_time() | Args]]);
        _ ->
            ok
    end,
    ok.
