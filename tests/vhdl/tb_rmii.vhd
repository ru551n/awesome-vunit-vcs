-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- RMII sources, monitors and protocol checkers at 10 or 100 Mbit/s: a source
-- drives an RMII line that two monitors observe, each with a protocol checker
-- it instantiates. A second source transmits like a PHY whose CRS_DV toggles
-- at the end of every frame, and tests that need traffic no source produces,
-- such as zero dibits before the preamble, drive the line directly. A test
-- expecting violations counts them on both monitors.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;
  use vunit_lib.integer_array_pkg.all;

library python_bridge;
context python_bridge.python_context;

library osvvm;
  use osvvm.randompkg.randomptype;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_rmii is
  generic (
    runner_cfg : string;
    link_rate_mbps : positive := 100);
end entity;

architecture tb of tb_rmii is

  -- The 50 MHz reference clock; at 10 Mbit/s a dibit lasts 10 clock cycles
  constant clk_period : time := 20 ns;
  constant cycles_per_dibit : positive := 1000 / (10 * link_rate_mbps);

  signal clk : std_ulogic := '0';

  -- The line the monitors observe
  signal data : std_ulogic_vector(1 downto 0);
  signal dv, er : std_ulogic;

  signal source_data, toggle_data : std_ulogic_vector(1 downto 0);
  signal source_dv : std_ulogic;
  signal source_er : std_ulogic;
  signal toggle_dv : std_ulogic;
  signal toggle_er : std_ulogic;

  type driver_t is (source_driver, toggle_driver, raw_driver);

  signal driver : driver_t := source_driver;
  -- Dibits driven by the test instead of a source
  signal raw_data : std_ulogic_vector(1 downto 0) := "00";
  signal raw_dv : std_ulogic := '0';

  constant source : rmii_source_t := new_rmii_source(link_rate_mbps => link_rate_mbps);
  constant toggle_source : rmii_source_t :=
    new_rmii_source(link_rate_mbps => link_rate_mbps, crs_dv_toggle_octets => 3);
  constant monitor : rmii_monitor_t := new_rmii_monitor(
    link_rate_mbps => link_rate_mbps,
    protocol_checker => default_rmii_protocol_checker,
    id => get_id("tb_rmii:monitor")
  );
  constant second_monitor : rmii_monitor_t := new_rmii_monitor(
    link_rate_mbps => link_rate_mbps,
    protocol_checker => default_rmii_protocol_checker,
    id => get_id("tb_rmii:second_monitor")
  );

  type rmii_monitor_vec_t is array (natural range <>) of rmii_monitor_t;

  constant monitors : rmii_monitor_vec_t := (monitor, second_monitor);

begin

  clk <= not clk after clk_period / 2;

  with driver select data <=
    source_data when source_driver,
    toggle_data when toggle_driver,
    raw_data when raw_driver;
  with driver select dv <=
    source_dv when source_driver,
    toggle_dv when toggle_driver,
    raw_dv when raw_driver;
  with driver select er <=
    source_er when source_driver,
    toggle_er when toggle_driver,
    '0' when raw_driver;

  main : process

    constant stimulus : python_session_t := new_session("tb_rmii:stimulus");

    variable rnd : randomptype;
    variable count : natural;
    variable total, expected_count : natural;
    variable statistics : ethernet_statistics_t;
    variable dibits : integer_vector(0 to 43);

    -- Seeded random traffic with malformations, see awesome_vunit_vcs.ethernet.traffic.
    -- Without bad_sfd: RMII realigns dibits on the SFD, which expected_violations does not predict
    constant traffic_function : string := "awesome_vunit_vcs.ethernet.traffic:random_traffic";
    impure function traffic_arguments return arg_t is
    begin

      return kwarg("count", 60)
             & kwarg("malformations", "bad_fcs,short_preamble,long_preamble,runt,giant,phy_error,short_ifg")
             & kwarg("malformed_fraction", 0.3)
             & kwarg("interface", "rmii");
    end;

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
      wait_until_idle(net, as_sync(toggle_source));
      for idx in monitors'range loop

        wait_until_idle(net, as_sync(monitors(idx)));
        wait_until_idle(net, as_sync(get_protocol_checker(monitors(idx))));
      end loop;

    end;

    procedure push_checked_frame (frame : std_ulogic_vector; ifg_octets : natural := 12) is
    begin

      for idx in monitors'range loop

        check_ethernet_frame(net, monitors(idx), frame, blocking => false);
      end loop;

      push_ethernet_frame(net, source, frame, frame_options(ifg_octets => ifg_octets));
    end;

    -- Check that each monitor found exactly expected violations of check. When
    -- errors is given, the monitor logged that many errors in total, otherwise
    -- the violations were the only errors logged.
    procedure check_violations (check : ethernet_check_t; expected : natural; errors : integer := -1) is

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
        if errors < 0 then
          check_equal(
            get_log_count(get_logger(get_protocol_checker(monitors(idx))), error),
            expected,
            "Errors on monitor " & to_string(idx)
          );
          reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
        end if;
      end loop;

    end;

    procedure check_errors (expected : natural) is
    begin

      for idx in monitors'range loop

        check_equal(
          get_log_count(get_logger(get_protocol_checker(monitors(idx))), error),
          expected,
          "Errors on monitor " & to_string(idx)
        );
        reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
      end loop;

    end;

    -- The dibits on the wire of a 60 octet frame with a good FCS, built with
    -- zlib as an independent reference: zeros 00 dibits, the preamble and SFD
    -- dibits, the frame least significant dibit first, then extra
    impure function wire_dibits (zeros : natural; extra : string := "") return integer_array_t is
    begin

      exec(
        "import struct, zlib"
        & LF
        & "import numpy as np"
        & LF
        & "frame = bytes.fromhex('02000000000102000000000288b5') + bytes(range(46))"
        & LF
        & "wire = bytes([0x55] * 7 + [0xD5]) + frame + struct.pack('<I', zlib.crc32(frame))"
        & LF
        & "dibits = [0] * "
        & integer'image(zeros)
        & " + [(octet >> shift) & 3 for octet in wire for shift in (0, 2, 4, 6)] + ["
        & extra
        & "]",
        stimulus
      );
      return eval_integer_array("np.array(dibits, dtype=np.int32)", stimulus);
    end;

    -- Drive dibits with CRS_DV asserted instead of a source, followed by 12 idle octets
    procedure drive_dibits (dibit_array : integer_array_t) is
    begin

      wait_until_idle;
      driver <= raw_driver;
      for idx in 0 to length(dibit_array) - 1 loop

        for cycle in 1 to cycles_per_dibit loop

          wait until rising_edge(clk);
          raw_data <= std_ulogic_vector(to_unsigned(get(dibit_array, idx), 2));
          raw_dv <= '1';
        end loop;

      end loop;

      wait until rising_edge(clk);
      raw_data <= "00";
      raw_dv <= '0';
      for idx in 1 to 48 * cycles_per_dibit loop

        wait until rising_edge(clk);
      end loop;

      driver <= source_driver;
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));

    for idx in monitors'range loop

      disable_stop(get_logger(get_protocol_checker(monitors(idx))), error);
    end loop;

    while test_suite loop

      if run("test_dibit_ordering") then
        push_checked_frame(frame_data(60));
        wait until rising_edge(clk) and dv = '1';
        for idx in dibits'range loop

          dibits(idx) := to_integer(unsigned(data));
          for cycle in 1 to cycles_per_dibit loop

            wait until rising_edge(clk);
          end loop;

        end loop;

        -- 31 preamble dibits 01 and the last SFD dibit 11, least significant dibit first
        for idx in 0 to 30 loop

          check_equal(dibits(idx), 1, "Preamble dibit " & to_string(idx));
        end loop;

        check_equal(dibits(31), 3, "Last SFD dibit");
        -- The destination address starts with 0x02
        check_equal(dibits(32), 2, "First dibit of the first frame octet");
        check_equal(dibits(33), 0, "Second dibit of the first frame octet");
        check_equal(dibits(34), 0, "Third dibit of the first frame octet");
        check_equal(dibits(35), 0, "Fourth dibit of the first frame octet");
        check_violations(eth_fcs, 0);

      elsif run("test_minimum_size_frame") then
        push_checked_frame(frame_data(60));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        check_equal(statistics.min_frame_octets, 64);

      elsif run("test_larger_frame") then
        push_checked_frame(frame_data(1514));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        check_equal(statistics.max_frame_octets, 1518);

      elsif run("test_bad_fcs") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(fcs => fcs_bad));
        check_violations(eth_fcs, 1);

      elsif run("test_receive_error") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(error_offsets => (0 => 20)));
        check_violations(eth_phy_error, 1);

      elsif run("test_zero_dibits_before_the_preamble") then
        -- A PHY presents 00 on RXD after asserting CRS_DV until it has decoded the stream
        drive_dibits(wire_dibits(zeros => 7));
        check_violations(eth_preamble, 0);
        check_violations(eth_sfd, 0);
        check_violations(eth_fcs, 0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);

      elsif run("test_toggling_crs_dv") then
        -- CRS_DV toggles during the last three octets of every frame
        driver <= toggle_driver;
        for idx in monitors'range loop

          check_ethernet_frame(net, monitors(idx), frame_data(60, seed => 1), blocking => false);
          check_ethernet_frame(net, monitors(idx), frame_data(100, seed => 2), blocking => false);
        end loop;

        push_ethernet_frame(net, toggle_source, frame_data(60, seed => 1));
        push_ethernet_frame(net, toggle_source, frame_data(100, seed => 2));
        wait until rising_edge(clk) and dv = '1';
        count := 0;
        while count < 3 loop

          wait until rising_edge(clk);
          if dv = '0' then
            count := count + 1;
          end if;
        end loop;

        check_violations(eth_fcs, 0);
        check_violations(eth_termination, 0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 2);
        check_equal(statistics.min_ifg_octets, 12);
        check_equal(get_log_count(get_logger(monitor), error), 0, "Scoreboard errors");
        driver <= source_driver;

      elsif run("test_trailing_dibits_are_an_alignment_error") then
        drive_dibits(wire_dibits(zeros => 0, extra => "2, 1"));
        check_violations(eth_termination, 1, errors => 2);
        check_violations(eth_fcs, 1, errors => 2);
        check_errors(2);

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
          for check_id in eth_preamble to eth_link_fault loop

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

      elsif run("test_randomized_traffic") then
        for idx in 1 to 50 loop

          push_checked_frame(frame_data(rnd.RandInt(60, 1514), seed => idx), ifg_octets => rnd.RandInt(12, 40));
        end loop;

        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 50, "Seed " & get_string_seed(runner_cfg));
        check_violations(eth_ifg, 0);
      end if;
    end loop;

    wait_until_idle;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20_000_000 * clk_period);

  source_inst : entity awesome_vunit_vcs.rmii_source
    generic map (
      source => source
    )
    port map (
      ref_clk => clk,
      data => source_data,
      dv => source_dv,
      er => source_er
    );

  toggle_source_inst : entity awesome_vunit_vcs.rmii_source
    generic map (
      source => toggle_source
    )
    port map (
      ref_clk => clk,
      data => toggle_data,
      dv => toggle_dv,
      er => toggle_er
    );

  monitor_inst : entity awesome_vunit_vcs.rmii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      ref_clk => clk,
      data => data,
      dv => dv,
      er => er
    );

  second_monitor_inst : entity awesome_vunit_vcs.rmii_monitor
    generic map (
      monitor => second_monitor
    )
    port map (
      ref_clk => clk,
      data => data,
      dv => dv,
      er => er
    );

end architecture;
