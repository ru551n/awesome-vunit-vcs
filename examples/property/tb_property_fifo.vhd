-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Targeted (feedback-directed) property search on a depth-4 FIFO's occupancy.
-- Hypothesis draws a bounded sequence of push/pop operations; report_score
-- steers the search towards full, wraparound and simultaneous push+pop near
-- full, which a plain random search rarely reaches on its own. A VHDL-side
-- reference model checks no loss, no duplication, correct order and legal
-- occupancy against the DUT, which plants a bug behind inject_bug.

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
  signal count : std_ulogic_vector(2 downto 0);
begin
  clk <= not clk after 5 ns;

  main : process
    variable prop : property_t;

    -- A software reference FIFO with the DUT's correct (unbugged) semantics,
    -- used to check the DUT and to compute the metrics that steer the search.
    type mem_t is array (0 to 3) of natural;
    variable mem : mem_t := (others => 0);
    variable wr, rd, fill, max_fill, wraps, boundary : natural := 0;
    variable ok, reached_full : boolean := true;

    -- The path of field "name" of list element idx, "(2).push"
    impure function item(idx : natural; name : string) return string is
    begin
      return "(" & integer'image(idx) & ")." & name;
    end;

    -- Drive one operation, advance the reference model and check the DUT
    procedure step(push_v, pop_v : boolean; data_v : natural) is
      variable was_full, was_empty, was_near_full, popped : boolean;
      variable head, expect, wr0, rd0 : natural;
    begin
      was_full := fill = 4;
      was_empty := fill = 0;
      was_near_full := fill >= 3;
      head := to_integer(unsigned(data_out));
      wr0 := wr;
      rd0 := rd;
      push <= '1' when push_v else '0';
      pop <= '1' when pop_v else '0';
      data_in <= std_ulogic_vector(to_unsigned(data_v, 8));
      wait until rising_edge(clk);
      wait for 1 ns;
      popped := false;
      if push_v and pop_v and was_empty then
        mem(wr) := data_v; wr := (wr + 1) mod 4; fill := fill + 1;
      elsif push_v and pop_v then
        popped := true; expect := mem(rd);
        mem(wr) := data_v; wr := (wr + 1) mod 4; rd := (rd + 1) mod 4;
      elsif push_v and not was_full then
        mem(wr) := data_v; wr := (wr + 1) mod 4; fill := fill + 1;
      elsif pop_v and not was_empty then
        popped := true; expect := mem(rd);
        rd := (rd + 1) mod 4; fill := fill - 1;
      end if;
      if push_v and pop_v and was_near_full then
        boundary := boundary + 1;
      end if;
      if (wr0 = 3 and wr = 0) or (rd0 = 3 and rd = 0) then
        wraps := wraps + 1;
      end if;
      if fill > max_fill then max_fill := fill; end if;
      if fill = 4 then reached_full := true; end if;
      ok := ok and (not popped or head = expect);
      ok := ok and to_integer(unsigned(count)) = fill;
      ok := ok and (full = '1') = (fill = 4) and (empty = '1') = (fill = 0);
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_occupancy_targeting") then
        -- docs-start: fifo
        prop := new_property("fifo_strategies:operations", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          rst <= '1';
          wait until rising_edge(clk);
          rst <= '0';
          wait for 1 ns;
          wr := 0; rd := 0; fill := 0; max_fill := 0; wraps := 0; boundary := 0;
          ok := true; reached_full := false;
          for idx in 0 to get_length(prop) - 1 loop
            step(push_v => get_boolean(prop, item(idx, "push")), pop_v => get_boolean(prop, item(idx, "pop")),
              data_v => get_integer(prop, item(idx, "data")));
          end loop;
          -- Steer Hypothesis towards deep occupancy and boundary operations
          report_score(prop, "max_occupancy", real(max_fill));
          report_score(prop, "boundary_events", real(boundary * 3 + wraps * 2 + boolean'pos(reached_full)));
          report_example(prop, passed => ok);
        end loop;
        check_property(prop);
        -- docs-end: fifo
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.fifo4
    generic map (inject_bug => inject_bug)
    port map (
      clk => clk, rst => rst, push => push, pop => pop, data_in => data_in, data_out => data_out,
      full => full, empty => empty, count => count
    );
end architecture;
