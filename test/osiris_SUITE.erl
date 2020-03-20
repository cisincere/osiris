-module(osiris_SUITE).

-compile(export_all).

-export([
         ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [
     {group, tests}
    ].


all_tests() ->
    [
     single_node_write,
     cluster_write,
     cluster_batch_write,
     read_validate_single_node,
     read_validate,
     single_node_offset_listener,
     cluster_offset_listener,
     cluster_restart,
     cluster_delete
    ].

-define(BIN_SIZE, 800).

groups() ->
    [
     {tests, [], all_tests()}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    PrivDir = ?config(priv_dir, Config),
    Dir = filename:join(PrivDir, TestCase),
    application:load(osiris),
    application:set_env(osiris, data_dir, Dir),
    {ok, Apps} = application:ensure_all_started(osiris),
    % file:make_dir(Dir),
    [{data_dir, Dir},
     {test_case, TestCase},
     {cluster_name, atom_to_list(TestCase)},
     {started_apps, Apps} | Config].

end_per_testcase(_TestCase, Config) ->
    [application:stop(App) || App <- lists:reverse(?config(started_apps, Config))],
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

single_node_write(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => node(),
              replica_nodes => [],
              dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, [42]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,
    ok.

cluster_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_slave(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => LeaderNode,
              replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, 42, <<"mah-data">>),
    receive
        {osiris_written, _, [42]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,
    Self = self(),
    _ = spawn_link(LeaderNode,
                   fun () ->
                           {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, undefined}),
                           {[{0, <<"mah-data">>}], _Log} = osiris_log:read_chunk_parsed(Log0),
                           Self ! read_data_ok
                   end),
    receive
        read_data_ok -> ok
    after 2000 ->
              exit(read_data_ok_timeout)
    end,
    [slave:stop(N) || N <- Nodes],
    ok.

cluster_batch_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_slave(N, PrivDir)
                                       || N <- [s1, s2, s3]],
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => LeaderNode,
              replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    Batch = {batch, 1, 0, <<0:1, 8:31/unsigned, "mah-data">>},
    ok = osiris:write(Leader, 42, Batch),
    receive
        {osiris_written, _, [42]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,
    Self = self(),
    _ = spawn(LeaderNode,
              fun () ->
                      {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, undefined}),
                      {[{0, <<"mah-data">>}], _Log} = osiris_log:read_chunk_parsed(Log0),
                      Self ! read_data_ok
              end),
    receive
        read_data_ok -> ok
    after 2000 ->
              exit(read_data_ok_timeout)
    end,
    [slave:stop(N) || N <- Nodes],
    ok.

single_node_offset_listener(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => node(),
              replica_nodes => []},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {error, {offset_out_of_range, empty}} =
        osiris_writer:init_offset_reader(Leader, {abs, 0}),
    osiris_writer:register_offset_listener(Leader, 0),
    ok = osiris:write(Leader, 42, <<"mah-data">>),
    receive
        {osiris_offset, _Name, 0} ->
            {ok, Log0} = osiris_writer:init_offset_reader(Leader, {abs, 0}),
            {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
            {end_of_stream, _} = osiris_log:read_chunk_parsed(Log),
            ok
    after 2000 ->
              flush(),
              exit(osiris_offset_timeout)
    end,
    flush(),
    ok.

cluster_offset_listener(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [_ | Replicas] = Nodes = [start_slave(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => node(),
              replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {ok, Log0} = osiris_writer:init_offset_reader(Leader, 0),
    osiris_writer:register_offset_listener(Leader, 0),
    ok = osiris:write(Leader, 42, <<"mah-data">>),
    receive
        {osiris_offset, _Name, O} when O > -1 ->
            ct:pal("got offset ~w", [O]),
            {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
            slave:stop(hd(Replicas)),
            ok = osiris:write(Leader, 43, <<"mah-data2">>),
            timer:sleep(10),
            {end_of_stream, _} = osiris_log:read_chunk_parsed(Log),
            ok
    after 2000 ->
              flush(),
              exit(osiris_offset_timeout)
    end,
    [slave:stop(N) || N <- Nodes],
    ok.

read_validate_single_node(Config) ->
    _PrivDir = ?config(data_dir, Config),
    Num = 100000,
    Name = ?config(cluster_name, Config),
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => node(),
              replica_nodes => []},
    {ok, #{leader_pid := Leader,
           replica_pids := []}} = osiris:start_cluster(Conf0),
    timer:sleep(500),
    % start_profile(Config, [osiris_writer, gen_batch_server,
    %                        osiris_log, lists, file]),
    write_n(Leader, Num, #{}),
    % stop_profile(Config),
    {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, undefined}),

    {Time, _} = timer:tc(fun() -> validate_read(Num, Log0) end),
    MsgSec = Num / ((Time / 1000) / 1000),
    ct:pal("validate read of ~b entries took ~wms ~w msg/s", [Num, Time div 1000, MsgSec]),
    ok.


read_validate(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Num = 1000000,
    [_LNode | Replicas] = Nodes =  [start_slave(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => node(),
              replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {_, GarbBefore} = erlang:process_info(Leader, garbage_collection),
    {_, MemBefore} = erlang:process_info(Leader, memory),
    {_, BinBefore} = erlang:process_info(Leader, binary),
    timer:sleep(500),
    {Time, _} = timer:tc(fun () ->
                                 Self = self(),
                                 spawn(fun () ->
                                               write_n(Leader, Num div 2, #{}),
                                               Self ! done
                                       end),
                                 write_n(Leader, Num div 2, #{}),
                                 receive
                                     done -> ok
                                 after 1000 * 60 ->
                                           exit(blah)
                                 end
                         end),
    {_, BinAfter} = erlang:process_info(Leader, binary),
    {_, GarbAfter} = erlang:process_info(Leader, garbage_collection),
    {_, MemAfter} = erlang:process_info(Leader, memory),
    {reductions, _RedsAfter} = erlang:process_info(Leader, reductions),

    ct:pal("Binary:~n~w~n~w~n", [length(BinBefore), length(BinAfter)]),
    ct:pal("Garbage:~n~w~n~w~n", [GarbBefore, GarbAfter]),
    ct:pal("Memory:~n~w~n~w~n", [MemBefore, MemAfter]),
    MsgSec = Num / (Time / 1000 / 1000),
    ct:pal("~b writes took ~wms ~w msg/s",
           [Num, trunc(Time div 1000), trunc(MsgSec)]),
    ct:pal("~w counters ~p", [node(), osiris_counters:overview()]),
    [begin
         ct:pal("~w counters ~p", [N, rpc:call(N, osiris_counters, overview, [])])
     end || N <- Nodes],
    {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, undefined}),
    {_, _} = timer:tc(fun() -> validate_read(Num, Log0) end),

    [slave:stop(N) || N <- Nodes],
    ok.

cluster_restart(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_slave(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 = #{name => Name,
              epoch => 1,
              replica_nodes => Replicas,
              leader_node => LeaderNode},
    {ok, #{leader_pid := Leader} = Conf} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, 42, <<"before-restart">>),
    receive
        {osiris_written, _, [42]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,

    osiris:stop_cluster(Conf),

    {ok, Leader1} = rpc:call(LeaderNode, osiris, restart_server, [Conf]),
    [{ok, _Replica} = rpc:call(LeaderNode, osiris, restart_replica,
                              [Replica, Conf#{leader_pid => Leader1}])
     || Replica <- Replicas],

    ok = osiris:write(Leader1, 43, <<"after-restart">>),
    receive
        {osiris_written, _, [43]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,

    Self = self(),
    _ = spawn(LeaderNode,
              fun () ->
                      {ok, Log0} = osiris_writer:init_data_reader(Leader1, {0, undefined}),
                      {[{0, <<"before-restart">>}], Log1} = osiris_log:read_chunk_parsed(Log0),
                      {[{1, <<"after-restart">>}], _Log2} = osiris_log:read_chunk_parsed(Log1),
                      Self ! read_data_ok
              end),
    receive
        read_data_ok -> ok
    after 2000 ->
              exit(read_data_ok_timeout)
    end,
    [slave:stop(N) || N <- Nodes],
    ok.

cluster_delete(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_slave(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 = #{name => Name,
              epoch => 1,
              leader_node => LeaderNode,
              replica_nodes => Replicas},
    {ok, #{leader_pid := Leader} = Conf} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, 42, <<"before-restart">>),
    receive
        {osiris_written, _, [42]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,

    osiris:delete_cluster(Conf),
    [slave:stop(N) || N <- Nodes],
    ok.

%% Utility

write_n(Pid, N, Written) ->
    write_n(Pid, N, 0, Written).

write_n(_Pid, N, N, Written) ->
    %% wait for all written events;
    wait_for_written(Written),
    ok;
write_n(Pid, N, Next, Written) ->
    ok = osiris:write(Pid, Next, <<Next:?BIN_SIZE/integer>>),
    write_n(Pid, N, Next + 1, Written#{Next => ok}).

wait_for_written(Written0) ->
    receive
        {osiris_written, _Name, Corrs} ->
            Written = maps:without(Corrs, Written0),
            % ct:pal("written ~w", [length(Corrs)]),
            case maps:size(Written) of
                0 ->
                    ok;
                _ ->
                    wait_for_written(Written)
            end
    after 1000 * 60 ->
              flush(),
              exit(osiris_written_timeout)
    end.


validate_read(N, Log) ->
    validate_read(N, 0, Log).

validate_read(N, N, Log0) ->
    {end_of_stream, _Log} = osiris_log:read_chunk_parsed(Log0),
    ok;
validate_read(Max, Next, Log0) ->
    {[{Offs, _} | _] = Recs, Log} = osiris_log:read_chunk_parsed(Log0),
    case Offs == Next of
        false ->
            ct:fail("validate_read failed Offs ~b not eqial to ~b",
                    [Offs, Next]);
        true ->
            validate_read(Max, Next + length(Recs), Log)
    end.

start_slave(N, PrivDir) ->
    Dir0 = filename:join(PrivDir, N),
    Host = get_current_host(),
    Dir = "'\"" ++ Dir0 ++ "\"'",
    Pa = string:join(["-pa" | search_paths()] ++ ["-osiris data_dir", Dir], " "),
    ct:pal("starting slave node with ~s~n", [Pa]),
    {ok, S} = slave:start_link(Host, N, Pa),
    ct:pal("started slave node ~w ~w~n", [S, Host]),
    Res = rpc:call(S, application, ensure_all_started, [osiris]),
    ct:pal("application start result ~p", [Res]),
    S.

flush() ->
    receive
        Any ->
            ct:pal("flush ~p", [Any]),
            flush()
    after 0 ->
              ok
    end.

get_current_host() ->
    {ok, H} = inet:gethostname(),
    list_to_atom(H).

make_node_name(N) ->
    {ok, H} = inet:gethostname(),
    list_to_atom(lists:flatten(io_lib:format("~s@~s", [N, H]))).

search_paths() ->
    Ld = code:lib_dir(),
    lists:filter(fun (P) -> string:prefix(P, Ld) =:= nomatch end,
                 code:get_path()).

start_profile(Config, Modules) ->
    Dir = ?config(priv_dir, Config),
    Case = ?config(test_case, Config),
    GzFile = filename:join([Dir, "lg_" ++ atom_to_list(Case) ++ ".gz"]),
    ct:pal("Profiling to ~p~n", [GzFile]),

    lg:trace(Modules, lg_file_tracer,
             GzFile, #{running => false, mode => profile}).

stop_profile(Config) ->
    Case = ?config(test_case, Config),
    ct:pal("Stopping profiling for ~p~n", [Case]),
    lg:stop(),
    Dir = ?config(priv_dir, Config),
    Name = filename:join([Dir, "lg_" ++ atom_to_list(Case)]),
    lg_callgrind:profile_many(Name ++ ".gz.*", Name ++ ".out",#{}),
    ok.

