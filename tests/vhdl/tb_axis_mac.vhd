-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- AXI-Stream MAC client source, sink, monitors and protocol checkers: a source
-- sends frames to a sink applying backpressure, and two monitors observe the
-- bus, each with a protocol checker it instantiates. Tests of the AXI-Stream
-- rules drive a second bus directly, observed by a protocol checker of its own.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;

library python_bridge;
context python_bridge.python_context;

library osvvm;
  use osvvm.randompkg.randomptype;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_axis_mac is
  generic (
    runner_cfg : string;
    bytes_per_beat : positive := 8;
    ready_high_percent : natural := 100;
    valid_low_percent : natural := 0);
end entity;

architecture tb of tb_axis_mac is

  constant clk_period : time := 8 ns;
  signal clk : std_ulogic := '0';

  constant source : axis_mac_source_t :=
    new_axis_mac_source(bytes_per_beat => bytes_per_beat, valid_low_percent => valid_low_percent, seed => 17);
  constant sink : axis_mac_sink_t := new_axis_mac_sink(ready_high_percent => ready_high_percent, seed => 29);
  constant monitor : axis_mac_monitor_t := new_axis_mac_monitor(
    bytes_per_beat => bytes_per_beat,
    protocol_checker => default_axis_mac_protocol_checker,
    id => get_id("tb_axis_mac:monitor")
  );
  constant second_monitor : axis_mac_monitor_t := new_axis_mac_monitor(
    bytes_per_beat => bytes_per_beat,
    protocol_checker => default_axis_mac_protocol_checker,
    id => get_id("tb_axis_mac:second_monitor")
  );

  type axis_mac_monitor_vec_t is array (natural range <>) of axis_mac_monitor_t;

  constant monitors : axis_mac_monitor_vec_t := (monitor, second_monitor);

  signal tdata : std_ulogic_vector(data_length(source) - 1 downto 0);
  signal tkeep : std_ulogic_vector(keep_length(source) - 1 downto 0);
  signal tvalid : std_ulogic;
  signal tready : std_ulogic;
  signal tlast : std_ulogic;
  signal tuser : std_ulogic_vector(0 downto 0);

  -- A bus without FCS
  constant no_fcs_source : axis_mac_source_t := new_axis_mac_source(bytes_per_beat => 4, has_fcs => false);
  constant no_fcs_monitor : axis_mac_monitor_t :=
    new_axis_mac_monitor(bytes_per_beat => 4, has_fcs => false, protocol_checker => default_axis_mac_protocol_checker);
  signal no_fcs_tdata : std_ulogic_vector(31 downto 0);
  signal no_fcs_tkeep : std_ulogic_vector(3 downto 0);
  signal no_fcs_tvalid, no_fcs_tlast : std_ulogic;
  signal no_fcs_tuser : std_ulogic_vector(0 downto 0);

  -- A bus the tests of the AXI-Stream rules drive directly
  constant manual_checker : axis_mac_protocol_checker_t := new_axis_mac_protocol_checker(bytes_per_beat => 4);
  signal manual_tdata : std_ulogic_vector(31 downto 0) := (others => '0');
  signal manual_tkeep : std_ulogic_vector(3 downto 0) := (others => '0');
  signal manual_tvalid, manual_tlast : std_ulogic := '0';
  signal manual_tready : std_ulogic := '1';

begin

  clk <= not clk after clk_period / 2;

  main : process

    variable rnd : randomptype;
    variable count : natural;
    variable total : natural;
    variable expected_count : natural;
    variable statistics : ethernet_statistics_t;

    constant traffic_function : string := "awesome_vunit_vcs.ethernet.traffic:random_traffic";
    impure function traffic_arguments return arg_t is
    begin

      return kwarg("count", 40)
             & kwarg("malformations", "bad_fcs,runt,giant,phy_error")
             & kwarg("malformed_fraction", 0.3)
             & kwarg("interface", "axis");
    end;

    -- Frame data from the destination address up to the FCS
    impure function frame_data (octets : positive; seed : natural := 0) return std_ulogic_vector is

      variable result : std_ulogic_vector(0 to 8 * octets - 1);
    begin

      for idx in 0 to octets - 1 loop

        result(8 * idx to 8 * idx + 7) := std_ulogic_vector(to_unsigned((7 * idx + seed) mod 256, 8));
      end loop;

      result(0 to 111) := x"020000000001" & x"020000000002" & x"88B5";
      return result;
    end;

    procedure wait_until_idle is
    begin

      wait_until_idle(net, as_sync(source));
      wait_until_idle(net, as_sync(no_fcs_source));
      for idx in monitors'range loop

        wait_until_idle(net, as_sync(monitors(idx)));
        wait_until_idle(net, as_sync(get_protocol_checker(monitors(idx))));
      end loop;

      wait_until_idle(net, as_sync(no_fcs_monitor));
      wait_until_idle(net, as_sync(manual_checker));
    end;

    procedure push_checked_frame (frame : std_ulogic_vector) is
    begin

      for idx in monitors'range loop

        check_ethernet_frame(net, monitors(idx), frame, blocking => false);
      end loop;

      push_ethernet_frame(net, source, frame);
    end;

    procedure check_violations (check : ethernet_check_t; expected : natural) is

      variable violations : natural;
    begin

      wait_until_idle;
      for idx in monitors'range loop

        get_check_count(net, monitors(idx), check, violations);
        check_equal(
          violations,
          expected,
          "Violations of " & ethernet_check_t'image(check) & " on monitor " & to_string(idx)
        );
        check_equal(
          get_log_count(get_logger(get_protocol_checker(monitors(idx))), error),
          expected,
          "Errors on monitor " & to_string(idx)
        );
        reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
      end loop;

    end;

    -- One clock of the manually driven bus
    procedure drive_manual (
      data : std_ulogic_vector(31 downto 0);
      keep : std_ulogic_vector(3 downto 0);
      valid, last : std_ulogic;
      ready : std_ulogic := '1'
    ) is
    begin

      manual_tdata <= data;
      manual_tkeep <= keep;
      manual_tvalid <= valid;
      manual_tlast <= last;
      manual_tready <= ready;
      wait until rising_edge(clk);
    end;

    procedure check_manual_violations (check : ethernet_check_t; expected : natural) is
    begin

      drive_manual(x"00000000", "0000", '0', '0');
      wait_until_idle;
      get_check_count(net, manual_checker, check, count);
      check_equal(count, expected, "Violations of " & ethernet_check_t'image(check));
      check_equal(get_log_count(get_logger(manual_checker), error), expected, "Errors of the manual protocol checker");
      reset_log_count(get_logger(manual_checker), error);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));
    exec("import sys");
    call("sys.path.insert", arg(0), arg(tb_path(runner_cfg) & "python"));

    for idx in monitors'range loop

      disable_stop(get_logger(get_protocol_checker(monitors(idx))), error);
    end loop;

    disable_stop(get_logger(manual_checker), error);
    -- The manual frames are short and have no FCS; only the AXI-Stream rules are checked
    set_check_enabled(net, manual_checker, eth_fcs, false);
    set_check_enabled(net, manual_checker, eth_runt, false);

    while test_suite loop

      if run("test_frames_of_many_lengths") then
        for octets in 60 to 60 + 2 * bytes_per_beat loop

          push_checked_frame(frame_data(octets, seed => octets));
        end loop;

        push_checked_frame(frame_data(1514));
        check_violations(eth_keep, 0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 2 * bytes_per_beat + 2);
        check_equal(get_log_count(get_logger(monitor), error), 0);

      elsif run("test_bad_fcs") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(fcs => fcs_bad));
        check_violations(eth_fcs, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.fcs_errors, 1);

      elsif run("test_runt_frame") then
        push_ethernet_frame(net, source, frame_data(20), frame_options(pad => false));
        check_violations(eth_runt, 1);

      elsif run("test_oversized_frame") then
        push_ethernet_frame(net, source, frame_data(1600));
        check_violations(eth_giant, 1);

      elsif run("test_tuser_error") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(error_offsets => (0 => 20)));
        check_violations(eth_phy_error, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.phy_error_frames, 1);

      elsif run("test_randomized_traffic_with_backpressure") then
        for idx in 1 to 30 loop

          push_checked_frame(frame_data(rnd.RandInt(60, 600), seed => idx));
        end loop;

        check_violations(eth_stable, 0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 30, "Seed " & get_string_seed(runner_cfg));
        check_equal(get_log_count(get_logger(monitor), error), 0);

      elsif run("test_frames_without_fcs") then
        check_ethernet_frame(net, no_fcs_monitor, frame_data(60), blocking => false);
        check_ethernet_frame(net, no_fcs_monitor, frame_data(99), blocking => false);
        push_ethernet_frame(net, no_fcs_source, frame_data(60));
        push_ethernet_frame(net, no_fcs_source, frame_data(99));
        wait_until_idle;
        get_statistics(net, no_fcs_monitor, statistics);
        check_equal(statistics.good_frames, 2);
        check_equal(get_log_count(get_logger(no_fcs_monitor), error), 0);
        check_equal(get_log_count(get_logger(get_protocol_checker(no_fcs_monitor)), error), 0);

      elsif run("test_partial_beat_before_the_last") then
        drive_manual(x"01020304", "0101", '1', '0');
        drive_manual(x"05060708", "1111", '1', '1');
        check_manual_violations(eth_keep, 1);

      elsif run("test_bus_changes_while_waiting_for_tready") then
        drive_manual(x"01020304", "1111", '1', '0', ready => '0');
        drive_manual(x"11020304", "1111", '1', '0', ready => '0');
        drive_manual(x"11020304", "1111", '1', '0');
        drive_manual(x"21020304", "1111", '1', '1');
        check_manual_violations(eth_stable, 1);

      elsif run("test_tvalid_dropped_before_the_handshake") then
        drive_manual(x"01020304", "1111", '1', '0', ready => '0');
        drive_manual(x"01020304", "1111", '0', '0', ready => '0');
        check_manual_violations(eth_valid, 1);

      elsif run("test_monitors_are_independent") then
        set_check_enabled(net, second_monitor, eth_fcs, false);
        push_ethernet_frame(net, source, frame_data(80), frame_options(fcs => fcs_bad));
        wait_until_idle;
        get_check_count(net, monitor, eth_fcs, count);
        check_equal(count, 1);
        reset_log_count(get_logger(get_protocol_checker(monitor)), error);
        get_check_count(net, second_monitor, eth_fcs, count);
        check_equal(count, 0);
        check_equal(get_log_count(get_logger(get_protocol_checker(second_monitor)), error), 0);

      elsif run("test_reset_mid_frame") then
        push_ethernet_frame(net, source, frame_data(1500));
        wait until rising_edge(clk) and tvalid = '1' and tready = '1';
        for idx in 1 to 20 loop

          wait until rising_edge(clk);
        end loop;

        -- The source abandons the frame, then the monitors forget it
        reset(net, source);
        reset(net, sink);
        for idx in monitors'range loop

          reset(net, monitors(idx));
          reset(net, get_protocol_checker(monitors(idx)));
        end loop;

        wait_until_idle;

        push_checked_frame(frame_data(60));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        check_equal(statistics.total_frames, 1);
        check_violations(eth_fcs, 0);

      elsif run("test_malformed_sequence_matches_the_oracle") then
        for idx in monitors'range loop

          check_ethernet_sequence(
            net,
            monitors(idx),
            traffic_function,
            traffic_arguments,
            seed => get_string_seed(runner_cfg)
          );
        end loop;

        push_ethernet_sequence(net, source, traffic_function, traffic_arguments, seed => get_string_seed(runner_cfg));
        wait_until_idle;
        for idx in monitors'range loop

          total := 0;
          for check_id in eth_preamble to eth_valid loop

            get_check_count(net, monitors(idx), check_id, count);
            expected_count := call_integer_w_arg(
              "vc.expected_violation_count",
              arg(ethernet_check_t'image(check_id)),
              session => new_session(get_id(monitors(idx)))
            );
            check_equal(
              count,
              expected_count,
              ethernet_check_t'image(check_id)
              & " on monitor "
              & to_string(idx)
              & ", seed "
              & get_string_seed(runner_cfg)
            );
            total := total + count;
          end loop;

          check(total > 0, "The sequence has malformed frames, seed " & get_string_seed(runner_cfg));
          check_equal(get_log_count(get_logger(get_protocol_checker(monitors(idx))), error), total);
          reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
          check_equal(
            get_log_count(get_logger(monitors(idx)), error),
            0,
            "Scoreboard errors on monitor " & to_string(idx)
          );
        end loop;

      end if;
    end loop;

    wait_until_idle;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 50 ms);

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

  sink_inst : entity awesome_vunit_vcs.axis_mac_sink
    generic map (
      sink => sink
    )
    port map (
      clk => clk,
      tready => tready
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

  second_monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (
      monitor => second_monitor
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

  no_fcs_source_inst : entity awesome_vunit_vcs.axis_mac_source
    generic map (
      source => no_fcs_source
    )
    port map (
      clk => clk,
      tdata => no_fcs_tdata,
      tkeep => no_fcs_tkeep,
      tvalid => no_fcs_tvalid,
      tlast => no_fcs_tlast,
      tuser => no_fcs_tuser
    );

  no_fcs_monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (
      monitor => no_fcs_monitor
    )
    port map (
      clk => clk,
      tdata => no_fcs_tdata,
      tkeep => no_fcs_tkeep,
      tvalid => no_fcs_tvalid,
      tlast => no_fcs_tlast,
      tuser => no_fcs_tuser
    );

  manual_checker_inst : entity awesome_vunit_vcs.axis_mac_protocol_checker
    generic map (
      protocol_checker => manual_checker
    )
    port map (
      clk => clk,
      tdata => manual_tdata,
      tkeep => manual_tkeep,
      tvalid => manual_tvalid,
      tready => manual_tready,
      tlast => manual_tlast
    );

end architecture;
