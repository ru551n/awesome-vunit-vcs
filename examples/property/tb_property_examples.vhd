-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Property-based testing examples, one test case each, on an ALU and a
-- register bank. The strategies are in python/strategies.py.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

use work.example_records_pkg.all;

entity tb_property_examples is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_property_examples is
  signal clk, rst, subtract, write_enable : std_ulogic := '0';
  signal a, b, write_data, read_data, buggy_read_data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal address : std_ulogic_vector(2 downto 0) := (others => '0');
  signal y : std_ulogic_vector(8 downto 0);
begin
  clk <= not clk after 5 ns;

  main : process
    variable prop : property_t;
    variable pair : pair_t;
    variable sum : std_ulogic_vector(8 downto 0);
    variable passed : boolean;

    impure function new_example(strategy : string) return property_t is
    begin
      return new_property("strategies:" & strategy, seed => get_seed(runner_cfg),
        output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
    end;

    -- Put operands on the ALU and let it settle
    procedure apply(a_value, b_value : natural; subtract_value : std_ulogic := '0') is
    begin
      a <= std_ulogic_vector(to_unsigned(a_value, 8));
      b <= std_ulogic_vector(to_unsigned(b_value, 8));
      subtract <= subtract_value;
      wait for 1 ns;
    end;

    -- Hold a signal high for one clock cycle
    procedure pulse(signal value : out std_ulogic) is
    begin
      value <= '1';
      wait until rising_edge(clk);
      value <= '0';
    end;

    impure function item(idx : natural; name : string := "") return string is
    begin
      if name = "" then
        return "(" & integer'image(idx) & ")";
      end if;
      return "(" & integer'image(idx) & ")." & name;
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_scalar") then
        -- docs-start: scalar
        -- Every octet minus itself is 0
        prop := new_example("scalar");
        while next_example(prop) loop
          apply(get_integer(prop), get_integer(prop), subtract_value => '1');
          report_example(prop, passed => to_integer(unsigned(y)) = 0);
        end loop;
        -- docs-end: scalar

      elsif run("test_composite") then
        -- docs-start: composite
        -- The offset of the record is added to every value of its list
        prop := new_example("composite");
        while next_example(prop) loop
          passed := true;
          for idx in 0 to get_length(prop, "values") - 1 loop
            apply(get_integer(prop, "values" & item(idx)), get_integer(prop, "offset"));
            passed := passed and to_integer(unsigned(y)) = get_integer(prop, "values" & item(idx)) + get_integer(prop, "offset");
          end loop;
          report_example(prop, passed => passed);
        end loop;
        -- docs-end: composite

      elsif run("test_tagged_union") then
        -- docs-start: tagged_union
        -- Each kind of operation, with fields of its own, gives its result
        prop := new_example("tagged_union");
        while next_example(prop) loop
          if get_string(prop, "kind") = "add" then
            apply(get_integer(prop, "a"), get_integer(prop, "b"));
            passed := to_integer(unsigned(y)) = get_integer(prop, "a") + get_integer(prop, "b");
          else
            apply(0, get_integer(prop, "value"), subtract_value => '1');
            passed := to_integer(unsigned(y)) = (512 - get_integer(prop, "value")) mod 512;
          end if;
          report_example(prop, passed => passed);
        end loop;
        -- docs-end: tagged_union

      elsif run("test_stateful") then
        -- docs-start: stateful
        -- Every read returns the last write, checked by the Python model. The
        -- register bank loses writes to address 5, and Hypothesis shrinks the
        -- failure to the shortest sequence of steps showing it.
        prop := new_example("registers");
        while next_example(prop) loop
          if get_rule(prop) = "start" then
            pulse(rst);
          else
            address <= std_ulogic_vector(to_unsigned(get_integer(prop, "address"), 3));
            if get_rule(prop) = "write" then
              write_data <= std_ulogic_vector(to_unsigned(get_integer(prop, "data"), 8));
              pulse(write_enable);
            end if;
            wait for 1 ns;
          end if;
          report_step(prop, value => to_integer(unsigned(buggy_read_data)));
        end loop;
        check_equal(get_counterexample(prop), "write(address=5, data=1); read(address=5)");
        -- docs-end: stateful

      elsif run("test_generated_record") then
        -- docs-start: generated_record
        -- The operands of a record generated from a Python dataclass are added
        prop := new_example("pair");
        while next_example(prop) loop
          pair := get_pair(prop);
          apply(pair.a, pair.b);
          report_example(prop, passed => to_integer(unsigned(y)) = pair.a + pair.b, msg => to_string(pair));
        end loop;
        -- docs-end: generated_record

      elsif run("test_score") then
        -- docs-start: score
        -- The carry is set exactly when the sum overflows. Scoring the sum steers
        -- Hypothesis towards large sums, where the carry changes.
        prop := new_example("pair");
        while next_example(prop) loop
          pair := get_pair(prop);
          apply(pair.a, pair.b);
          report_score(prop, "sum", real(pair.a + pair.b));
          report_example(prop, passed => (y(8) = '1') = (pair.a + pair.b > 255));
        end loop;
        -- docs-end: score

      elsif run("test_metamorphic") then
        -- docs-start: metamorphic
        -- Swapping the operands does not change the sum: no expected value needed
        prop := new_example("pair");
        while next_example(prop) loop
          pair := get_pair(prop);
          apply(pair.a, pair.b);
          sum := y;
          apply(pair.b, pair.a);
          report_example(prop, passed => y = sum);
        end loop;
        -- docs-end: metamorphic

      elsif run("test_timing") then
        -- docs-start: timing
        -- Writes read back whatever the idle cycles between them are
        prop := new_example("timed_writes");
        while next_example(prop) loop
          pulse(rst);
          for idx in 0 to get_length(prop, "data") - 1 loop
            for cycle in 1 to get_integer(prop, "idle" & item(idx)) loop
              wait until rising_edge(clk);
            end loop;
            address <= std_ulogic_vector(to_unsigned(idx, 3));
            write_data <= std_ulogic_vector(to_unsigned(get_integer(prop, "data" & item(idx)), 8));
            pulse(write_enable);
          end loop;
          passed := true;
          for idx in 0 to get_length(prop, "data") - 1 loop
            address <= std_ulogic_vector(to_unsigned(idx, 3));
            wait for 1 ns;
            passed := passed and to_integer(unsigned(read_data)) = get_integer(prop, "data" & item(idx));
          end loop;
          report_example(prop, passed => passed);
        end loop;
        -- docs-end: timing

      elsif run("test_swarm") then
        -- docs-start: swarm
        -- Additions and subtractions, with a random subset of them enabled per example
        prop := new_example("swarm");
        while next_example(prop) loop
          passed := true;
          for idx in 0 to get_length(prop) - 1 loop
            if get_string(prop, item(idx, "kind")) = "add" then
              apply(get_integer(prop, item(idx, "a")), get_integer(prop, item(idx, "b")));
              passed := passed and to_integer(unsigned(y)) = get_integer(prop, item(idx, "a")) + get_integer(prop, item(idx, "b"));
            else
              apply(get_integer(prop, item(idx, "a")), get_integer(prop, item(idx, "b")), subtract_value => '1');
              passed := passed and to_integer(unsigned(y)) = (512 + get_integer(prop, item(idx, "a")) - get_integer(prop, item(idx, "b"))) mod 512;
            end if;
          end loop;
          report_example(prop, passed => passed);
        end loop;
        -- docs-end: swarm
      end if;

      if running_test_case /= "test_stateful" then
        check_property(prop);
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  alu_inst : entity work.alu
    port map (a => a, b => b, subtract => subtract, y => y);

  register_bank_inst : entity work.register_bank
    port map (
      clk => clk, rst => rst, write_enable => write_enable, address => address, write_data => write_data,
      read_data => read_data
    );

  buggy_register_bank_inst : entity work.register_bank
    generic map (stuck_address => 5)
    port map (
      clk => clk, rst => rst, write_enable => write_enable, address => address, write_data => write_data,
      read_data => buggy_read_data
    );
end architecture;
