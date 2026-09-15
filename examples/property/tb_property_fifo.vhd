-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Occupancy targeting on a depth-8 FIFO: scoring the highest occupancy of each
-- example steers Hypothesis towards a full FIFO, where a push and a pop at once
-- loses a word when inject_bug is set. The strategy is python/fifo_strategies.py.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

entity tb_property_fifo is
  generic (runner_cfg : string; inject_bug : boolean := false);
end entity;

architecture tb of tb_property_fifo is
  signal clk, rst, push, pop, full, empty : std_ulogic := '0';
  signal data_in, data_out : std_ulogic_vector(7 downto 0) := (others => '0');
  signal count : std_ulogic_vector(3 downto 0);
begin
  clk <= not clk after 5 ns;

  main : process
    variable prop : property_t;
    -- The reference model: the words in the FIFO, oldest first
    variable model : integer_vector(0 to 7);
    variable fill, max_fill : natural;
    variable push_now, pop_now, passed : boolean;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_occupancy_targeting") then
        -- docs-start: fifo
        -- Every pop returns the oldest word and count matches the model. The score
        -- rewards examples that fill the FIFO, so full-FIFO corner cases come up often.
        prop := new_property("fifo_strategies:fifo_operations", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          rst <= '1';
          wait until rising_edge(clk);
          rst <= '0';
          fill := 0;
          max_fill := 0;
          passed := true;
          for idx in 0 to get_length(prop) - 1 loop
            push_now := get_string(prop, "(" & integer'image(idx) & ")") /= "pop";
            pop_now := get_string(prop, "(" & integer'image(idx) & ")") /= "push";
            push <= '1' when push_now else '0';
            pop <= '1' when pop_now else '0';
            data_in <= std_ulogic_vector(to_unsigned(idx, 8));
            if pop_now and fill > 0 then
              passed := passed and to_integer(unsigned(data_out)) = model(0);
            end if;
            wait until rising_edge(clk);
            wait for 1 ns;
            -- A pop needs a word, a push needs room, which a pop in the same cycle makes
            if pop_now and fill > 0 then
              model(0 to 6) := model(1 to 7);
              fill := fill - 1;
            end if;
            if push_now and fill < 8 then
              model(fill) := idx;
              fill := fill + 1;
            end if;
            passed := passed and to_integer(unsigned(count)) = fill;
            max_fill := maximum(max_fill, fill);
          end loop;
          report_score(prop, "occupancy", real(max_fill));
          report_example(prop, passed => passed);
        end loop;
        check_property(prop);
        -- docs-end: fifo
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.fifo8
    generic map (inject_bug => inject_bug)
    port map (
      clk => clk, rst => rst, push => push, pop => pop, data_in => data_in, data_out => data_out,
      full => full, empty => empty, count => count
    );
end architecture;
