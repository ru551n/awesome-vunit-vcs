-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A lockup found by a property: the stalling sink stops taking octets after
-- 0xFF, which the property reports as a timeout and shrinks to [255, 0].

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_property_lockup is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_property_lockup is
  -- docs-start: sink-signals
  signal clk, rst, valid, ready : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0) := (others => '0');
  -- docs-end: sink-signals
begin
  clk <= not clk after 5 ns;

  main : process
    -- docs-start: property-variables
    variable prop : property_t;
    variable timed_out : boolean;
    -- docs-end: property-variables
  begin
    test_runner_setup(runner, runner_cfg);
    -- docs-start: lockup
    prop := new_property("strategies:byte_stream", seed => get_seed(runner_cfg),
      output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
    while next_example(prop) loop
      timed_out := false;
      for idx in 0 to get_length(prop) - 1 loop
        data <= std_ulogic_vector(to_unsigned(get_integer(prop, "(" & integer'image(idx) & ")"), 8));
        valid <= '1';
        wait until rising_edge(clk) and ready = '1' for example_budget(10 ns, 10 ns, 1);
        valid <= '0';
        timed_out := ready /= '1';
        exit when timed_out;
      end loop;
      rst <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      wait for 1 ns;
      report_example(prop, passed => not timed_out, timed_out => timed_out, recovered => ready = '1');
    end loop;
    check_equal(get_outcome(prop), "failed");
    check_equal(get_counterexample(prop), "[255, 0]");
    -- docs-end: lockup
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.stalling_sink
    port map (clk => clk, rst => rst, valid => valid, data => data, ready => ready);
end architecture;
