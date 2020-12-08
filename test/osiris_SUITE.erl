%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_SUITE).

-compile(export_all).

-export([]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [{group, tests}].

all_tests() ->
    [single_node_write,
     cluster_write,
     quorum_write,
     cluster_batch_write,
     read_validate_single_node,
     read_validate,
     single_node_offset_listener,
     single_node_offset_listener2,
     cluster_offset_listener,
     replica_offset_listener,
     cluster_restart,
     cluster_restart_new_leader,
     cluster_delete,
     cluster_failure,
     start_cluster_invalid_replicas,
     restart_replica,
     diverged_replica,
     retention,
     tracking,
     tracking_many,
     tracking_retention,
     single_node_deduplication,
     single_node_deduplication_2,
     cluster_minority_deduplication,
     cluster_deduplication,
     writers_retention].

-define(BIN_SIZE, 800).

groups() ->
    [{tests, [], all_tests()}].

init_per_suite(Config) ->
    osiris:configure_logger(logger),
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
    application:stop(osiris),
    application:load(osiris),
    application:set_env(osiris, data_dir, Dir),
    {ok, Apps} = application:ensure_all_started(osiris),
    ok = logger:set_primary_config(level, all),
    % file:make_dir(Dir),
    [{data_dir, Dir},
     {test_case, TestCase},
     {cluster_name, atom_to_list(TestCase)},
     {started_apps, Apps}
     | Config].

end_per_testcase(_TestCase, Config) ->
    [application:stop(App) || App <- lists:reverse(?config(started_apps, Config))],
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

single_node_write(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    Wid = <<"wid1">>,
    ?assertEqual(undefined, osiris:fetch_writer_seq(Leader, Wid)),
    ok = osiris:write(Leader, Wid, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    ?assertEqual(42, osiris:fetch_writer_seq(Leader, Wid)),
    ok.

cluster_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    WriterId = undefined,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, WriterId, 42, <<"mah-data">>),
    ok = osiris:write(Leader, WriterId, 43, <<"mah-data2">>),
    receive
        {osiris_written, _, undefined, [42, 43]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    ok = validate_log(Leader, [{0, <<"mah-data">>}, {1, <<"mah-data2">>}]),
    [slave:stop(N) || N <- Nodes],
    ok.

quorum_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    slave:stop(hd(Replicas)),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    ok = validate_log(Leader, [{0, <<"mah-data">>}]),
    [slave:stop(N) || N <- Nodes],
    ok.

cluster_batch_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := [ReplicaPid, ReplicaPid2]}} =
        osiris:start_cluster(Conf0),
    Batch = {batch, 1, 0, <<0:1, 8:31/unsigned, "mah-data">>},
    ok = osiris:write(Leader, undefined, 42, Batch),
    receive
        {osiris_written, _, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    ok = validate_log(Leader, [{0, <<"mah-data">>}]),
    timer:sleep(1000),
    ok = validate_log(ReplicaPid, [{0, <<"mah-data">>}]),
    ok = validate_log(ReplicaPid2, [{0, <<"mah-data">>}]),
    [slave:stop(N) || N <- Nodes],
    ok.

single_node_offset_listener(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => []},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {error, {offset_out_of_range, empty}} = osiris:init_reader(Leader, {abs, 0}),
    osiris:register_offset_listener(Leader, 0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_offset, _Name, 0} ->
            {ok, Log0} = osiris:init_reader(Leader, {abs, 0}),
            {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
            {end_of_stream, _} = osiris_log:read_chunk_parsed(Log),
            ok
    after 2000 ->
        flush(),
        exit(osiris_offset_timeout)
    end,
    flush(),
    ok.

single_node_offset_listener2(Config) ->
    %% writes before registering
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => []},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {ok, Log0} = osiris:init_reader(Leader, next),
    Next = osiris_log:next_offset(Log0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    wait_for_written([42]),
    osiris:register_offset_listener(Leader, Next),
    receive
        {osiris_offset, _Name, 0} ->
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
    [_ | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {ok, Log0} = osiris:init_reader(Leader, 0),
    osiris:register_offset_listener(Leader, 0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_offset, _Name, O} when O > -1 ->
            ct:pal("got offset ~w", [O]),
            {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
            %% stop all replicas
            [slave:stop(N) || N <- Replicas],
            ok = osiris:write(Leader, undefined, 43, <<"mah-data2">>),
            timer:sleep(10),
            {end_of_stream, _} = osiris_log:read_chunk_parsed(Log),
            ok
    after 2000 ->
        flush(),
        exit(osiris_offset_timeout)
    end,
    [slave:stop(N) || N <- Nodes],
    ok.

replica_offset_listener(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [_ | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := ReplicaPids}} = osiris:start_cluster(Conf0),
    Self = self(),
    R = hd(ReplicaPids),
    _ = spawn(node(R),
              fun() ->
                 {ok, Log0} = osiris:init_reader(R, 0),
                 osiris:register_offset_listener(R, 0),
                 receive
                     {osiris_offset, _Name, O} when O > -1 ->
                         ct:pal("got offset ~w", [O]),
                         {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
                         osiris_log:close(Log),
                         Self ! test_passed,
                         ok
                 after 2000 ->
                     flush(),
                     exit(osiris_offset_timeout)
                 end
              end),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),

    receive
        test_passed ->
            ok
    after 5000 ->
        flush(),
        [slave:stop(N) || N <- Nodes],
        exit(timeout)
    end,
    [slave:stop(N) || N <- Nodes],
    ok.

read_validate_single_node(Config) ->
    _PrivDir = ?config(data_dir, Config),
    Num = 10000,
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []}} = osiris:start_cluster(Conf0),
    timer:sleep(500),
    % start_profile(Config, [osiris_writer, gen_batch_server,
    %                        osiris_log, lists, file]),
    ct:pal("writing ~b", [Num]),
    write_n(Leader, Num, #{}),
    % stop_profile(Config),
    {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, empty}),

    ct:pal("~w counters ~p", [node(), osiris_counters:overview()]),

    ct:pal("validating....", []),
    {Time, _} = timer:tc(fun() -> validate_read(Num, Log0) end),
    MsgSec = Num / (Time / 1000 / 1000),
    ct:pal("validate read of ~b entries took ~wms ~w msg/s", [Num, Time div 1000, MsgSec]),
    ok.

read_validate(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    NumWriters = 2,
    Num = 1000000 * NumWriters,
    Replicas = [start_child_node(N, PrivDir) || N <- [r1, r2]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          retention => [{max_bytes, 1000000}],
          leader_node => node(),
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := ReplicaPids}} = osiris:start_cluster(Conf0),
    {_, GarbBefore} = erlang:process_info(Leader, garbage_collection),
    {_, MemBefore} = erlang:process_info(Leader, memory),
    {_, BinBefore} = erlang:process_info(Leader, binary),
    timer:sleep(500),
    {Time, _} =
        timer:tc(fun() ->
                    Self = self(),
                    N = Num div NumWriters,
                    [begin
                         spawn(fun() ->
                                  write_n(Leader, N div 2, #{}),
                                  Self ! done
                               end),
                         write_n(Leader, N div 2, #{}),
                         receive done -> ok after 1000 * 60 -> exit(blah) end
                     end
                     || _ <- lists:seq(1, NumWriters)]
                 end),
    {_, BinAfter} = erlang:process_info(Leader, binary),
    {_, GarbAfter} = erlang:process_info(Leader, garbage_collection),
    {_, MemAfter} = erlang:process_info(Leader, memory),
    {reductions, _RedsAfter} = erlang:process_info(Leader, reductions),

    ct:pal("Binary:~n~w~n~w~n", [length(BinBefore), length(BinAfter)]),
    ct:pal("Garbage:~n~w~n~w~n", [GarbBefore, GarbAfter]),
    ct:pal("Memory:~n~w~n~w~n", [MemBefore, MemAfter]),
    MsgSec = Num / (Time / 1000 / 1000),
    ct:pal("~b writes took ~wms ~w msg/s", [Num, trunc(Time div 1000), trunc(MsgSec)]),
    ct:pal("~w counters ~p", [node(), osiris_counters:overview()]),
    [begin ct:pal("~w counters ~p", [N, rpc:call(N, osiris_counters, overview, [])]) end
     || N <- Replicas],

    {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, empty}),
    {_, _} = timer:tc(fun() -> validate_read(Num, Log0) end),

    %% test reading on slave
    R = hd(ReplicaPids),
    Self = self(),
    _ = spawn(node(R),
              fun() ->
                 {ok, RLog0} = osiris_writer:init_data_reader(R, {0, empty}),
                 {_, _} = timer:tc(fun() -> validate_read(Num, RLog0) end),
                 Self ! validate_read_done
              end),
    receive
        validate_read_done ->
            ct:pal("all reads validated", []),
            ok
    after 30000 ->
        exit(validate_read_done_timeout)
    end,

    [slave:stop(N) || N <- Replicas],
    ok.

cluster_restart(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          replica_nodes => Replicas,
          leader_node => LeaderNode},
    {ok, #{leader_pid := Leader} = Conf} = osiris:start_cluster(Conf0),
    WriterId = <<"wid1">>,
    ok = osiris:write(Leader, WriterId, 42, <<"before-restart">>),
    receive
        {osiris_written, _, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    osiris:stop_cluster(Conf),
    {ok, #{leader_pid := Leader1}} = osiris:start_cluster(Conf0#{epoch => 2}),
    %% give leader some time to discover the committed offset
    timer:sleep(1000),
    ok = validate_log(Leader1, [{0, <<"before-restart">>}]),

    ok = osiris:write(Leader1, WriterId, 43, <<"after-restart">>),
    receive
        {osiris_written, _, WriterId, [43]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    ok = validate_log(Leader1, [{0, <<"before-restart">>}, {1, <<"after-restart">>}]),
    [slave:stop(N) || N <- Nodes],
    ok.

cluster_restart_new_leader(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          replica_nodes => Replicas,
          leader_node => LeaderNode},
    {ok, #{leader_pid := Leader} = Conf} = osiris:start_cluster(Conf0),
    WriterId = <<"wid1">>,
    ok = osiris:write(Leader, WriterId, 42, <<"before-restart">>),
    receive
        {osiris_written, _, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    osiris:stop_cluster(Conf),
    %% restart cluster with new
    [NewLeaderNode, Replica1] = Replicas,
    {ok, #{leader_pid := Leader1}} =
        osiris:start_cluster(Conf0#{epoch => 2,
                                    replica_nodes => [LeaderNode, Replica1],
                                    leader_node => NewLeaderNode}),
    %% give leader some time to discover the committed offset
    timer:sleep(1000),

    ok = validate_log(Leader1, [{0, <<"before-restart">>}]),

    ok = osiris:write(Leader1, WriterId, 43, <<"after-restart">>),
    receive
        {osiris_written, _, WriterId, [43]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    ok = validate_log(Leader1, [{0, <<"before-restart">>}, {1, <<"after-restart">>}]),
    [slave:stop(N) || N <- Nodes],
    ok.

cluster_delete(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader} = Conf} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"before-restart">>),
    receive
        {osiris_written, _, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    osiris:delete_cluster(Conf),
    [slave:stop(N) || N <- Nodes],
    ok.

cluster_failure(Config) ->
    %% when the leader exits the failure the replicas and replica readers
    %% should also exit
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := [R1, R2]} = _Conf} =
        osiris:start_cluster(Conf0),

    _PreRRs = supervisor:which_children({osiris_replica_reader_sup, node(Leader)}),
    %% stop the leader
    gen_batch_server:stop(Leader, bananas, 5000),

    R1Ref = monitor(process, R1),
    R2Ref = monitor(process, R2),
    receive
        {'DOWN', R1Ref, _, _, _} ->
            ok
    after 2000 ->
        flush(),
        exit(down_timeout_1)
    end,
    receive
        {'DOWN', R2Ref, _, _, _} ->
            ok
    after 2000 ->
        flush(),
        exit(down_timeout_2)
    end,
    [] = supervisor:which_children({osiris_replica_reader_sup, node(Leader)}),

    [slave:stop(N) || N <- Nodes],
    ok.

start_cluster_invalid_replicas(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [zen@rabbit],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := _Leader, replica_pids := []}} = osiris:start_cluster(Conf0).

restart_replica(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Nodes = [s1, s2, s3],
    [LeaderE1, Replica1, Replica2] = [start_child_node(N, PrivDir) || N <- Nodes],
    InitConf =
        #{name => Name,
          external_ref => Name,
          epoch => 1,
          leader_node => LeaderE1,
          replica_nodes => [Replica1, Replica2]},
    {ok, #{leader_pid := LeaderE1Pid, replica_pids := [R1Pid, _]} = Conf} =
        osiris:start_cluster(InitConf),
    %% write some records in e1
    Msgs = lists:seq(1, 1),
    [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>]) || N <- Msgs],
    wait_for_written(Msgs),
    timer:sleep(100),
    ok = rpc:call(node(R1Pid), gen_server, stop, [R1Pid]),
    [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>]) || N <- Msgs],
    wait_for_written(Msgs),
    {ok, _Replica1b} = osiris_replica:start(node(R1Pid), Conf),
    [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>]) || N <- Msgs],
    wait_for_written(Msgs),
    ok.

diverged_replica(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Nodes = [s1, s2, s3],
    [LeaderE1, LeaderE2, LeaderE3] = [start_child_node(N, PrivDir) || N <- Nodes],
    ConfE1 =
        #{name => Name,
          external_ref => Name,
          epoch => 1,
          leader_node => LeaderE1,
          replica_nodes => [LeaderE2, LeaderE3]},
    {ok, #{leader_pid := LeaderE1Pid}} = osiris:start_cluster(ConfE1),
    %% write some records in e1
    [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>]) || N <- lists:seq(1, 100)],
    wait_for_written(lists:seq(1, 100)),

    %% shut down cluster and start only LeaderE2 in epoch 2
    ok = osiris:stop_cluster(ConfE1),
    ConfE2 =
        ConfE1#{leader_node => LeaderE2,
                epoch => 2,
                replica_nodes => [LeaderE1, LeaderE2]},
    {ok, LeaderE2Pid} = osiris_writer:start(ConfE2),
    %% write some entries that won't be committedo
    [osiris:write(LeaderE2Pid, undefined, N, [<<N:64/integer>>]) || N <- lists:seq(101, 200)],
    %% we can't wait for osiris_written here
    timer:sleep(500),
    %% shut down LeaderE2
    ok = osiris_writer:stop(ConfE2),

    ConfE3 =
        ConfE1#{leader_node => LeaderE3,
                epoch => 3,
                replica_nodes => [LeaderE1, LeaderE2]},
    %% start the cluster in E3 with E3 as leader
    {ok, #{leader_pid := LeaderE3Pid}} = osiris:start_cluster(ConfE3),
    %% write some more in this epoch
    [osiris:write(LeaderE3Pid, undefined, N, [<<N:64/integer>>]) || N <- lists:seq(201, 300)],
    wait_for_written(lists:seq(201, 300)),
    timer:sleep(1000),

    print_counters(),
    ok = osiris:stop_cluster(ConfE3),

    %% validate replication etc takes place
    [Idx1, Idx2, Idx3] =
        [begin
             {ok, D} =
                 file:read_file(
                     filename:join([PrivDir, N, ?FUNCTION_NAME, "00000000000000000000.index"])),
             D
         end
         || N <- Nodes],
    ?assertEqual(Idx1, Idx2),
    ?assertEqual(Idx1, Idx3),

    [Seg1, Seg2, Seg3] =
        [begin
             {ok, D} =
                 file:read_file(
                     filename:join([PrivDir, N, ?FUNCTION_NAME, "00000000000000000000.segment"])),
             D
         end
         || N <- Nodes],
    ?assertEqual(Seg1, Seg2),
    ?assertEqual(Seg1, Seg3),
    ok.

retention(Config) ->
    _PrivDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_bytes, SegSize}],
          max_segment_size => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []}} = osiris:start_cluster(Conf0),
    timer:sleep(500),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    timer:sleep(1000),
    %% assert on num segs
    ok.

tracking(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    TrackId = <<"tracking-id-1">>,

    ?assertEqual(undefined, osiris:read_tracking(Leader, TrackId)),
    ok = osiris:write_tracking(Leader, TrackId, 0),
    %% need to sleep a little else we may try to write and read in the same
    %% batch which due to batch reversal isn't possible. This should be ok
    %% given the use case for reading tracking
    timer:sleep(100),
    ?assertEqual(0, osiris:read_tracking(Leader, TrackId)),
    ok = osiris:write_tracking(Leader, TrackId, 1),
    timer:sleep(100),
    ?assertEqual(1, osiris:read_tracking(Leader, TrackId)),

    ok.

tracking_many(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    TrackId = <<"tracking-id-1">>,
    ?assertEqual(undefined, osiris:read_tracking(Leader, TrackId)),
    ok = osiris:write_tracking(Leader, TrackId, 0),
    ok = osiris:write_tracking(Leader, TrackId, 1),
    ok = osiris:write_tracking(Leader, TrackId, 2),
    ok = osiris:write_tracking(Leader, TrackId, 3),
    timer:sleep(250),
    ?assertEqual(3, osiris:read_tracking(Leader, TrackId)),
    ok.

tracking_retention(Config) ->
    _PrivDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_bytes, SegSize}],
          max_segment_size => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []}} = osiris:start_cluster(Conf0),
    timer:sleep(500),
    TrkId = <<"trkid1">>,
    osiris:write_tracking(Leader, TrkId, 5),
    TrkId2 = <<"trkid2">>,
    osiris:write_tracking(Leader, TrkId2, Num),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    timer:sleep(1000),
    %% tracking id should be gone
    ?assertEqual(undefined, osiris:read_tracking(Leader, TrkId)),
    ?assertEqual(Num, osiris:read_tracking(Leader, TrkId2)),
    ok.

single_node_deduplication(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    WID = <<"wid1">>,
    ok = osiris:write(Leader, WID, 1, <<"data1">>),
    ok = osiris:write(Leader, WID, 1, <<"data1b">>),
    ok = osiris:write(Leader, WID, 2, <<"data2">>),
    wait_for_written([1, 2]),
    %% validate there are only a single entry
    validate_log(Leader, [{0, <<"data1">>}, {1, <<"data2">>}]),
    ok.

single_node_deduplication_2(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    WID = <<"wid1">>,
    ok = osiris:write(Leader, WID, 1, <<"data1">>),
    timer:sleep(50),
    ok = osiris:write(Leader, WID, 1, <<"data1b">>),
    ok = osiris:write(Leader, WID, 2, <<"data2">>),
    wait_for_written([1, 2]),
    %% data1b must not have been written
    ok = validate_log(Leader, [{0, <<"data1">>}, {1, <<"data2">>}]),

    ok.

cluster_minority_deduplication(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    WriterId = atom_to_binary(?FUNCTION_NAME, utf8),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    [slave:stop(N) || N <- Replicas],
    ok = osiris:write(Leader, WriterId, 42, <<"data1">>),
    ok = osiris:write(Leader, WriterId, 42, <<"data1b">>),
    timer:sleep(50),
    ok = osiris:write(Leader, WriterId, 43, <<"data2">>),
    %% the duplicate must not be confirmed until the prior write is
    receive
        {osiris_written, _, WriterId, _} ->
            ct:fail("unexpected osiris written event in minority")
    after 1000 ->
        ok
    end,
    ok = validate_log(Leader, [{0, <<"data1">>}, {1, <<"data2">>}]),
    [slave:stop(N) || N <- Nodes],
    ok.

cluster_deduplication(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = Nodes = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    WriterId = atom_to_binary(?FUNCTION_NAME, utf8),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, WriterId, 42, <<"mah-data">>),
    receive
        {osiris_written, _, WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout_1)
    end,
    ok = osiris:write(Leader, WriterId, 42, <<"mah-data-dupe">>),
    receive
        {osiris_written, _, WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout_2)
    end,
    ok = validate_log(Leader, [{0, <<"mah-data">>}]),
    [slave:stop(N) || N <- Nodes],
    ok.

writers_retention(Config) ->
    Name = ?config(cluster_name, Config),
    SegSize = 1000 * 10000,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          max_segment_size => SegSize,
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    %% perform writes from 255 unique writers
    Writes =
        [begin
             WID = integer_to_binary(I),
             ok = osiris:write(Leader, WID, I, <<I:64/integer>>),
             I
         end
         || I <- lists:seq(1, 500)],
    wait_for_written(Writes),

    %% then make sure another segment is created
    write_n(Leader, 20000, 0, 8 * 1000, #{}),

    %% validate there are a maximum of 255 active writers after the segment
    %% roll over
    Writers = osiris_writer:query_writers(Leader, fun(W) -> W end),

    ct:pal("Num writers ~w", [map_size(Writers)]),
    ?assert(map_size(Writers) < 256),

    %% validate there are only a single entry
    ok.

%% Utility

write_n(Pid, N, Written) ->
    write_n(Pid, N, 0, ?BIN_SIZE, Written).

write_n(_Pid, N, N, _BinSize, Written) ->
    %% wait for all written events;
    wait_for_written(Written),
    ok;
write_n(Pid, N, Next, BinSize, Written) ->
    ok = osiris:write(Pid, undefined, Next, <<Next:BinSize/integer>>),
    write_n(Pid, N, Next + 1, BinSize, Written#{Next => ok}).

wait_for_written(Written0) when is_list(Written0) ->
    ct:pal("wait_for_written num: ~w", [length(Written0)]),
    wait_for_written(lists:foldl(fun(N, Acc) -> maps:put(N, ok, Acc) end, #{}, Written0));
wait_for_written(Written0) ->
    receive
        {osiris_written, _Name, _WriterId, Corrs} ->
            Written = maps:without(Corrs, Written0),
            % ct:pal("written ~w", [Corrs]),
            case maps:size(Written) of
                0 ->
                    ok;
                _ ->
                    wait_for_written(Written)
            end
    after 1000 * 60 ->
        flush(),
        print_counters(),
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
            ct:fail("validate_read failed Offs ~b not eqial to ~b", [Offs, Next]);
        true ->
            validate_read(Max, Next + length(Recs), Log)
    end.

start_child_node(N, PrivDir) ->
    Dir0 = filename:join(PrivDir, N),
    Host = get_current_host(),
    Dir = "'\"" ++ Dir0 ++ "\"'",
    Pa = string:join(["-pa" | search_paths()] ++ ["-osiris data_dir", Dir], " "),
    ct:pal("starting child node with ~s~n", [Pa]),
    {ok, S} = slave:start_link(Host, N, Pa),
    ct:pal("started child node ~w ~w~n", [S, Host]),
    Res = rpc:call(S, application, ensure_all_started, [osiris]),
    ok = rpc:call(S, logger, set_primary_config, [level, all]),
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
    list_to_atom(lists:flatten(
                     io_lib:format("~s@~s", [N, H]))).

search_paths() ->
    Ld = code:lib_dir(),
    lists:filter(fun(P) -> string:prefix(P, Ld) =:= nomatch end, code:get_path()).

% start_profile(Config, Modules) ->
%     Dir = ?config(priv_dir, Config),
%     Case = ?config(test_case, Config),
%     GzFile = filename:join([Dir, "lg_" ++ atom_to_list(Case) ++ ".gz"]),
%     ct:pal("Profiling to ~p~n", [GzFile]),

%     lg:trace(Modules, lg_file_tracer,
%              GzFile, #{running => false, mode => profile}).

% stop_profile(Config) ->
%     Case = ?config(test_case, Config),
%     ct:pal("Stopping profiling for ~p~n", [Case]),
%     lg:stop(),
%     Dir = ?config(priv_dir, Config),
%     Name = filename:join([Dir, "lg_" ++ atom_to_list(Case)]),
%     lg_callgrind:profile_many(Name ++ ".gz.*", Name ++ ".out",#{}),
%     ok.

validate_log(Leader, Exp) when is_pid(Leader) ->
    case node(Leader) == node() of
        true ->
            {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, empty}),
            validate_log(Log0, Exp);
        false ->
            ok = rpc:call(node(Leader), ?MODULE, ?FUNCTION_NAME, [Leader, Exp])
    end;
validate_log(Log, []) ->
    ok = osiris_log:close(Log),
    ok;
validate_log(Log0, Expected) ->
    case osiris_log:read_chunk_parsed(Log0) of
        {end_of_stream, _} ->
            ct:fail("validate log failed, rem: ~p", [Expected]);
        {Entries, Log} ->
            validate_log(Log, Expected -- Entries)
    end.

print_counters() ->
    [begin ct:pal("~w counters ~p", [N, rpc:call(N, osiris_counters, overview, [])]) end
     || N <- nodes()].
