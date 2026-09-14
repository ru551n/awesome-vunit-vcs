-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- XGMII source, monitors and protocol checkers: a source drives an XGMII line
-- at 10 Gbit/s that two monitors observe, each with a protocol checker it
-- instantiates. The lane count and clocking are generics, run.py
-- runs the tests for 4-lane single edge, 4-lane both edges and 8 lanes.
-- A test expecting violations counts them, and the errors they log, on both
-- protocol checkers.

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
use osvvm.RandomPkg.RandomPType;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_xgmii is
  generic (
    runner_cfg : string;
    lanes : positive := 4;
    both_edges : boolean := false;
    link_rate_mbps : positive := 10000
  );
end entity;

architecture tb of tb_xgmii is
  -- A column carries lanes octets of 8 bits each: 800 ps at 10 Gbit/s, 20 ps at 400 Gbit/s
  constant column_period : time := lanes * (8 us / link_rate_mbps);
  constant clk_period : time := column_period * (1 + boolean'pos(both_edges));

  signal clk : std_ulogic := '0';
  signal data : std_ulogic_vector(8 * lanes - 1 downto 0);
  signal ctrl : std_ulogic_vector(lanes - 1 downto 0);

  constant source : xgmii_source_t := new_xgmii_source(lanes => lanes, both_edges => both_edges, link_rate_mbps => link_rate_mbps);
  constant monitor : xgmii_monitor_t := new_xgmii_monitor(
    lanes => lanes, both_edges => both_edges, link_rate_mbps => link_rate_mbps,
    protocol_checker => default_xgmii_protocol_checker,
    id => get_id("tb_xgmii:monitor")
  );
  constant second_monitor : xgmii_monitor_t := new_xgmii_monitor(
    lanes => lanes, both_edges => both_edges, link_rate_mbps => link_rate_mbps,
    protocol_checker => default_xgmii_protocol_checker,
    id => get_id("tb_xgmii:second_monitor")
  );

  type xgmii_monitor_vec_t is array (natural range <>) of xgmii_monitor_t;
  constant monitors : xgmii_monitor_vec_t := (monitor, second_monitor);
begin
  clk <= not clk after clk_period / 2;

  main : process
    -- The data octet and control bit of one lane
    type lane_t is record
      data : std_ulogic_vector(7 downto 0);
      control : std_ulogic;
    end record;
    type lane_vec_t is array (natural range <>) of lane_t;

    constant idle_lane : lane_t := (x"07", '1');

    variable column : lane_vec_t(0 to lanes - 1);
    variable rnd : RandomPType;
    variable count : natural;
    variable total, expected_count : natural;

    -- Seeded random traffic with malformations, see awesome_vunit_vcs.ethernet.traffic.
    constant traffic_function : string := "awesome_vunit_vcs.ethernet.traffic:random_traffic";
    constant traffic_arguments : string :=
      "count=60, malformations=('bad_fcs', 'short_preamble', 'long_preamble', 'bad_sfd', 'runt', 'giant', " &
      "'phy_error', 'short_ifg'), malformed_fraction=0.3, interface='xgmii'";
    variable statistics : ethernet_statistics_t;

    -- Frame data from the destination address up to the FCS: addresses, the
    -- local experimental EtherType and a counting payload
    impure function frame_data(octets : positive; seed : natural := 0) return std_ulogic_vector is
      variable result : std_ulogic_vector(0 to 8 * octets - 1);
    begin
      for idx in 0 to octets - 1 loop
        result(8 * idx to 8 * idx + 7) := std_ulogic_vector(to_unsigned((7 * idx + seed) mod 256, 8));
      end loop;
      result(0 to 111) := x"020000000001" & x"020000000002" & x"88B5";
      return result;
    end;

    -- Lanes of a frame of 64 zero octets, which has no valid FCS: Idle up to
    -- start_lane, Start, the rest of the preamble, the SFD, the frame,
    -- Terminate when terminate, then Idle to the end of the column and for one
    -- more column
    impure function raw_frame(start_lane : natural; terminate : boolean) return lane_vec_t is
      constant octets : positive := start_lane + 8 + 64 + boolean'pos(terminate);
      variable result : lane_vec_t(0 to (octets + lanes - 1) / lanes * lanes + lanes - 1) := (others => idle_lane);
    begin
      result(start_lane) := (x"FB", '1');
      for idx in start_lane + 1 to start_lane + 6 loop
        result(idx) := (x"55", '0');
      end loop;
      result(start_lane + 7) := (x"D5", '0');
      for idx in start_lane + 8 to start_lane + 71 loop
        result(idx) := (x"00", '0');
      end loop;
      if terminate then
        result(start_lane + 72) := (x"FD", '1');
      end if;
      return result;
    end;

    procedure send_lanes(value : lane_vec_t) is
      alias normalized : lane_vec_t(0 to value'length - 1) is value;
      variable column_data : std_ulogic_vector(0 to 8 * value'length - 1);
      variable column_control : std_ulogic_vector(0 to value'length - 1);
    begin
      for idx in normalized'range loop
        column_data(8 * idx to 8 * idx + 7) := normalized(idx).data;
        column_control(idx) := normalized(idx).control;
      end loop;
      push_xgmii_columns(net, source, column_data, column_control);
    end;

    procedure wait_until_idle is
    begin
      wait_until_idle(net, as_sync(source));
      for idx in monitors'range loop
        wait_until_idle(net, as_sync(monitors(idx)));
        wait_until_idle(net, as_sync(get_protocol_checker(monitors(idx))));
      end loop;
    end;

    -- Push a frame both monitors check that they receive unchanged
    procedure push_checked_frame(frame : std_ulogic_vector; ifg_octets : natural := 12) is
    begin
      for idx in monitors'range loop
        check_ethernet_frame(net, monitors(idx), frame, blocking => false);
      end loop;
      push_ethernet_frame(net, source, frame, frame_options(ifg_octets => ifg_octets));
    end;

    -- Check that each monitor found expected violations of check
    procedure check_violation_count(check : ethernet_check_t; expected : natural) is
      variable violations : natural;
    begin
      wait_until_idle;
      for idx in monitors'range loop
        get_check_count(net, monitors(idx), check, violations);
        check_equal(
          violations, expected, "Violations of " & ethernet_check_t'image(check) & " on monitor " & to_string(idx)
        );
      end loop;
    end;

    -- Check that each protocol checker logged expected errors since the last
    -- check, and the monitors none
    procedure check_error_count(expected : natural) is
    begin
      wait_until_idle;
      for idx in monitors'range loop
        check_equal(
          get_log_count(get_logger(get_protocol_checker(monitors(idx))), error), expected,
          "Errors on monitor " & to_string(idx)
        );
        reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
        check_equal(get_log_count(get_logger(monitors(idx)), error), 0, "Scoreboard errors on monitor " & to_string(idx));
      end loop;
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));

    -- Errors are expected in some tests; they are counted by check_error_count
    -- and any error left uncounted still fails the test at cleanup
    for idx in monitors'range loop
      disable_stop(get_logger(get_protocol_checker(monitors(idx))), error);
    end loop;

    while test_suite loop
      if run("test_terminate_on_every_lane") then
        -- Start, 7 preamble octets and 64 + idx frame octets put Terminate on lane idx
        for idx in 0 to lanes - 1 loop
          push_checked_frame(frame_data(60 + idx, seed => idx));
        end loop;
        check_error_count(0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, lanes);
        check_equal(statistics.min_frame_octets, 64);
        check_equal(statistics.max_frame_octets, 64 + lanes - 1);

      elsif run("test_bad_fcs") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(fcs => fcs_bad));
        check_violation_count(eth_fcs, 1);
        check_error_count(1);

      elsif run("test_error_character") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(error_offsets => (0 => 20)));
        check_violation_count(eth_phy_error, 1);
        -- The Error character replaces an octet of the frame
        check_violation_count(eth_fcs, 1);
        check_error_count(2);

      elsif run("test_start_on_wrong_lane") then
        send_lanes(raw_frame(start_lane => 1, terminate => true));
        check_violation_count(eth_control, 1);
        check_violation_count(eth_fcs, 1);
        check_error_count(2);

      elsif run("test_missing_terminate") then
        send_lanes(raw_frame(start_lane => 0, terminate => false));
        check_violation_count(eth_termination, 1);
        check_violation_count(eth_fcs, 1);
        check_error_count(2);

      elsif run("test_unknown_control_character") then
        -- 0x1C is a reserved control character
        column := (others => idle_lane);
        column(0) := (x"1C", '1');
        send_lanes(column);
        check_violation_count(eth_control, 1);
        check_error_count(1);

      elsif run("test_legal_ifg") then
        for idx in 1 to 5 loop
          push_checked_frame(frame_data(60 + idx, seed => idx), ifg_octets => 12);
        end loop;
        check_violation_count(eth_ifg, 0);
        check_error_count(0);
        get_statistics(net, monitor, statistics);
        check(statistics.min_ifg_octets >= 5, "Minimum IFG " & to_string(statistics.min_ifg_octets));

      elsif run("test_short_ifg") then
        -- 8 preamble octets and 68 frame octets end on the last lane of a
        -- column when followed by Terminate and 3 Idle octets
        push_checked_frame(frame_data(64), ifg_octets => 1);
        push_checked_frame(frame_data(60));
        check_violation_count(eth_ifg, 1);
        check_error_count(1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.min_ifg_octets, 4);

      elsif run("test_link_fault") then
        push_xgmii_link_fault(net, source, local_fault, columns => 4);
        push_xgmii_link_fault(net, source, remote_fault, columns => 2);
        check_violation_count(eth_link_fault, 2);
        check_error_count(2);

      elsif run("test_transmit_and_reconstruct") then
        push_checked_frame(frame_data(333, seed => 3));
        push_checked_frame(frame_data(1514, seed => 4));
        check_error_count(0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 2);
        check_equal(statistics.max_frame_octets, 1518);

      elsif run("test_monitors_are_independent") then
        -- The same line, but only the first monitor checks the FCS
        set_check_enabled(net, second_monitor, eth_fcs, false);
        push_ethernet_frame(net, source, frame_data(80), frame_options(fcs => fcs_bad));
        wait_until_idle;

        get_check_count(net, monitor, eth_fcs, count);
        check_equal(count, 1);
        check_equal(get_log_count(get_logger(get_protocol_checker(monitor)), error), 1);
        reset_log_count(get_logger(get_protocol_checker(monitor)), error);

        get_check_count(net, second_monitor, eth_fcs, count);
        check_equal(count, 0);
        check_equal(get_log_count(get_logger(get_protocol_checker(second_monitor)), error), 0);
        check(get_id(monitor) /= get_id(second_monitor));

      elsif run("test_malformed_sequence_matches_the_oracle") then
        -- The monitors expect the frames as they are received, and each protocol
        -- checker must find exactly the violations the Python oracle predicts
        for idx in monitors'range loop
          check_ethernet_sequence(
            net, monitors(idx), traffic_function, traffic_arguments, seed => get_string_seed(runner_cfg)
          );
        end loop;
        push_ethernet_sequence(net, source, traffic_function, traffic_arguments, seed => get_string_seed(runner_cfg));
        wait_until_idle;
        for idx in monitors'range loop
          total := 0;
          for check_id in eth_preamble to eth_link_fault loop
            get_check_count(net, monitors(idx), check_id, count);
            expected_count := eval_integer(
              "vc.expected_violation_count('" & ethernet_check_t'image(check_id) & "')",
              new_session(get_id(monitors(idx)))
            );
            check_equal(
              count, expected_count,
              ethernet_check_t'image(check_id) & " on monitor " & to_string(idx) & ", seed " &
              get_string_seed(runner_cfg)
            );
            total := total + count;
          end loop;
          check(total > 0, "The sequence has malformed frames, seed " & get_string_seed(runner_cfg));
          check_equal(get_log_count(get_logger(get_protocol_checker(monitors(idx))), error), total);
          reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
          check_equal(get_log_count(get_logger(monitors(idx)), error), 0, "Scoreboard errors on monitor " & to_string(idx));
        end loop;

      elsif run("test_randomized_traffic") then
        -- The deficit idle count shortens a gap by up to lanes - 1 octets
        for idx in 1 to 100 loop
          push_checked_frame(frame_data(rnd.RandInt(60, 1514), seed => idx), ifg_octets => rnd.RandInt(12, 40));
        end loop;
        check_error_count(0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 100, "Seed " & get_string_seed(runner_cfg));
        log_statistics(net, monitor);
      end if;
    end loop;

    wait_until_idle;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 ms);

  source_inst : entity awesome_vunit_vcs.xgmii_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      data => data,
      ctrl => ctrl
    );

  monitor_inst : entity awesome_vunit_vcs.xgmii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      data => data,
      ctrl => ctrl
    );

  second_monitor_inst : entity awesome_vunit_vcs.xgmii_monitor
    generic map (
      monitor => second_monitor
    )
    port map (
      clk => clk,
      data => data,
      ctrl => ctrl
    );
end architecture;
