-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- MII source, monitors and protocol checkers at 10 or 100 Mbit/s: a source
-- drives an MII line that two monitors observe, each with a protocol checker
-- it instantiates. Tests that need traffic the source cannot produce,
-- such as an odd number of nibbles, drive the line directly instead. A test
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
use osvvm.RandomPkg.RandomPType;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_mii is
  generic (
    runner_cfg : string;
    link_rate_mbps : positive := 100
  );
end entity;

architecture tb of tb_mii is
  -- The clocks run at a quarter of the bit rate: 25 MHz at 100 Mbit/s and
  -- 2.5 MHz at 10 Mbit/s (IEEE 802.3 Clause 22)
  constant clk_period : time := 4000 ns / link_rate_mbps;

  signal clk : std_ulogic := '0';

  -- The line the monitors observe
  signal data : std_ulogic_vector(3 downto 0);
  signal dv, er : std_ulogic;

  signal source_data : std_ulogic_vector(3 downto 0);
  signal source_dv, source_er : std_ulogic;

  -- Nibbles driven by the test instead of the source
  signal raw_active : boolean := false;
  signal raw_data : std_ulogic_vector(3 downto 0) := x"0";
  signal raw_dv : std_ulogic := '0';

  constant source : mii_source_t := new_mii_source(link_rate_mbps => link_rate_mbps);
  constant monitor : mii_monitor_t := new_mii_monitor(
    link_rate_mbps => link_rate_mbps, protocol_checker => default_mii_protocol_checker,
    id => get_id("tb_mii:monitor")
  );
  constant second_monitor : mii_monitor_t := new_mii_monitor(
    link_rate_mbps => link_rate_mbps, protocol_checker => default_mii_protocol_checker,
    id => get_id("tb_mii:second_monitor")
  );

  type mii_monitor_vec_t is array (natural range <>) of mii_monitor_t;
  constant monitors : mii_monitor_vec_t := (monitor, second_monitor);
begin
  clk <= not clk after clk_period / 2;

  data <= raw_data when raw_active else source_data;
  dv <= raw_dv when raw_active else source_dv;
  er <= '0' when raw_active else source_er;

  main : process
    constant stimulus : python_session_t := new_session("tb_mii:stimulus");

    variable rnd : RandomPType;
    variable count : natural;
    variable total, expected_count : natural;

    -- Seeded random traffic with malformations, see awesome_vunit_vcs.ethernet.traffic.
    -- Without bad_sfd: MII realigns nibbles on the SFD, which expected_violations does not predict
    constant traffic_function : string := "awesome_vunit_vcs.ethernet.traffic:random_traffic";
    impure function traffic_arguments return arg_t is
    begin
      return
        kwarg("count", 60) & kwarg("malformations", "bad_fcs,short_preamble,long_preamble,runt,giant,phy_error,short_ifg") &
        kwarg("malformed_fraction", 0.3) & kwarg("interface", "mii");
    end;
    variable statistics : ethernet_statistics_t;
    variable nibbles : integer_vector(0 to 43);

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

    -- Check that each monitor found exactly expected violations of check. When
    -- errors is given, the monitor logged that many errors in total, otherwise
    -- the violations were the only errors logged.
    procedure check_violations(check : ethernet_check_t; expected : natural; errors : integer := -1) is
      variable violations : natural;
    begin
      wait_until_idle;
      for idx in monitors'range loop
        get_check_count(net, monitors(idx), check, violations);
        check_equal(
          violations, expected, "Violations of " & ethernet_check_t'image(check) & " on monitor " & to_string(idx)
        );
        if errors < 0 then
          check_equal(get_log_count(get_logger(get_protocol_checker(monitors(idx))), error), expected, "Errors on monitor " & to_string(idx));
          reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
        end if;
      end loop;
    end;

    procedure check_errors(expected : natural) is
    begin
      for idx in monitors'range loop
        check_equal(get_log_count(get_logger(get_protocol_checker(monitors(idx))), error), expected, "Errors on monitor " & to_string(idx));
        reset_log_count(get_logger(get_protocol_checker(monitors(idx))), error);
      end loop;
    end;

    -- The nibbles on the wire of a 60 octet frame with a good FCS, built with
    -- zlib as an independent reference: preamble_nibbles 0x5 nibbles, the SFD
    -- nibbles 0x5 0xD, the frame least significant nibble first, then extra
    impure function wire_nibbles(preamble_nibbles : natural; extra : string := "") return integer_array_t is
    begin
      exec(
        "import struct, zlib" & LF &
        "import numpy as np" & LF &
        "frame = bytes.fromhex('02000000000102000000000288b5') + bytes(range(46))" & LF &
        "wire = frame + struct.pack('<I', zlib.crc32(frame))" & LF &
        "nibbles = [5] * " & integer'image(preamble_nibbles) & " + [5, 13]" &
        " + [nibble for octet in wire for nibble in (octet & 15, octet >> 4)] + [" & extra & "]",
        stimulus
      );
      return eval_integer_array("np.array(nibbles, dtype=np.int32)", stimulus);
    end;

    -- Drive nibbles on the line instead of the source, followed by 12 idle octets
    procedure drive_nibbles(nibble_array : integer_array_t) is
    begin
      wait_until_idle;
      raw_active <= true;
      for idx in 0 to length(nibble_array) - 1 loop
        wait until rising_edge(clk);
        raw_data <= std_ulogic_vector(to_unsigned(get(nibble_array, idx), 4));
        raw_dv <= '1';
      end loop;
      wait until rising_edge(clk);
      raw_data <= x"0";
      raw_dv <= '0';
      for idx in 1 to 24 loop
        wait until rising_edge(clk);
      end loop;
      raw_active <= false;
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));

    -- Errors are expected in some tests; they are counted by check_violations
    -- and check_errors, and any error left uncounted still fails the test at
    -- cleanup
    for idx in monitors'range loop
      disable_stop(get_logger(get_protocol_checker(monitors(idx))), error);
    end loop;

    while test_suite loop
      if run("test_nibble_ordering") then
        push_checked_frame(frame_data(60));
        wait until rising_edge(clk) and dv = '1';
        for idx in nibbles'range loop
          nibbles(idx) := to_integer(unsigned(data));
          wait until rising_edge(clk);
        end loop;
        -- Seven preamble octets and the SFD 0xD5, low nibble first
        for idx in 0 to 14 loop
          check_equal(nibbles(idx), 16#5#, "Preamble nibble " & to_string(idx));
        end loop;
        check_equal(nibbles(15), 16#D#, "SFD high nibble");
        -- The destination address starts with 0x02, the EtherType is 0x88B5
        check_equal(nibbles(16), 16#2#, "Low nibble of the first frame octet");
        check_equal(nibbles(17), 16#0#, "High nibble of the first frame octet");
        check_equal(nibbles(40), 16#8#, "Low nibble of 0x88");
        check_equal(nibbles(41), 16#8#, "High nibble of 0x88");
        check_equal(nibbles(42), 16#5#, "Low nibble of 0xB5");
        check_equal(nibbles(43), 16#B#, "High nibble of 0xB5");
        check_violations(eth_fcs, 0);

      elsif run("test_minimum_size_frame") then
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

      elsif run("test_bad_fcs") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(fcs => fcs_bad));
        check_violations(eth_fcs, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.fcs_errors, 1);

      elsif run("test_phy_error") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(error_offsets => (0 => 20)));
        check_violations(eth_phy_error, 1);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.phy_error_frames, 1);

      elsif run("test_odd_preamble_nibble_count") then
        -- 15 preamble nibbles: the unpaired first nibble must not misalign the frame
        drive_nibbles(wire_nibbles(preamble_nibbles => 15));
        check_violations(eth_preamble, 0);
        check_violations(eth_sfd, 0);
        check_violations(eth_fcs, 0);
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);

      elsif run("test_trailing_nibble_is_an_alignment_error") then
        -- An extra nibble after the FCS leaves an incomplete octet, which is
        -- reported as bad termination; the incomplete octet also breaks the FCS
        drive_nibbles(wire_nibbles(preamble_nibbles => 14, extra => "10"));
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
        get_statistics(net, monitor, statistics);
        check_equal(statistics.min_ifg_octets, 8);

      elsif run("test_transmit_and_reconstruct") then
        push_checked_frame(frame_data(333, seed => 3));
        push_checked_frame(frame_data(64, seed => 4));
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 2);
        check_equal(statistics.payload_octets, (333 - 14) + (64 - 14));

      elsif run("test_monitors_are_independent") then
        set_check_enabled(net, second_monitor, eth_fcs, false);
        check_ethernet_frame(net, second_monitor, frame_data(80), blocking => false);
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
            expected_count := call_integer_w_arg(
              "vc.expected_violation_count", arg(ethernet_check_t'image(check_id)),
              session => new_session(get_id(monitors(idx)))
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
        for idx in 1 to 100 loop
          push_checked_frame(
            frame_data(rnd.RandInt(60, 1514), seed => idx),
            ifg_octets => rnd.RandInt(12, 40)
          );
        end loop;
        wait_until_idle;
        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 100, "Seed " & get_string_seed(runner_cfg));
        check_violations(eth_ifg, 0);
      end if;
    end loop;

    wait_until_idle;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1_000_000 * clk_period);

  source_inst : entity awesome_vunit_vcs.mii_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      data => source_data,
      dv => source_dv,
      er => source_er
    );

  monitor_inst : entity awesome_vunit_vcs.mii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      data => data,
      dv => dv,
      er => er
    );

  second_monitor_inst : entity awesome_vunit_vcs.mii_monitor
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
