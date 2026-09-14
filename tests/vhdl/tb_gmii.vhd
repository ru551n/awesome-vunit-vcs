-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- GMII source, monitors and protocol checkers: a source drives a GMII line that
-- two monitors observe, each with a protocol checker it instantiates. Every
-- frame a test pushes is reconstructed and checked in Python by both. A test
-- expecting violations counts them on both protocol checkers.

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

entity tb_gmii is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_gmii is
  constant clk_period : time := 8 ns;

  signal clk : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0);
  signal dv, er : std_ulogic;

  constant source : gmii_source_t := new_gmii_source;
  constant monitor : gmii_monitor_t := new_gmii_monitor(
    protocol_checker => default_gmii_protocol_checker, id => get_id("tb_gmii:monitor")
  );
  constant second_monitor : gmii_monitor_t := new_gmii_monitor(
    protocol_checker => default_gmii_protocol_checker, id => get_id("tb_gmii:second_monitor")
  );

  type gmii_monitor_vec_t is array (natural range <>) of gmii_monitor_t;
  constant monitors : gmii_monitor_vec_t := (monitor, second_monitor);
begin
  clk <= not clk after clk_period / 2;

  main : process
    variable rnd : RandomPType;
    variable count : natural;
    variable total, expected_count : natural;

    -- Seeded random traffic with malformations, see awesome_vunit_vcs.ethernet.traffic.
    constant traffic_function : string := "awesome_vunit_vcs.ethernet.traffic:random_traffic";
    constant traffic_arguments : string :=
      "count=60, malformations=('bad_fcs', 'short_preamble', 'long_preamble', 'bad_sfd', 'runt', 'giant', " &
      "'phy_error', 'short_ifg'), malformed_fraction=0.3, interface='gmii'";
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

    -- Check that each protocol checker found exactly expected violations of
    -- check and that they were the only errors logged
    procedure check_violations(check : ethernet_check_t; expected : natural) is
      variable violations : natural;
    begin
      wait_until_idle;
      for idx in monitors'range loop
        get_check_count(net, get_protocol_checker(monitors(idx)), check, violations);
        check_equal(
          violations, expected, "Violations of " & ethernet_check_t'image(check) & " on monitor " & to_string(idx)
        );
        check_equal(
          get_log_count(get_logger(get_protocol_checker(monitors(idx))), error), expected,
          "Errors on monitor " & to_string(idx)
        );
        reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
      end loop;
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));
    -- The Python functions of the traffic tests
    exec("import sys" & LF & "sys.path.insert(0, " & "'" & tb_path(runner_cfg) & "python')");

    -- Errors are expected in some tests; they are counted by check_violations
    -- and any error left uncounted still fails the test at cleanup
    for idx in monitors'range loop
      disable_stop(get_logger(get_protocol_checker(monitors(idx))), error);
    end loop;

    while test_suite loop
      if run("test_minimum_size_frame") then
        push_checked_frame(frame_data(60));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        check_equal(statistics.min_frame_octets, 64);
        check_equal(statistics.max_frame_octets, 64);

      elsif run("test_larger_frame") then
        push_checked_frame(frame_data(1514));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        check_equal(statistics.max_frame_octets, 1518);

      elsif run("test_header_fields") then
        for idx in monitors'range loop
          check_ethernet_frame(net, monitors(idx), frame_data(60), blocking => false);
        end loop;
        push_ethernet_frame(net, source, x"020000000001", x"020000000002", x"88B5", frame_data(60)(112 to 479));
        check_violations(eth_scoreboard, 0);
        check_equal(get_log_count(get_logger(monitor), error), 0);

      elsif run("test_preamble_and_sfd") then
        push_checked_frame(frame_data(60));
        check_violations(eth_preamble, 0);
        check_violations(eth_sfd, 0);

        push_ethernet_frame(net, source, frame_data(60), frame_options(preamble_octets => 5));
        check_violations(eth_preamble, 1);

        push_ethernet_frame(net, source, frame_data(60), frame_options(sfd => x"D4"));
        check_violations(eth_sfd, 1);

      elsif run("test_fcs_pass") then
        for idx in 1 to 10 loop
          push_checked_frame(frame_data(rnd.RandInt(60, 1514), seed => idx));
        end loop;
        check_violations(eth_fcs, 0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 10);
        check_equal(statistics.fcs_errors, 0);

      elsif run("test_bad_fcs") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(fcs => fcs_bad));
        check_violations(eth_fcs, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.fcs_errors, 1);
        check_equal(statistics.bad_frames, 1);

      elsif run("test_runt_frame") then
        push_ethernet_frame(net, source, frame_data(20), frame_options(pad => false));
        check_violations(eth_runt, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.runts, 1);

      elsif run("test_oversized_frame") then
        push_ethernet_frame(net, source, frame_data(1600));
        check_violations(eth_giant, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.giants, 1);

      elsif run("test_phy_error") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(error_offsets => (0 => 20)));
        check_violations(eth_phy_error, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.phy_error_frames, 1);

      elsif run("test_legal_ifg") then
        for idx in 1 to 3 loop
          push_checked_frame(frame_data(60, seed => idx), ifg_octets => 12);
        end loop;
        check_violations(eth_ifg, 0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.min_ifg_octets, 12);

      elsif run("test_short_ifg") then
        push_checked_frame(frame_data(60), ifg_octets => 8);
        push_checked_frame(frame_data(60));
        check_violations(eth_ifg, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.min_ifg_octets, 8);

      elsif run("test_back_to_back_frames") then
        for idx in 1 to 5 loop
          push_checked_frame(frame_data(100, seed => idx), ifg_octets => 12);
        end loop;
        wait_until_idle;
        for idx in monitors'range loop
          get_frame_count(net, monitors(idx), count);
          check_equal(count, 5);
        end loop;

      elsif run("test_monitors_are_independent") then
        -- The same line, but only the first protocol checker checks the FCS
        -- and only the second monitor checks the frame
        set_check_enabled(net, get_protocol_checker(second_monitor), eth_fcs, false);
        check_ethernet_frame(net, second_monitor, frame_data(80), blocking => false);
        push_ethernet_frame(net, source, frame_data(80), frame_options(fcs => fcs_bad));
        wait_until_idle;

        get_check_count(net, get_protocol_checker(monitor), eth_fcs, count);
        check_equal(count, 1);
        check_equal(get_log_count(get_logger(get_protocol_checker(monitor)), error), 1);
        reset_log_count(get_logger(get_protocol_checker(monitor)), error);

        get_check_count(net, get_protocol_checker(second_monitor), eth_fcs, count);
        check_equal(count, 0);
        check_equal(get_log_count(get_logger(get_protocol_checker(second_monitor)), error), 0);
        check(get_id(monitor) /= get_id(second_monitor));

      elsif run("test_pcap_export") then
        start_capture(net, monitor, output_path(runner_cfg) & "gmii.pcapng");
        for idx in 1 to 3 loop
          push_checked_frame(frame_data(60 + idx, seed => idx));
        end loop;
        wait_until_idle;
        stop_capture(net, monitor);
        wait_until_idle;

        -- Read the capture back with Scapy, an independent PCAPNG reader
        exec(
          "from scapy.utils import rdpcap" & LF &
          "packets = rdpcap(" & "'" & output_path(runner_cfg) & "gmii.pcapng')",
          new_session("tb_gmii:pcap_reader")
        );
        check_equal(eval_integer("len(packets)", new_session("tb_gmii:pcap_reader")), 3);
        -- 61 octets of frame data and the FCS
        check_equal(eval_integer("len(packets[0])", new_session("tb_gmii:pcap_reader")), 65);

      elsif run("test_scapy_packet_decode") then
        push_ethernet_packet(net, source, "tb_traffic:udp_packet", "dport=1234");
        check_violations(eth_fcs, 0);
        -- The backend of a monitor is the object vc in the session with the
        -- identity of the monitor
        check_true(eval_boolean("vc.last_packet().haslayer('UDP')", new_session(get_id(monitor))));
        check_equal(eval_integer("vc.last_packet()['UDP'].dport", new_session(get_id(monitor))), 1234);
        check_equal(eval_string("vc.last_packet().dst", new_session(get_id(monitor))), "02:00:00:00:00:01");

      elsif run("test_transmit_and_reconstruct") then
        push_checked_frame(frame_data(333, seed => 3));
        push_checked_frame(frame_data(64, seed => 4));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 2);
        -- Payload octets exclude the 14 octet header of each frame
        check_equal(statistics.payload_octets, (333 - 14) + (64 - 14));

      elsif run("test_reproducible_sequence") then
        -- The same function, arguments and seed give the same frames on the
        -- source and the monitors
        for idx in monitors'range loop
          check_ethernet_sequence(
            net, monitors(idx), "tb_traffic:random_frames", "max_size=600", count => 50,
            seed => get_string_seed(runner_cfg)
          );
        end loop;
        push_ethernet_sequence(
          net, source, "tb_traffic:random_frames", "max_size=600", count => 50, seed => get_string_seed(runner_cfg)
        );
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 50, "Seed " & get_string_seed(runner_cfg));
        check_equal(get_log_count(get_logger(monitor), error), 0);
        check_violations(eth_fcs, 0);

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
            get_check_count(net, get_protocol_checker(monitors(idx)), check_id, count);
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
        for idx in 1 to 200 loop
          push_checked_frame(
            frame_data(rnd.RandInt(60, 1514), seed => idx),
            ifg_octets => rnd.RandInt(12, 40)
          );
        end loop;
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 200, "Seed " & get_string_seed(runner_cfg));
        log_statistics(net, monitor);
      end if;
    end loop;

    wait_until_idle;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);

  source_inst : entity awesome_vunit_vcs.gmii_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      data => data,
      dv => dv,
      er => er
    );

  monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      data => data,
      dv => dv,
      er => er
    );

  second_monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (
      monitor => second_monitor
    )
    port map (
      clk => clk,
      data => data,
      dv => dv,
      er => er
    );
end architecture;
