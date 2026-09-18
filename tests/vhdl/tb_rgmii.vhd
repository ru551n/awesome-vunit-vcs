-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- RGMII source, monitors and protocol checkers at 10, 100 or 1000 Mbit/s,
-- with centered or edge aligned data: a source drives an RGMII line that two
-- monitors observe, each with a protocol checker it instantiates. A test
-- expecting violations counts them on both monitors.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;

library osvvm;
  use osvvm.randompkg.randomptype;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_rgmii is
  generic (
    runner_cfg : string;
    link_rate_mbps : positive := 1000;
    edge_aligned : boolean := false);
end entity;

architecture tb of tb_rgmii is

  -- 125 MHz at 1000 Mbit/s, 25 MHz at 100 and 2.5 MHz at 10
  function clock_period return time is
  begin

    if link_rate_mbps = 1000 then
      return 8 ns;
    end if;
    return 4000 ns / link_rate_mbps;
  end;

  function data_timing return rgmii_data_timing_t is
  begin

    if edge_aligned then
      return rgmii_edge_aligned;
    end if;
    return rgmii_centered;
  end;

  constant clk_period : time := clock_period;
  constant gigabit : boolean := link_rate_mbps = 1000;

  signal clk : std_ulogic := '0';
  -- The clock the test samples edge aligned data on, like the monitors do
  signal sample_clk : std_ulogic := '0';

  signal data : std_ulogic_vector(3 downto 0);
  signal ctl : std_ulogic;

  constant source : rgmii_source_t := new_rgmii_source(link_rate_mbps => link_rate_mbps, data_timing => data_timing);
  constant monitor : rgmii_monitor_t := new_rgmii_monitor(
    link_rate_mbps => link_rate_mbps,
    data_timing => data_timing,
    protocol_checker => default_rgmii_protocol_checker,
    id => get_id("tb_rgmii:monitor")
  );
  constant second_monitor : rgmii_monitor_t := new_rgmii_monitor(
    link_rate_mbps => link_rate_mbps,
    data_timing => data_timing,
    protocol_checker => default_rgmii_protocol_checker,
    id => get_id("tb_rgmii:second_monitor")
  );

  type rgmii_monitor_vec_t is array (natural range <>) of rgmii_monitor_t;

  constant monitors : rgmii_monitor_vec_t := (monitor, second_monitor);

begin

  clk <= not clk after clk_period / 2;
  sample_clk <= transport clk after get_sample_delay(monitor);

  main : process

    variable rnd : randomptype;
    variable count : natural;
    variable total, expected_count : natural;
    variable statistics : ethernet_statistics_t;
    -- The symbols of the first 22 octets as sampled: rising edge data and CTL, falling edge data and CTL
    type symbol_t is record
      rising_data, falling_data : natural;
      rising_ctl, falling_ctl   : std_ulogic;
    end record;

    type symbol_vec_t is array (natural range <>) of symbol_t;

    variable symbols : symbol_vec_t(0 to 43);

    -- Seeded random traffic with malformations, see awesome_vunit_vcs.ethernet.traffic.
    -- Below 1000 Mbit/s RGMII realigns nibbles on the SFD like MII, which expected_violations does not predict
    constant traffic_function : string := "awesome_vunit_vcs.ethernet.traffic:random_traffic";
    impure function traffic_arguments return arg_t is

      constant common : string := "bad_fcs,short_preamble,long_preamble,runt,giant,phy_error,short_ifg";
    begin

      if gigabit then
        return kwarg("count", 60)
               & kwarg("malformations", common & ",bad_sfd")
               & kwarg("malformed_fraction", 0.3)
               & kwarg("interface", "rgmii");
      end if;
      return kwarg("count", 60)
             & kwarg("malformations", common)
             & kwarg("malformed_fraction", 0.3)
             & kwarg("interface", "rgmii");
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

    -- Wait for a sampling edge like the monitors: on clk for centered data, a
    -- copy of clk would change a delta cycle later and see data that changed on
    -- the clock edge
    procedure wait_for_rising_sample is
    begin

      if edge_aligned then
        wait until rising_edge(sample_clk);
      else
        wait until rising_edge(clk);
      end if;
    end;

    procedure wait_for_falling_sample is
    begin

      if edge_aligned then
        wait until falling_edge(sample_clk);
      else
        wait until falling_edge(clk);
      end if;
    end;

    procedure wait_for_frame is
    begin

      loop

        wait_for_rising_sample;
        exit when ctl = '1';
      end loop;

    end;

    -- The symbol of one clock cycle, sampled on both edges
    procedure sample_symbol (variable symbol : out symbol_t) is
    begin

      symbol.rising_data := to_integer(unsigned(data));
      symbol.rising_ctl := ctl;
      wait_for_falling_sample;
      symbol.falling_data := to_integer(unsigned(data));
      symbol.falling_ctl := ctl;
      wait_for_rising_sample;
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));

    for idx in monitors'range loop

      disable_stop(get_logger(get_protocol_checker(monitors(idx))), error);
    end loop;

    while test_suite loop

      if run("test_edge_ordering") then
        push_checked_frame(frame_data(60));
        wait_for_frame;
        for idx in symbols'range loop

          sample_symbol(symbols(idx));
        end loop;

        for idx in symbols'range loop

          check_equal(symbols(idx).rising_ctl, '1', "Valid on the rising edge of symbol " & to_string(idx));
          check_equal(symbols(idx).falling_ctl, '1', "Valid xor error on the falling edge of symbol " & to_string(idx));
        end loop;

        if gigabit then
          -- An octet per clock cycle: the lower bits on the rising and the upper bits on the falling edge
          for idx in 0 to 6 loop

            check_equal(symbols(idx).rising_data, 16#5#, "Rising edge of preamble octet " & to_string(idx));
            check_equal(symbols(idx).falling_data, 16#5#, "Falling edge of preamble octet " & to_string(idx));
          end loop;

          check_equal(symbols(7).rising_data, 16#5#, "Rising edge of the SFD");
          check_equal(symbols(7).falling_data, 16#D#, "Falling edge of the SFD");
          check_equal(symbols(8).rising_data, 16#2#, "Rising edge of the first frame octet 0x02");
          check_equal(symbols(8).falling_data, 16#0#, "Falling edge of the first frame octet 0x02");
          check_equal(symbols(20).rising_data, 16#8#, "Rising edge of 0x88");
          check_equal(symbols(21).rising_data, 16#5#, "Rising edge of 0xB5");
          check_equal(symbols(21).falling_data, 16#B#, "Falling edge of 0xB5");
        else
          -- A nibble per clock cycle on the rising edge, least significant nibble first
          for idx in 0 to 14 loop

            check_equal(symbols(idx).rising_data, 16#5#, "Preamble nibble " & to_string(idx));
          end loop;

          check_equal(symbols(15).rising_data, 16#D#, "SFD high nibble");
          check_equal(symbols(16).rising_data, 16#2#, "Low nibble of the first frame octet");
          check_equal(symbols(17).rising_data, 16#0#, "High nibble of the first frame octet");
          check_equal(symbols(42).rising_data, 16#5#, "Low nibble of 0xB5");
          check_equal(symbols(43).rising_data, 16#B#, "High nibble of 0xB5");
        end if;
        check_violations(eth_fcs, 0);

      elsif run("test_error_is_signalled_on_the_falling_edge") then
        push_ethernet_frame(net, source, frame_data(60), frame_options(error_offsets => (0 => 20)));
        wait_for_frame;
        count := 0;
        while ctl = '1' loop

          sample_symbol(symbols(0));
          if symbols(0).rising_ctl = '1' and symbols(0).falling_ctl = '0' then
            count := count + 1;
          end if;
        end loop;

        -- One errored octet: one clock cycle at 1000 Mbit/s, the two nibbles of the octet below
        if gigabit then
          check_equal(count, 1, "Clock cycles with error");
        else
          check_equal(count, 2, "Clock cycles with error");
        end if;
        check_violations(eth_phy_error, 1);

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

  test_runner_watchdog(runner, 1_000_000 * clk_period);

  source_inst : entity awesome_vunit_vcs.rgmii_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      data => data,
      ctl => ctl
    );

  monitor_inst : entity awesome_vunit_vcs.rgmii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      data => data,
      ctl => ctl
    );

  second_monitor_inst : entity awesome_vunit_vcs.rgmii_monitor
    generic map (
      monitor => second_monitor
    )
    port map (
      clk => clk,
      data => data,
      ctl => ctl
    );

end architecture;
