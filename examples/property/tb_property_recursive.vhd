-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A property with recursive, grammar-based generation: arithmetic expression trees
-- (const | add | subtract | negate) from python/recursive_strategies.py, serialized to a
-- postfix program and fed to a stack-machine evaluator, one instruction per clock cycle.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

entity tb_property_recursive is
  generic (runner_cfg : string; inject_bug : boolean := false);
end entity;

architecture tb of tb_property_recursive is
  signal clk, rst, push : std_ulogic := '0';
  signal op : std_ulogic_vector(1 downto 0) := (others => '0');
  signal operand : std_ulogic_vector(7 downto 0) := (others => '0');
  signal result : std_ulogic_vector(7 downto 0);
begin
  clk <= not clk after 5 ns;

  main : process
    variable prop : property_t;

    -- The path of program element idx, or of a field of it
    impure function instruction(idx : natural; name : string := "") return string is
    begin
      if name = "" then
        return "program(" & integer'image(idx) & ")";
      end if;
      return "program(" & integer'image(idx) & ")." & name;
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_expressions") then
        -- docs-start: recursive
        -- The DUT's result must match the reference evaluator's expected value; a failing deep
        -- tree shrinks structurally to the smallest tree that still shows the bug
        prop := new_property("recursive_strategies:expressions", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          rst <= '1';
          wait until rising_edge(clk);
          rst <= '0';
          for idx in 0 to get_length(prop, "program") - 1 loop
            if get_string(prop, instruction(idx, "op")) = "const" then
              operand <= std_ulogic_vector(to_unsigned(get_integer(prop, instruction(idx, "value")), 8));
              op <= "00";
            elsif get_string(prop, instruction(idx, "op")) = "add" then
              op <= "01";
            elsif get_string(prop, instruction(idx, "op")) = "subtract" then
              op <= "10";
            else -- "negate"
              op <= "11";
            end if;
            push <= '1';
            wait until rising_edge(clk);
            push <= '0';
          end loop;
          wait for 1 ns;
          report_example(prop, passed => to_integer(unsigned(result)) = get_integer(prop, "expected"));
        end loop;
        check_property(prop);
        -- docs-end: recursive
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.rpn_evaluator
    generic map (inject_bug => inject_bug)
    port map (clk => clk, rst => rst, push => push, op => op, operand => operand, result => result);
end architecture;
