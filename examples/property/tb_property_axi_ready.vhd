-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Does TVALID depend on TREADY? A paired, counterfactual experiment on two copies
-- of the same AXI4-Stream source. Both copies get the same clock, reset, load and
-- data. They differ in one thing only: for exactly one cycle, the fork, copy A sees
-- TREADY low and copy B sees TREADY high. Before and after the fork both see TREADY
-- low. TVALID is low on both copies in the fork cycle, so no transfer can happen
-- there. Any later difference in TVALID is caused by that one TREADY cycle alone.
--
-- What this shows, and what it does not: on a black-box AXI4-Stream interface,
-- TREADY low with TVALID low cannot tell "no data" from "data waiting illegally
-- for TREADY". The paired experiment (test_tready_fork) shows TREADY sensitivity:
-- whether TVALID behaviour is independent of TREADY (non-interference), which is a
-- metamorphic check that needs no expected value. It does not prove AXI4-Stream
-- compliance. This toy source also has a load interface, so the testbench knows
-- when a word is pending, which gives a stronger check (test_known_pending):
-- a pending word must raise TVALID without waiting for TREADY.
--
-- The source has a planted bug behind inject_bug; examples/property/run.py turns it
-- on with AWESOME_VUNIT_VCS_EXAMPLE_BUGS=1.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

entity tb_property_axi_ready is
  generic (
    runner_cfg : string;
    -- Turn on the planted bug of the source
    inject_bug : boolean := false);
end entity;

architecture tb of tb_property_axi_ready is

  -- Room for the longest experiment the strategy draws
  constant max_cycles : positive := 16;

  signal clk : std_ulogic := '0';
  signal rst : std_ulogic := '0';
  signal load_valid : std_ulogic := '0';
  signal load_data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal tready_a, tready_b : std_ulogic := '0';
  signal load_ready_a : std_ulogic;
  signal load_ready_b : std_ulogic;
  signal tvalid_a : std_ulogic;
  signal tvalid_b : std_ulogic;
  signal tdata_a, tdata_b : std_ulogic_vector(7 downto 0);

begin

  clk <= not clk after 5 ns;

  main : process

    type history_t is record
      cycles                     : natural;
      load_ready_a, load_ready_b : std_ulogic_vector(0 to max_cycles - 1);
      tready_a, tready_b         : std_ulogic_vector(0 to max_cycles - 1);
      tvalid_a, tvalid_b         : std_ulogic_vector(0 to max_cycles - 1);
      handshake_a, handshake_b   : std_ulogic_vector(0 to max_cycles - 1);
      -- TDATA when TVALID is high, -1 when it is low
      tdata_a, tdata_b           : integer_vector(0 to max_cycles - 1);
    end record;

    variable prop : property_t;
    variable history : history_t;
    variable passed : boolean;
    variable skipped : natural;

    impure function new_fork_property return property_t is
    begin

      return new_property(
        "axi_ready_strategies:ready_fork",
        seed => get_seed(runner_cfg),
        output_path => output_path(runner_cfg),
        search_path => tb_path(runner_cfg) & "python"
      );
    end;

    -- The first bits of a history as text, for example "0110"
    function bits (value : std_ulogic_vector; cycles : natural) return string is

      variable result : string(1 to cycles);
    begin

      for cycle in 0 to cycles - 1 loop

        result(cycle + 1) := '1' when value(cycle) = '1' else
                             '0';
      end loop;

      return result;
    end;

    -- docs-start: experiment
    -- Run one experiment and record, cycle by cycle, what both copies saw at each
    -- rising edge. The inputs are the same for both copies, except TREADY in the
    -- fork cycle.
    procedure run_experiment is

      constant data : natural := get_integer(prop, "data");
      constant load_cycle : natural := get_integer(prop, "idle");
      constant fork : natural := get_integer(prop, "fork");
      constant cycles : natural := maximum(fork + 1 + get_integer(prop, "window"), load_cycle + 3);
    begin

      -- Reset both copies together
      rst <= '1';
      load_valid <= '0';
      tready_a <= '0';
      tready_b <= '0';
      wait until rising_edge(clk);
      rst <= '0';

      -- Start from an empty history, so nothing of the previous example is compared
      history := (cycles => cycles, tdata_a | tdata_b => (others => -1), others => (others => '0'));
      for cycle in 0 to cycles - 1 loop

        -- The same load for both copies
        load_valid <= '1' when cycle = load_cycle else
                      '0';
        load_data <= std_ulogic_vector(to_unsigned(data, 8));
        -- docs-start: fork
        -- TREADY: low on both copies, except high on copy B in the fork cycle
        tready_a <= '0';
        tready_b <= '1' when cycle = fork else
                    '0';
        -- docs-end: fork
        wait until rising_edge(clk);

        -- The values the copies sampled at this edge
        history.load_ready_a(cycle) := load_ready_a;
        history.load_ready_b(cycle) := load_ready_b;
        history.tready_a(cycle) := tready_a;
        history.tready_b(cycle) := tready_b;
        history.tvalid_a(cycle) := tvalid_a;
        history.tvalid_b(cycle) := tvalid_b;
        history.handshake_a(cycle) := tvalid_a and tready_a;
        history.handshake_b(cycle) := tvalid_b and tready_b;
        history.tdata_a(cycle) := to_integer(unsigned(tdata_a)) when tvalid_a = '1' else
                                  -1;
        history.tdata_b(cycle) := to_integer(unsigned(tdata_b)) when tvalid_b = '1' else
                                  -1;
      end loop;

      load_valid <= '0';
    end;

    -- docs-end: experiment

    -- The histories are identical before the fork, and TVALID is low on both
    -- copies in the fork cycle. Only then is the experiment causally clean.
    impure function precondition_holds return boolean is

      constant fork : natural := get_integer(prop, "fork");
    begin

      for cycle in 0 to fork - 1 loop

        if history.load_ready_a(cycle) /= history.load_ready_b(cycle)
           or history.tvalid_a(cycle) /= history.tvalid_b(cycle)
           or history.handshake_a(cycle) /= history.handshake_b(cycle)
           or history.tdata_a(cycle) /= history.tdata_b(cycle) then
          return false;
        end if;
      end loop;

      return history.tvalid_a(fork) = '0' and history.tvalid_b(fork) = '0';
    end;

    -- The stimulus is what the experiment says it is: TREADY differs in the fork
    -- cycle only, and no transfer happens in the fork cycle
    procedure check_stimulus is

      constant fork : natural := get_integer(prop, "fork");
      variable expected_tready_b : std_ulogic;
    begin

      for cycle in 0 to history.cycles - 1 loop

        check_equal(history.tready_a(cycle), '0', "TREADY A in cycle " & integer'image(cycle));
        expected_tready_b := '1' when cycle = fork else
                             '0';
        check_equal(history.tready_b(cycle), expected_tready_b, "TREADY B in cycle " & integer'image(cycle));
      end loop;

      check_equal(history.handshake_a(fork), '0', "No transfer on A in the fork cycle");
      check_equal(history.handshake_b(fork), '0', "No transfer on B in the fork cycle");
    end;

    -- The first cycle where the copies differ, or "none"
    impure function first_divergence return string is
    begin

      for cycle in 0 to history.cycles - 1 loop

        if history.tvalid_a(cycle) /= history.tvalid_b(cycle)
           or history.tdata_a(cycle) /= history.tdata_b(cycle)
           or history.handshake_a(cycle) /= history.handshake_b(cycle) then
          return integer'image(cycle);
        end if;
      end loop;

      return "none";
    end;

    -- Everything recorded, for the failure message
    impure function describe return string is

      constant cycles : natural := history.cycles;
    begin

      return "loaded data "
             & integer'image(get_integer(prop, "data"))
             & ", setup cycles "
             & integer'image(get_integer(prop, "idle"))
             & ", fork cycle "
             & integer'image(get_integer(prop, "fork"))
             & " ("
             & get_string(prop, "case")
             & ")"
             & ", READY_A "
             & bits(history.tready_a, cycles)
             & ", READY_B "
             & bits(history.tready_b, cycles)
             & ", VALID_A "
             & bits(history.tvalid_a, cycles)
             & ", VALID_B "
             & bits(history.tvalid_b, cycles)
             & ", handshakes A "
             & bits(history.handshake_a, cycles)
             & " B "
             & bits(history.handshake_b, cycles)
             & ", first divergence "
             & first_divergence;
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    while test_suite loop

      skipped := 0;
      prop := new_fork_property;

      if run("test_tready_fork") then
        -- docs-start: tready-fork
        -- Generic check, no expected value: one cycle of TREADY must not change TVALID
        while next_example(prop) loop

          run_experiment;
          if not precondition_holds then
            skipped := skipped + 1;
            report_example(prop, passed => true, msg => "precondition not met: skipped");
          else
            check_stimulus;
            passed := history.tvalid_a = history.tvalid_b
                      and history.tdata_a = history.tdata_b
                      and history.handshake_a = history.handshake_b;
            report_example(prop, passed => passed, msg => describe);
          end if;
        end loop;

      -- docs-end: tready-fork

      elsif run("test_known_pending") then
        -- docs-start: known-pending
        -- Strong check: the testbench knows a word is pending, so TVALID must rise one
        -- cycle after the load on both copies, whatever TREADY does
        while next_example(prop) loop

          run_experiment;
          if not precondition_holds then
            skipped := skipped + 1;
            report_example(prop, passed => true, msg => "precondition not met: skipped");
          else
            check_stimulus;
            passed := true;
            for cycle in get_integer(prop, "idle") + 2 to history.cycles - 1 loop

              passed := passed
                        and history.tvalid_a(cycle) = '1'
                        and history.tvalid_b(cycle) = '1'
                        and history.tdata_a(cycle) = get_integer(prop, "data")
                        and history.tdata_b(cycle) = get_integer(prop, "data");
            end loop;

            check_equal(history.load_ready_a(get_integer(prop, "idle")), '1', "The load is taken");
            report_example(prop, passed => passed, msg => describe);
          end if;
        end loop;

      -- docs-end: known-pending
      end if;

      info("Examples skipped because the precondition did not hold: " & integer'image(skipped));
      check_equal(skipped, 0, "The strategy draws only causally clean experiments");
      check_property(prop);
    end loop;

    test_runner_cleanup(runner);
  end process;

  source_a_inst : entity work.axis_word_source
    generic map (
      inject_bug => inject_bug
    )
    port map (
      clk => clk,
      rst => rst,
      load_valid => load_valid,
      load_data => load_data,
      load_ready => load_ready_a,
      m_axis_tvalid => tvalid_a,
      m_axis_tready => tready_a,
      m_axis_tdata => tdata_a
    );

  source_b_inst : entity work.axis_word_source
    generic map (
      inject_bug => inject_bug
    )
    port map (
      clk => clk,
      rst => rst,
      load_valid => load_valid,
      load_data => load_data,
      load_ready => load_ready_b,
      m_axis_tvalid => tvalid_b,
      m_axis_tready => tready_b,
      m_axis_tdata => tdata_b
    );

end architecture;
