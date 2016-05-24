-module(erpc_test_callback).
-compile(export_all).

create_block_call_ets() ->
    timer:sleep(2000),
    block_call_test = ets:new(block_call_test, [named_table, public]),
    Pid = spawn(
            fun() ->
                    infinite_loop()
            end),
    true = ets:give_away(block_call_test, Pid, undefined).

create_abcast_ets() ->    
    abcast_test = ets:new(abcast_test, [named_table, public]),
    Pid = spawn(
            fun() ->
                    register(abcast_server, self()),
                    abcast_server()
            end),
    true = ets:give_away(abcast_test, Pid, undefined).

insert_into_abcast_ets(Terms) ->
    ets:insert(abcast_test, Terms).

list_abcast_ets() ->
    ets:tab2list(abcast_test).

infinite_loop() ->
    receive
        _ ->
            infinite_loop()
    end.

abcast_server() ->
    receive
        {insert_into_abcast_ets, Terms} ->
            insert_into_abcast_ets(Terms)
    end,
    abcast_server().

%%------------------------            
create_sbcast_ets() ->    
    sbcast_test = ets:new(sbcast_test, [named_table, public]),
    Pid = spawn(
            fun() ->
                    register(sbcast_server, self()),
                    sbcast_server()
            end),
    true = ets:give_away(sbcast_test, Pid, undefined).

insert_into_sbcast_ets(Terms) ->
    ets:insert(sbcast_test, Terms).

list_sbcast_ets() ->
    sbcast_server ! {read_entries, self()},
    receive
        {result, Terms} ->
            Terms
    end.

sbcast_server() ->
    receive
        {insert_into_sbcast_ets, Terms} ->
            insert_into_sbcast_ets(Terms);
        {read_entries, From} ->
            From ! {result, ets:tab2list(sbcast_test)}
    end,
    sbcast_server().

            
