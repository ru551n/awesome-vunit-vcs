-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- (e) Composite Ethernet traffic. Property: for every list of frames, each
-- with a random header, payload, gap and maybe a malformation (bad FCS, short
-- or long preamble, runt, PHY error, short gap), the protocol checker behind a
-- GMII register stage counts exactly the violations expected_violations
-- predicts. The strategy is built on the typed Python API (Frame.from_payload,
-- WireOptions.malformed). Shrinking: a mismatch is reduced to the fewest,
-- shortest frames with the simplest malformation that still shows it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;
use awesome_vunit_vcs.property_pkg.all;

entity tb_ethernet_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_ethernet_property is
  constant clk_period : time := 8 ns;

  signal clk : std_ulogic := '0';
  signal tx_data, rx_data : std_ulogic_vector(7 downto 0);
  signal tx_dv, tx_er, rx_dv, rx_er : std_ulogic;

  constant source : gmii_source_t := new_gmii_source;
  constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);
begin
  clk <= not clk after clk_period / 2;

  main : process
    type check_counts_t is array (ethernet_check_t) of natural;

    variable prop : property_t;
    variable counts_before, counts_after : check_counts_t;
    variable passed : boolean;

    impure function frame(idx : natural; name : string) return string is
    begin
      return "frames(" & integer'image(idx) & ")." & name;
    end;

    procedure get_check_counts(variable counts : out check_counts_t) is
    begin
      wait_until_idle(net, as_sync(get_protocol_checker(monitor)));
      for check in ethernet_check_t loop
        get_check_count(net, get_protocol_checker(monitor), check, counts(check));
      end loop;
    end;

    impure function expected_count(check : ethernet_check_t) return natural is
      constant path : string := "expected." & ethernet_check_t'image(check);
    begin
      if has_field(prop, path) then
        return get_integer(prop, path);
      end if;
      return 0;
    end;

    impure function fcs_of(idx : natural) return ethernet_fcs_mode_t is
    begin
      if get_string(prop, frame(idx, "fcs")) = "bad" then
        return fcs_bad;
      end if;
      return fcs_append;
    end;

    impure function options_of(idx : natural) return ethernet_frame_options_t is
    begin
      return frame_options(
        fcs => fcs_of(idx),
        pad => get_boolean(prop, frame(idx, "pad")),
        preamble_octets => get_integer(prop, frame(idx, "preamble_octets")),
        ifg_octets => get_integer(prop, frame(idx, "ifg_octets")),
        error_offsets => get_integer_vector(prop, frame(idx, "errors")));
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_checker_counts_the_generated_malformations") then
        -- docs-start: ethernet_loop
        prop := new_property("property_examples:ethernet_traffic", max_examples => 50, seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        -- The generated malformations are expected: count the violations instead of stopping
        disable_stop(get_logger(get_protocol_checker(monitor)), error);
        while next_example(prop) loop
          get_check_counts(counts_before);
          for idx in 0 to get_length(prop, "frames") - 1 loop
            push_ethernet_frame(net, source,
              get_unsigned(prop, frame(idx, "data"), 8 * get_length(prop, frame(idx, "data"))), options_of(idx));
          end loop;
          wait_until_idle(net, as_sync(source));
          wait for 40 * clk_period;  -- a gap longer than the minimum before the next example
          get_check_counts(counts_after);

          passed := true;
          for check in ethernet_check_t loop
            passed := passed and counts_after(check) - counts_before(check) = expected_count(check);
          end loop;
          report_example(prop, passed => passed);
        end loop;
        reset_log_count(get_logger(get_protocol_checker(monitor)), error);
        check_property(prop);
        -- docs-end: ethernet_loop
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 60 sec);

  source_inst : entity awesome_vunit_vcs.gmii_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      data => tx_data,
      dv => tx_dv,
      er => tx_er
    );

  dut_inst : entity work.gmii_register_stage
    port map (
      clk => clk,
      in_data => tx_data,
      in_dv => tx_dv,
      in_er => tx_er,
      out_data => rx_data,
      out_dv => rx_dv,
      out_er => rx_er
    );

  monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      data => rx_data,
      dv => rx_dv,
      er => rx_er
    );
end architecture;
