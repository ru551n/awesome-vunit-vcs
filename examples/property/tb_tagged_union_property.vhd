-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- (d) A tagged union. Property: every ALU operation gives the right result.
-- An example is one of three kinds, each with its own fields; the testbench
-- reads "kind" and then the fields of that kind. Shrinking: Hypothesis also
-- shrinks across the kinds, preferring the first alternative of the union, so
-- a failure is reported as the simplest kind that shows it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_tagged_union_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_tagged_union_property is
  signal op : std_ulogic_vector(1 downto 0) := "00";
  signal a, b : std_ulogic_vector(7 downto 0) := (others => '0');
  signal y : std_ulogic_vector(8 downto 0);

  function byte(value : natural) return std_ulogic_vector is
  begin
    return std_ulogic_vector(to_unsigned(value, 8));
  end;
begin
  main : process
    variable prop : property_t;
    variable expected : natural;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_every_alu_operation") then
        -- docs-start: tagged_union_loop
        prop := new_property("property_examples:alu_operation", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          if get_string(prop, "kind") = "add" then
            op <= "00";
            a <= byte(get_integer(prop, "a"));
            b <= byte(get_integer(prop, "b"));
            expected := get_integer(prop, "a") + get_integer(prop, "b");
          elsif get_string(prop, "kind") = "shift" then
            op <= "01";
            a <= byte(get_integer(prop, "value"));
            b <= byte(get_integer(prop, "amount"));
            expected := (get_integer(prop, "value") * 2 ** get_integer(prop, "amount")) mod 256;
          else
            op <= "10";
            a <= byte(get_integer(prop, "a"));
            b <= byte(get_integer(prop, "b"));
            expected := 1 when get_integer(prop, "a") < get_integer(prop, "b") else 0;
          end if;
          wait for 1 ns;
          report_example(prop, passed => to_integer(unsigned(y)) = expected, msg => "y=" & to_string(y));
        end loop;
        check_property(prop);
        -- docs-end: tagged_union_loop
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.mini_alu
    port map (
      op => op,
      a => a,
      b => b,
      y => y
    );
end architecture;
