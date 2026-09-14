-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- (f) A sequence of operations checked against a reference model. Property:
-- every read of every sequence of register writes and reads returns what the
-- Python reference model computed for it. Shrinking: with the planted bug (a
-- write to register 3 also writes register 7) Hypothesis removes and
-- simplifies operations until only the minimal failing sequence is left: a
-- nonzero write to register 3 followed by a read of register 7.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_register_sequence_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_register_sequence_property is
  constant clk_period : time := 10 ns;

  signal clk : std_ulogic := '0';
  signal rst : std_ulogic := '1';
  signal planted_bug : boolean := false;
  signal write_enable : std_ulogic := '0';
  signal address : std_ulogic_vector(2 downto 0) := (others => '0');
  signal write_data, read_data : std_ulogic_vector(7 downto 0) := (others => '0');
begin
  clk <= not clk after clk_period / 2;

  main : process
    variable prop : property_t;
    variable passed : boolean;

    -- Run every example of the property
    procedure run_sequences(max_examples : positive := 100) is
      impure function field(idx : natural; name : string) return string is
      begin
        return "(" & integer'image(idx) & ")." & name;
      end;
    begin
      -- docs-start: operations_loop
      prop := new_property("property_examples:register_operations", max_examples => max_examples,
        seed => get_seed(runner_cfg), output_path => output_path(runner_cfg),
        search_path => tb_path(runner_cfg) & "python");
      while next_example(prop) loop
        rst <= '1';
        wait until rising_edge(clk);
        rst <= '0';
        passed := true;
        for idx in 0 to get_length(prop) - 1 loop
          address <= std_ulogic_vector(to_unsigned(get_integer(prop, field(idx, "address")), 3));
          if get_string(prop, field(idx, "kind")) = "write" then
            write_data <= std_ulogic_vector(to_unsigned(get_integer(prop, field(idx, "data")), 8));
            write_enable <= '1';
            wait until rising_edge(clk);
            write_enable <= '0';
          else
            wait for 1 ns;
            passed := to_integer(unsigned(read_data)) = get_integer(prop, field(idx, "expected"));
            exit when not passed;
          end if;
        end loop;
        report_example(prop, passed => passed, msg => "operation read " & to_string(read_data));
      end loop;
      -- docs-end: operations_loop
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_register_bank_matches_the_model") then
        run_sequences;
        check_property(prop);

      elsif run("test_planted_bug_shrinks_to_minimal_sequence") then
        planted_bug <= true;
        -- The bug needs a nonzero write to register 3 before a read of register 7,
        -- so give Hypothesis enough examples to find it with any seed
        run_sequences(max_examples => 1000);
        info("Minimal failing sequence: " & get_counterexample(prop));
        check_equal(get_outcome(prop), "failed");
        -- Shrunk to a write and a read, not the up to 20 operations generated
        check_equal(
          get_counterexample(prop),
          "[{'kind': 'write', 'address': 3, 'data': 1}, {'kind': 'read', 'address': 7, 'expected': 0}]");
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.register_bank
    port map (
      clk => clk,
      rst => rst,
      planted_bug => planted_bug,
      write_enable => write_enable,
      address => address,
      write_data => write_data,
      read_data => read_data
    );
end architecture;
