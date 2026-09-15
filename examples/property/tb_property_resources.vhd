-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A stateful property of a 4-slot handle table, where Hypothesis tracks the
-- object identity of each live handle through a Bundle. The strategy is in
-- python/resources_strategies.py.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

entity tb_property_resources is
  generic (runner_cfg : string; inject_bug : boolean := false);
end entity;

architecture tb of tb_property_resources is
  signal clk, rst, allocate, release_handle, write_enable, allocated : std_ulogic := '0';
  signal handle, allocated_handle : std_ulogic_vector(1 downto 0) := (others => '0');
  signal write_data, read_data : std_ulogic_vector(7 downto 0) := (others => '0');
begin
  clk <= not clk after 5 ns;

  main : process
    variable prop : property_t;

    -- Hold a signal high for one clock cycle
    procedure pulse(signal value : out std_ulogic) is
    begin
      value <= '1';
      wait until rising_edge(clk);
      value <= '0';
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_resources") then
        -- docs-start: resources
        prop := new_property("resources_strategies:resources", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          if get_rule(prop) = "start" then
            pulse(rst);
            report_step(prop, value => 0);
          elsif get_rule(prop) = "allocate" then
            pulse(allocate);
            wait for 1 ns;
            if allocated = '1' then
              report_step(prop, value => to_integer(unsigned(allocated_handle)));
            else
              report_step(prop, value => -1);
            end if;
          elsif get_rule(prop) = "write" then
            handle <= std_ulogic_vector(to_unsigned(get_integer(prop, "handle"), 2));
            write_data <= std_ulogic_vector(to_unsigned(get_integer(prop, "value"), 8));
            pulse(write_enable);
            report_step(prop, value => 0);
          elsif get_rule(prop) = "read" then
            handle <= std_ulogic_vector(to_unsigned(get_integer(prop, "handle"), 2));
            wait for 1 ns;
            report_step(prop, value => to_integer(unsigned(read_data)));
          else
            handle <= std_ulogic_vector(to_unsigned(get_integer(prop, "handle"), 2));
            pulse(release_handle);
            report_step(prop, value => 0);
          end if;
        end loop;
        check_property(prop);
        -- docs-end: resources
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut : entity work.handle_table
    generic map (inject_bug => inject_bug)
    port map (
      clk => clk, rst => rst, allocate => allocate, release_handle => release_handle, write_enable => write_enable,
      handle => handle, write_data => write_data, read_data => read_data,
      allocated_handle => allocated_handle, allocated => allocated
    );
end architecture;
