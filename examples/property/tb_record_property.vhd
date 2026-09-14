-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- (b) A record. Property: for every configuration (limit, step, enable) and
-- run length, the wrap counter ends where a model of it ends. The fields are
-- read by path, "config.limit". Shrinking: a failure is reduced field by
-- field, towards the smallest limit, step and number of cycles that still
-- fail.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_record_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_record_property is
  constant clk_period : time := 10 ns;

  signal clk : std_ulogic := '0';
  signal rst : std_ulogic := '1';
  signal enable : std_ulogic := '0';
  signal step : std_ulogic_vector(3 downto 0) := (others => '0');
  signal limit : std_ulogic_vector(7 downto 0) := (others => '0');
  signal count : std_ulogic_vector(7 downto 0);
begin
  clk <= not clk after clk_period / 2;

  main : process
    variable prop : property_t;
    variable expected : natural;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_counter_matches_model_for_every_config") then
        -- docs-start: record_loop
        prop := new_property("property_examples:counter_config", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          limit <= std_ulogic_vector(to_unsigned(get_integer(prop, "config.limit"), 8));
          step <= std_ulogic_vector(to_unsigned(get_integer(prop, "config.step"), 4));
          enable <= '1' when get_boolean(prop, "config.enable") else '0';
          rst <= '1';
          wait until rising_edge(clk);
          rst <= '0';

          expected := 0;
          for cycle in 1 to get_integer(prop, "cycles") loop
            wait until rising_edge(clk);
            if get_boolean(prop, "config.enable") then
              expected := (expected + get_integer(prop, "config.step")) mod (get_integer(prop, "config.limit") + 1);
            end if;
          end loop;
          wait for 1 ns;
          report_example(prop, passed => to_integer(unsigned(count)) = expected);
        end loop;
        check_property(prop);
        -- docs-end: record_loop
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.wrap_counter
    port map (
      clk => clk,
      rst => rst,
      enable => enable,
      step => step,
      limit => limit,
      count => count
    );
end architecture;
