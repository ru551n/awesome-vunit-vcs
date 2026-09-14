-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Bridge overhead of the GMII monitor for different batch sizes. A source
-- sends the same traffic in every configuration (see run.py); the monitor
-- transfers it to Python with one call per sample, one call per frame or one
-- call per batch_length samples. Without a monitor it measures the source and
-- the simulation alone. Wall clock time is measured in Python and logged.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;

library python_bridge;
context python_bridge.python_context;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_bridge_benchmark is
  generic (
    runner_cfg : string;
    config_name : string := "batched";
    with_monitor : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := false;
    num_frames : positive := 200;
    frame_octets : positive := 1500
  );
end entity;

architecture tb of tb_bridge_benchmark is
  constant clk_period : time := 8 ns;

  signal clk : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0);
  signal dv, er : std_ulogic;

  constant source : ethernet_source_t := new_gmii_source;
  constant monitor : ethernet_monitor_t := new_gmii_monitor(
    batch_length => batch_length, flush_at_frame_end => flush_at_frame_end
  );
begin
  clk <= not clk after clk_period / 2;

  main : process
    constant timer : python_session_t := new_session("tb_bridge_benchmark:timer");
    variable frame : std_ulogic_vector(0 to 8 * frame_octets - 1);
    variable frames : natural;
  begin
    test_runner_setup(runner, runner_cfg);

    for idx in 0 to frame_octets - 1 loop
      frame(8 * idx to 8 * idx + 7) := std_ulogic_vector(to_unsigned(idx mod 256, 8));
    end loop;

    exec("import time" & LF & "start = time.perf_counter()", timer);
    for idx in 1 to num_frames loop
      send_ethernet_frame(net, source, frame);
    end loop;
    wait_until_idle(net, as_sync(source));
    if with_monitor then
      wait_until_idle(net, as_sync(monitor));
      get_frame_count(net, monitor, frames);
      check_equal(frames, num_frames);
    end if;
    info(
      "BENCHMARK " & config_name & " frames=" & to_string(num_frames) & " octets=" & to_string(frame_octets) &
      " seconds=" & eval_string("f'{time.perf_counter() - start:.4f}'", timer)
    );

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 ms);

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

  monitor_gen : if with_monitor generate
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
  end generate;
end architecture;
