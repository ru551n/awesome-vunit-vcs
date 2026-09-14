-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- (f) with records. The same property as tb_register_sequence_property, with
-- the operations defined as Python dataclasses: run.py generates
-- register_records_pkg from them, and get_operation_sequence reads a whole
-- sequence into a VHDL record. Shrinking: with the planted bug the sequence
-- shrinks to a store of 1 into register 3 followed by a fetch of register 7.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

use work.register_records_pkg.all;

entity tb_register_records_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_register_records_property is
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

    procedure run_sequences(max_examples : positive := 100) is
      variable seq : operation_sequence_t;
      variable operation : operation_t;
      variable passed : boolean;
    begin
      -- docs-start: register_records_loop
      prop := new_property("register_records:register_operation_records", max_examples => max_examples,
        seed => get_seed(runner_cfg), output_path => output_path(runner_cfg),
        search_path => tb_path(runner_cfg) & "python");
      while next_example(prop) loop
        seq := get_operation_sequence(prop);
        rst <= '1';
        wait until rising_edge(clk);
        rst <= '0';
        passed := true;
        for idx in 0 to seq.operations_length - 1 loop
          operation := seq.operations(idx);
          address <= std_ulogic_vector(to_unsigned(operation.address, 3));
          if operation.kind = store then
            write_data <= std_ulogic_vector(to_unsigned(operation.data, 8));
            write_enable <= '1';
            wait until rising_edge(clk);
            write_enable <= '0';
          else
            wait for 1 ns;
            passed := to_integer(unsigned(read_data)) = operation.expected;
            exit when not passed;
          end if;
        end loop;
        report_example(prop, passed => passed, msg => to_string(seq));
      end loop;
      -- docs-end: register_records_loop
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_register_bank_matches_the_model") then
        run_sequences;
        check_property(prop);

      elsif run("test_planted_bug_shrinks_to_minimal_sequence") then
        planted_bug <= true;
        run_sequences(max_examples => 1000);
        info("Minimal failing sequence: " & get_counterexample(prop));
        check_equal(get_outcome(prop), "failed");
        check_equal(
          get_counterexample(prop),
          "OperationSequence(operations=[Operation(kind=<Kind.STORE: 1>, address=3, data=1, expected=None), " &
          "Operation(kind=<Kind.FETCH: 0>, address=7, data=0, expected=0)])");
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
