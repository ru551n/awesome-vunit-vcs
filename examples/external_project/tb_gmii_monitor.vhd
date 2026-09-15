-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

library ieee;
use ieee.std_logic_1164.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

-- A GMII source drives a line that a GMII monitor observes, using only the
-- installed package: no path to its VHDL files or Python modules, and no
-- Python in the testbench.
entity tb_gmii_monitor is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_gmii_monitor is
  signal clk : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0);
  signal dv, er : std_ulogic;

  constant source : gmii_source_t := new_gmii_source;
  constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);

  -- Destination and source address, local experimental EtherType, payload
  constant frame : std_ulogic_vector := x"020000000001" & x"020000000002" & x"88B5" & x"48656C6C6F";
begin
  clk <= not clk after 4 ns;

  main : process
    variable count : natural;
    variable statistics : ethernet_statistics_t;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("test_frames_are_reconstructed_and_checked") then
        start_capture(net, monitor, output_path(runner_cfg) & "gmii.pcapng");

        check_ethernet_frame(net, monitor, frame, blocking => false);
        push_ethernet_frame(net, source, frame);
        wait_until_idle(net, as_sync(source));
        wait_until_idle(net, as_sync(monitor));

        get_statistics(net, monitor, statistics);
        check_equal(statistics.good_frames, 1);
        -- The frame is padded to the 64 octet minimum
        check_equal(statistics.min_frame_octets, 64);
        log_statistics(net, monitor);

      elsif run("test_bad_fcs_is_a_check_failure") then
        -- The violation is logged as an error on the protocol checker of the
        -- monitor; count it instead of stopping the simulation
        disable_stop(get_logger(get_protocol_checker(monitor)), error);

        push_ethernet_frame(net, source, frame, frame_options(fcs => fcs_bad));
        wait_until_idle(net, as_sync(source));
        wait_until_idle(net, as_sync(monitor));

        get_check_count(net, monitor, eth_fcs, count);
        check_equal(count, 1);
        check_equal(get_log_count(get_logger(get_protocol_checker(monitor)), error), 1);
        reset_log_count(get_logger(get_protocol_checker(monitor)), error);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);

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
end architecture;
