-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Conformance of the AXI-Stream MAC client source, sink, monitor and protocol checker with the VUnit
-- verification component conventions: identity (id, logger, actor, checker)
-- and its inheritance, the unexpected message type policy, the sync VCI, the
-- stream master and slave VCIs, published frames, pops, blocking checks,
-- non-blocking requests, reset and port widths. Modelled on tb_vc_pkg and
-- tb_axi_stream of VUnit.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.stream_master_pkg.all;
  use vunit_lib.stream_slave_pkg.all;

library python_bridge;
context python_bridge.python_context;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;
  use awesome_vunit_vcs.vc_python_pkg.all;

entity tb_axis_mac_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axis_mac_vci is

  constant clk_period : time := 8 ns;
  signal clk_running : boolean := true;
  signal clk : std_ulogic := '0';

  -- The bus the source drives and every monitor and protocol checker observes
  signal tdata : std_ulogic_vector(63 downto 0);
  signal tkeep : std_ulogic_vector(7 downto 0);
  signal tvalid, tlast : std_ulogic;
  signal tready : std_ulogic := '1';
  signal tuser : std_ulogic_vector(0 downto 0);
  -- The buses of the other sources, observed by nobody
  signal second_tdata, ignoring_tdata : std_ulogic_vector(63 downto 0);
  signal second_tkeep, ignoring_tkeep : std_ulogic_vector(7 downto 0);
  signal second_tvalid : std_ulogic;
  signal second_tlast : std_ulogic;
  signal ignoring_tvalid : std_ulogic;
  signal ignoring_tlast : std_ulogic;
  signal second_tuser, ignoring_tuser : std_ulogic_vector(0 downto 0);
  -- The tready of the sinks
  signal sink_tready, ignoring_sink_tready : std_ulogic;

  constant sink : axis_mac_sink_t := new_axis_mac_sink(ready_high_percent => 50, seed => 3);
  constant second_sink : axis_mac_sink_t := new_axis_mac_sink;
  constant ignoring_sink : axis_mac_sink_t := new_axis_mac_sink(unexpected_msg_type_policy => ignore);

  constant source : axis_mac_source_t := new_axis_mac_source;
  constant second_source : axis_mac_source_t := new_axis_mac_source;
  constant ignoring_source : axis_mac_source_t := new_axis_mac_source(unexpected_msg_type_policy => ignore);

  constant monitor : axis_mac_monitor_t := new_axis_mac_monitor(
    protocol_checker => default_axis_mac_protocol_checker,
    id => get_id("tb_axis_mac_vci:monitor")
  );
  constant default_monitor : axis_mac_monitor_t := new_axis_mac_monitor;
  constant second_default_monitor : axis_mac_monitor_t := new_axis_mac_monitor;
  constant ignoring_monitor : axis_mac_monitor_t := new_axis_mac_monitor(unexpected_msg_type_policy => ignore);

  constant protocol_checker : axis_mac_protocol_checker_t := new_axis_mac_protocol_checker;
  constant second_protocol_checker : axis_mac_protocol_checker_t := new_axis_mac_protocol_checker;
  constant ignoring_protocol_checker : axis_mac_protocol_checker_t :=
    new_axis_mac_protocol_checker(unexpected_msg_type_policy => ignore);

  type axis_mac_protocol_checker_vec_t is array (natural range <>) of axis_mac_protocol_checker_t;

  -- Every protocol checker observing the line
  constant protocol_checkers : axis_mac_protocol_checker_vec_t :=
    (get_protocol_checker(monitor), protocol_checker, second_protocol_checker, ignoring_protocol_checker);

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown msg");
  constant subscriber : actor_t := new_actor("tb_axis_mac_vci:subscriber");

begin

  clk <= not clk after clk_period / 2 when clk_running else
         clk;

  main : process

    variable msg : msg_t;
    variable reference : ethernet_reference_t;
    variable stream_reference : stream_reference_t;
    variable octet : std_logic_vector(7 downto 0);
    variable last : boolean;
    variable received : std_ulogic_vector(0 to 8 * 1518 - 1);
    variable length : natural;
    variable fcs_ok : boolean;
    variable count : natural;
    variable session : python_session_t;
    variable statistics : ethernet_statistics_t;
    variable start : time;
    variable custom_logger : logger_t;
    variable custom_actor : actor_t;
    variable custom_checker : checker_t;
    variable custom_source : axis_mac_source_t;
    variable custom_monitor : axis_mac_monitor_t;

    -- Frame data from the destination address up to the FCS
    impure function frame_data (octets : positive) return std_ulogic_vector is

      variable result : std_ulogic_vector(0 to 8 * octets - 1);
    begin

      for idx in 0 to octets - 1 loop

        result(8 * idx to 8 * idx + 7) := std_ulogic_vector(to_unsigned(idx mod 256, 8));
      end loop;

      result(0 to 111) := x"020000000001" & x"020000000002" & x"88B5";
      return result;
    end;

    procedure wait_until_idle is
    begin

      wait_until_idle(net, as_sync(source));
      wait_until_idle(net, as_sync(monitor));
      wait_until_idle(net, as_sync(default_monitor));
      for idx in protocol_checkers'range loop

        wait_until_idle(net, as_sync(protocol_checkers(idx)));
      end loop;

    end;

    impure function starts_with (value, prefix : string) return boolean is
    begin

      return value'length >= prefix'length and value(value'left to value'left + prefix'length - 1) = prefix;
    end;

    procedure check_default_identity (
      id : id_t;
      logger : logger_t;
      actor : actor_t;
      checker : checker_t;
      vc_name : string
    ) is
    begin

      check(
        starts_with(full_name(id), "awesome_vunit_vcs:" & vc_name & ":"),
        "Default id of " & vc_name & ": " & full_name(id)
      );
      check_equal(get_full_name(logger), full_name(id), "Logger of " & vc_name);
      check(find(id, enable_deferred_creation => false) = actor, "Actor of " & vc_name);
      check(get_logger(checker) = logger, "Checker of " & vc_name);
    end;

    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown msg", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

    procedure check_wait_for_time (actor : actor_t) is
    begin

      start := now;
      wait_for_time(net, actor, 37 * clk_period);
      wait_until_idle(net, actor);
      check_equal(now - start, 37 * clk_period, "wait_for_time of " & name(actor));
    end;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_default_ids_are_enumerated_under_the_vc_name") then
        check_default_identity(
          get_id(source),
          get_logger(source),
          get_actor(source),
          get_checker(source),
          "axis_mac_source"
        );
        check_default_identity(
          get_id(default_monitor),
          get_logger(default_monitor),
          get_actor(default_monitor),
          get_checker(default_monitor),
          "axis_mac_monitor"
        );
        check_default_identity(
          get_id(protocol_checker),
          get_logger(protocol_checker),
          get_actor(protocol_checker),
          get_checker(protocol_checker),
          "axis_mac_protocol_checker"
        );
        check(get_id(source) /= get_id(second_source));
        check(get_id(default_monitor) /= get_id(second_default_monitor));
        check(get_id(protocol_checker) /= get_id(second_protocol_checker));
        check_default_identity(get_id(sink), get_logger(sink), get_actor(sink), get_checker(sink), "axis_mac_sink");
        check(get_id(sink) /= get_id(second_sink));

      elsif run("test_explicit_id_names_logger_actor_and_checker") then
        check_equal(full_name(get_id(monitor)), "tb_axis_mac_vci:monitor");
        check_equal(get_full_name(get_logger(monitor)), full_name(get_id(monitor)));
        check(get_id(get_actor(monitor)) = get_id(monitor));
        check(get_logger(get_checker(monitor)) = get_logger(monitor));

      elsif run("test_protocol_checker_is_a_child_of_its_monitor") then
        check_equal(full_name(get_id(get_protocol_checker(monitor))), "tb_axis_mac_vci:monitor:protocol_checker");
        check_equal(
          get_full_name(get_logger(get_protocol_checker(monitor))),
          "tb_axis_mac_vci:monitor:protocol_checker"
        );
        check(get_id(get_actor(get_protocol_checker(monitor))) = get_id(get_protocol_checker(monitor)));
        check(get_protocol_checker(default_monitor) = null_axis_mac_protocol_checker);

      elsif run("test_explicit_logger_actor_and_checker_are_kept") then
        custom_logger := get_logger("tb_axis_mac_vci:custom");
        custom_actor := new_actor("tb_axis_mac_vci:custom actor");
        custom_checker := new_checker("tb_axis_mac_vci:custom checker");
        custom_source := new_axis_mac_source(logger => custom_logger, actor => custom_actor, checker => custom_checker);
        check(get_logger(custom_source) = custom_logger);
        check(get_actor(custom_source) = custom_actor);
        check(get_checker(custom_source) = custom_checker);

        -- A protocol checker keeps the logger it was given when a monitor adopts it
        custom_monitor := new_axis_mac_monitor(
          protocol_checker => new_axis_mac_protocol_checker(logger => custom_logger)
        );
        check(get_logger(get_protocol_checker(custom_monitor)) = custom_logger);
        check_equal(
          full_name(get_id(get_protocol_checker(custom_monitor))),
          full_name(get_id(custom_monitor)) & ":protocol_checker"
        );

      elsif run("test_default_instances_have_independent_backends") then
        exec("vc.tb_marker = 'first'", new_session(get_id(default_monitor)));
        check_false(eval_boolean("hasattr(vc, 'tb_marker')", new_session(get_id(second_default_monitor))));
        exec("vc.tb_marker = 'first'", new_session(get_id(source)));
        check_false(eval_boolean("hasattr(vc, 'tb_marker')", new_session(get_id(second_source))));
        exec("vc.tb_marker = 'first'", new_session(get_id(protocol_checker)));
        check_false(eval_boolean("hasattr(vc, 'tb_marker')", new_session(get_id(second_protocol_checker))));

      elsif run("test_monitor_forwards_check_calls_to_its_protocol_checker") then
        set_check_enabled(net, monitor, eth_fcs, false);
        get_check_count(net, monitor, eth_fcs, count);
        check_equal(count, 0);
        set_check_enabled(net, monitor, eth_fcs);

      elsif run("test_check_calls_on_a_monitor_without_protocol_checker_fail") then
        mock(get_logger(default_monitor), failure);
        set_check_enabled(net, default_monitor, eth_fcs, false);
        check_only_log(
          get_logger(default_monitor),
          "set_check_enabled needs a protocol checker, but the monitor has none. Create the monitor with "
          & "protocol_checker => new_axis_mac_protocol_checker or default_axis_mac_protocol_checker",
          failure
        );
        unmock(get_logger(default_monitor));

      elsif run("test_two_sessions_for_one_id_fail") then
        session := new_vc_session(get_id("tb_axis_mac_vci:duplicate"));
        mock(get_logger(get_id("tb_axis_mac_vci:duplicate")), failure);
        session := new_vc_session(get_id("tb_axis_mac_vci:duplicate"));
        check_only_log(
          get_logger(get_id("tb_axis_mac_vci:duplicate")),
          "Two verification components have the id tb_axis_mac_vci:duplicate and would share one Python backend",
          failure
        );
        unmock(get_logger(get_id("tb_axis_mac_vci:duplicate")));

      elsif run("test_monitor_serves_the_checks_it_owns") then
        -- eth_scoreboard and eth_user belong to the monitor and need no protocol checker
        set_check_enabled(net, default_monitor, eth_user, false);
        get_check_count(net, default_monitor, eth_user, count);
        exec("vc.error('ETH_USER', 'not counted while disabled')", new_session(get_id(default_monitor)));
        get_check_count(net, default_monitor, eth_user, count);
        check_equal(count, 0, "eth_user while disabled");
        set_check_enabled(net, default_monitor, eth_user);
        get_check_count(net, default_monitor, eth_scoreboard, count);
        check_equal(count, 0, "eth_scoreboard");

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(source), get_logger(source), expect_failure => true);
        check_unexpected_message(get_actor(default_monitor), get_logger(default_monitor), expect_failure => true);
        check_unexpected_message(get_actor(protocol_checker), get_logger(protocol_checker), expect_failure => true);
        check_unexpected_message(get_actor(sink), get_logger(sink), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_source), get_logger(ignoring_source), expect_failure => false);
        check_unexpected_message(get_actor(ignoring_monitor), get_logger(ignoring_monitor), expect_failure => false);
        check_unexpected_message(
          get_actor(ignoring_protocol_checker),
          get_logger(ignoring_protocol_checker),
          expect_failure => false
        );
        check_unexpected_message(get_actor(ignoring_sink), get_logger(ignoring_sink), expect_failure => false);

      elsif run("test_wait_for_time") then
        check_wait_for_time(as_sync(source));
        check_wait_for_time(as_sync(default_monitor));
        check_wait_for_time(as_sync(protocol_checker));
        check_wait_for_time(as_sync(sink));

      elsif run("test_stream_master_and_slave") then
        -- A pop pending before the frame arrives
        pop_stream(net, as_stream(default_monitor), stream_reference);
        for idx in 0 to 59 loop

          push_stream(net, as_stream(source), frame_data(60)(8 * idx to 8 * idx + 7), last => idx = 59);
        end loop;

        await_pop_stream_reply(net, stream_reference, octet, last);
        check_equal(octet, frame_data(60)(0 to 7));
        check_false(last);
        for idx in 1 to 59 loop

          pop_stream(net, as_stream(default_monitor), octet, last);
          check_equal(octet, frame_data(60)(8 * idx to 8 * idx + 7), "Octet " & to_string(idx));
          check_equal(last, idx = 59, "last of octet " & to_string(idx));
        end loop;

      elsif run("test_push_stream_needs_octets") then
        mock(get_logger(source), error);
        push_stream(net, as_stream(source), std_logic_vector'("0101010"), last => true);
        wait_until_idle(net, as_sync(source));
        check_only_log(get_logger(source), "push_stream data of an Ethernet source is one octet, got 7 bits", error);
        unmock(get_logger(source));

      elsif run("test_push_stream_without_last") then
        for idx in 0 to 2 loop

          push_stream(net, as_stream(source), x"55");
        end loop;

        mock(get_logger(source), error);
        wait_until_idle(net, as_sync(source));
        check_only_log(get_logger(source), "3 octets were pushed with push_stream without last", error);
        unmock(get_logger(source));

      elsif run("test_monitor_publishes_frames") then
        -- docs-start: subscribe
        subscribe(subscriber, get_actor(default_monitor));
        push_ethernet_frame(net, source, frame_data(60));
        receive(net, subscriber, msg);
        check(message_type(msg) = ethernet_frame_msg, "Message type " & name(message_type(msg)));
        pop_ethernet_frame(msg, received, length, fcs_ok);
        check_equal(length, 60);
        check_true(fcs_ok);
        check_equal(received(0 to 479), frame_data(60));
        unsubscribe(subscriber, get_actor(default_monitor));
      -- docs-end: subscribe

      elsif run("test_pop_ethernet_frame") then
        pop_ethernet_frame(net, default_monitor, reference);
        push_ethernet_frame(net, source, frame_data(64));
        await_pop_ethernet_frame_reply(net, reference, received, length, fcs_ok);
        check_equal(length, 64);
        check_true(fcs_ok);
        check_equal(received(0 to 511), frame_data(64));

        push_ethernet_frame(net, source, frame_data(70));
        pop_ethernet_frame(net, default_monitor, received, length);
        check_equal(length, 70);
        check_equal(received(0 to 559), frame_data(70));

      elsif run("test_blocking_check_ethernet_frame") then
        push_ethernet_frame(net, source, frame_data(100));
        check_ethernet_frame(net, default_monitor, frame_data(100));
        get_frame_count(net, default_monitor, count);
        check_equal(count, 1);

        disable_stop(get_logger(default_monitor), error);
        push_ethernet_frame(net, source, frame_data(90));
        check_ethernet_frame(net, default_monitor, frame_data(80), "The second frame");
        check_equal(get_log_count(get_logger(default_monitor), error), 1);
        reset_log_count(get_logger(default_monitor), error);

      elsif run("test_non_blocking_requests") then
        push_ethernet_frame(net, source, frame_data(60));
        push_ethernet_frame(net, source, frame_data(61));
        wait_until_idle;
        get_statistics(net, default_monitor, reference);
        await_get_statistics_reply(net, reference, statistics);
        check_equal(statistics.good_frames, 2);
        get_frame_count(net, default_monitor, reference);
        await_get_frame_count_reply(net, reference, count);
        check_equal(count, 2);
        get_check_count(net, protocol_checker, eth_fcs, reference);
        await_get_check_count_reply(net, reference, count);
        check_equal(count, 0);

      elsif run("test_reset_mid_frame") then
        push_ethernet_frame(net, source, frame_data(1500));
        wait until rising_edge(clk) and tvalid = '1';
        for idx in 1 to 100 loop

          wait until rising_edge(clk);
        end loop;

        -- The monitors and protocol checkers ignore the rest of the frame
        reset(net, monitor);
        reset(net, default_monitor);
        for idx in protocol_checkers'range loop

          reset(net, protocol_checkers(idx));
        end loop;

        -- A reset returns also while the clock is stopped
        clk_running <= false;
        wait for 10 * clk_period;
        reset(net, source);
        clk_running <= true;
        wait_until_idle;

        -- A clean frame passes
        check_ethernet_frame(net, monitor, frame_data(60), blocking => false);
        push_ethernet_frame(net, source, frame_data(60));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        check_equal(statistics.total_frames, 1);
        for idx in protocol_checkers'range loop

          check_equal(
            get_log_count(get_logger(protocol_checkers(idx)), error),
            0,
            "Errors of protocol checker " & to_string(idx)
          );
        end loop;

      elsif run("test_reset_keeps_statistics_and_counts") then
        for idx in protocol_checkers'range loop

          if idx /= 1 then
            set_check_enabled(net, protocol_checkers(idx), eth_fcs, false);
          end if;
        end loop;

        disable_stop(get_logger(protocol_checker), error);
        push_ethernet_frame(net, source, frame_data(60), frame_options(fcs => fcs_bad));
        push_ethernet_frame(net, source, frame_data(60));
        wait_until_idle;

        reset(net, default_monitor);
        get_statistics(net, default_monitor, statistics);
        check_equal(statistics.total_frames, 2);
        reset(net, default_monitor, clear_statistics => true);
        get_statistics(net, default_monitor, statistics);
        check_equal(statistics.total_frames, 0);

        reset(net, protocol_checker);
        get_check_count(net, protocol_checker, eth_fcs, count);
        check_equal(count, 1);
        check_equal(get_log_count(get_logger(protocol_checker), error), 1);
        reset_log_count(get_logger(protocol_checker), error);

      elsif run("test_port_widths") then
        check_equal(tdata'length, data_length(source));
        check_equal(data_length(monitor), 64);
        check_equal(data_length(protocol_checker), 64);
        check_equal(keep_length(source), 8);
        check_equal(keep_length(monitor), 8);
        check_equal(user_length(protocol_checker), 1);

      elsif run("test_sink_ready_pattern") then
        -- About half of the clocks with tready high, then all after a reset
        count := 0;
        for idx in 1 to 400 loop

          wait until rising_edge(clk);
          if sink_tready = '1' then
            count := count + 1;
          end if;
        end loop;

        check(count > 120 and count < 280, "tready high on " & to_string(count) & " of 400 clocks");

        set_ready_pattern(net, sink, ready_high_percent => 0);
        wait until rising_edge(clk);
        for idx in 1 to 20 loop

          wait until rising_edge(clk);
          check_equal(sink_tready, '0', "tready with a pattern of 0 %");
        end loop;

        reset(net, sink);
        set_ready_pattern(net, sink, ready_high_percent => 100);
        wait until rising_edge(clk);
        for idx in 1 to 20 loop

          wait until rising_edge(clk);
          check_equal(sink_tready, '1', "tready with a pattern of 100 %");
        end loop;

      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);

  source_inst : entity awesome_vunit_vcs.axis_mac_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  second_source_inst : entity awesome_vunit_vcs.axis_mac_source
    generic map (
      source => second_source
    )
    port map (
      clk => clk,
      tdata => second_tdata,
      tkeep => second_tkeep,
      tvalid => second_tvalid,
      tlast => second_tlast,
      tuser => second_tuser
    );

  ignoring_source_inst : entity awesome_vunit_vcs.axis_mac_source
    generic map (
      source => ignoring_source
    )
    port map (
      clk => clk,
      tdata => ignoring_tdata,
      tkeep => ignoring_tkeep,
      tvalid => ignoring_tvalid,
      tlast => ignoring_tlast,
      tuser => ignoring_tuser
    );

  monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  default_monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (
      monitor => default_monitor
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  second_default_monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (
      monitor => second_default_monitor
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  ignoring_monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (
      monitor => ignoring_monitor
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  protocol_checker_inst : entity awesome_vunit_vcs.axis_mac_protocol_checker
    generic map (
      protocol_checker => protocol_checker
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  second_protocol_checker_inst : entity awesome_vunit_vcs.axis_mac_protocol_checker
    generic map (
      protocol_checker => second_protocol_checker
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  ignoring_protocol_checker_inst : entity awesome_vunit_vcs.axis_mac_protocol_checker
    generic map (
      protocol_checker => ignoring_protocol_checker
    )
    port map (
      clk => clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  sink_inst : entity awesome_vunit_vcs.axis_mac_sink
    generic map (
      sink => sink
    )
    port map (
      clk => clk,
      tready => sink_tready
    );

  second_sink_inst : entity awesome_vunit_vcs.axis_mac_sink
    generic map (
      sink => second_sink
    )
    port map (
      clk => clk,
      tready => open
    );

  ignoring_sink_inst : entity awesome_vunit_vcs.axis_mac_sink
    generic map (
      sink => ignoring_sink
    )
    port map (
      clk => clk,
      tready => ignoring_sink_tready
    );

end architecture;
