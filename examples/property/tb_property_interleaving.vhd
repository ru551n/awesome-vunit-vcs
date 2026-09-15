-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A property-based test of a two-client arbiter: Hypothesis draws a concurrent
-- event schedule of requests, cancels and releases, several possibly on the
-- same cycle, and VHDL replays it clock-accurately, checking mutual exclusion
-- and grant integrity every cycle. The strategy is interleaving_strategies.py.

library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

entity tb_property_interleaving is
  generic (runner_cfg : string; inject_bug : boolean := false);
end entity;

architecture tb of tb_property_interleaving is
  signal clk, rst, request_a, request_b, grant_a, grant_b : std_ulogic := '0';
begin
  clk <= not clk after 5 ns;

  main : process
    variable prop : property_t;
    variable num_events : natural;
    variable passed, held_a, held_b : boolean;

    -- The path of a field of event idx, "events(2).cycle"
    impure function event(idx : natural; name : string) return string is
    begin
      return "events(" & integer'image(idx) & ")." & name;
    end;

    -- "cycle 0: A request, cycle 1: A cancel, ..." for the current example, in cycle order
    -- (the events themselves are unsorted, for Hypothesis to shrink freely)
    impure function describe_schedule return string is
      variable result : line;
      variable first : boolean := true;
    begin
      for cycle in 0 to 7 loop
        for idx in 0 to num_events - 1 loop
          if get_integer(prop, event(idx, "cycle")) = cycle then
            if not first then
              write(result, string'(", "));
            end if;
            first := false;
            write(result, string'("cycle " & integer'image(cycle) & ": " &
              get_string(prop, event(idx, "actor")) & " " & get_string(prop, event(idx, "action"))));
          end if;
        end loop;
      end loop;
      if result = null then
        return "";
      end if;
      return result.all;
    end;

    -- Apply cycle's events: a request goes high on "request", low on "cancel" or "release"
    procedure apply(cycle : natural) is
    begin
      for idx in 0 to num_events - 1 loop
        if get_integer(prop, event(idx, "cycle")) = cycle then
          if get_string(prop, event(idx, "actor")) = "A" then
            request_a <= '1' when get_string(prop, event(idx, "action")) = "request" else '0';
          else
            request_b <= '1' when get_string(prop, event(idx, "action")) = "request" else '0';
          end if;
        end if;
      end loop;
    end;

    -- Fail the example, once, with the schedule and the failing cycle in the message
    procedure verify(ok : boolean; cycle : natural; text : string) is
    begin
      if passed and not ok then
        passed := false;
        report_example(prop, passed => false,
          msg => describe_schedule & " -- cycle " & integer'image(cycle) & ": " & text);
      end if;
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_interleaving") then
        -- docs-start: interleaving
        -- Requests, cancels and releases on overlapping cycles never violate mutual
        -- exclusion or drop a still-requesting client's grant. inject_bug grants a
        -- request on the same cycle the other client releases, so both are held.
        prop := new_property("interleaving_strategies:interleaving", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          rst <= '1';
          request_a <= '0';
          request_b <= '0';
          wait until rising_edge(clk);
          rst <= '0';
          held_a := false;
          held_b := false;
          passed := true;
          num_events := get_length(prop, "events");
          for cycle in 0 to 7 loop
            apply(cycle);
            wait until rising_edge(clk);
            wait for 1 ns;
            verify(not (grant_a = '1' and grant_b = '1'), cycle, "both grant_a and grant_b are 1");
            verify(not (grant_a = '1' and request_a = '0'), cycle, "grant_a is asserted though request_a is 0");
            verify(not (grant_b = '1' and request_b = '0'), cycle, "grant_b is asserted though request_b is 0");
            verify(not (held_a and request_a = '1' and grant_a = '0'), cycle, "grant_a dropped though A still requests");
            verify(not (held_b and request_b = '1' and grant_b = '0'), cycle, "grant_b dropped though B still requests");
            held_a := grant_a = '1';
            held_b := grant_b = '1';
            exit when not passed;
          end loop;
          if passed then
            report_example(prop, passed => true);
          end if;
        end loop;
        check_property(prop);
        -- docs-end: interleaving
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut : entity work.arbiter2
    generic map (inject_bug => inject_bug)
    port map (
      clk => clk, rst => rst, request_a => request_a, request_b => request_b, grant_a => grant_a, grant_b => grant_b
    );
end architecture;
