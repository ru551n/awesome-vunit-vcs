-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A property on a toggle-based pulse synchronizer (toggle_synchronizer.vhd).
-- Hypothesis draws the source and destination clock periods, the destination
-- clock's phase and a handful of source-domain event cycles at least the
-- ratio-dependent legal minimum apart (cdc_strategies.py); each legal source
-- event must create exactly one destination event, within a bounded number of
-- destination cycles -- no losses, no duplicates. inject_bug swaps the toggle
-- handshake for a naive pulse synchronizer, which loses or merges events.
--
-- THIS DOES NOT MODEL ANALOG METASTABILITY. It explores digital issues: the
-- clock relationship, phase, event loss, duplicate events, reset timing and
-- synchronizer control logic, not the analog settling of a real flip-flop.

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

-- docs-start: cdc-generic
entity tb_property_cdc is
  generic (runner_cfg : string; inject_bug : boolean := false);
end entity;
-- docs-end: cdc-generic

architecture tb of tb_property_cdc is
  signal src_clk, dst_clk : std_ulogic := '0';
  signal src_rst, dst_rst : std_ulogic := '1';
  signal src_event, dst_event : std_ulogic := '0';
  signal src_period, dst_period, dst_phase : time := 10 ns;
  signal clk_enable : boolean := false;
  signal dst_count : natural := 0;
begin
  -- docs-start: cdc-clocks
  -- A clock process per domain, its period (and the destination's phase) taken
  -- from a signal set for each example; stopped cleanly between examples
  src_clk_gen : process
  begin
    loop
      wait until clk_enable;
      src_clk <= '0';
      while clk_enable loop
        wait for src_period / 2;
        src_clk <= not src_clk;
      end loop;
    end loop;
  end process;

  dst_clk_gen : process
  begin
    loop
      wait until clk_enable;
      wait for dst_phase;
      dst_clk <= '0';
      while clk_enable loop
        wait for dst_period / 2;
        dst_clk <= not dst_clk;
      end loop;
    end loop;
  end process;

  -- docs-end: cdc-clocks

  -- Count destination events; cleared by the destination-domain reset
  count_gen : process(dst_clk)
  begin
    if rising_edge(dst_clk) then
      if dst_rst = '1' then
        dst_count <= 0;
      elsif dst_event = '1' then
        dst_count <= dst_count + 1;
      end if;
    end if;
  end process;

  main : process
    variable prop : property_t;
    variable expected, prev_cycle, cycle : natural;
    variable timed_out : boolean;
    -- More than half of the largest period the strategy draws (20 ns), so both
    -- clock generators are parked at "wait until clk_enable" before it goes off
    constant clock_stop_margin : time := 21 ns;
    -- Comfortably bounds the synchronizer's 3-cycle latency plus up to one
    -- destination cycle of alignment slack between the two clock domains
    constant settle_dst_cycles : positive := 8;

    -- Hold src_event high for one source cycle
    procedure pulse_src is
    begin
      src_event <= '1';
      wait until rising_edge(src_clk);
      src_event <= '0';
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_clock_ratio_and_phase") then
        -- docs-start: cdc-property
        prop := new_property("cdc_strategies:toggle_sync", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          clk_enable <= false;
          -- Longer than any half period the strategy draws, so both clock generators are
          -- parked at "wait until clk_enable" and the new example starts from a clean clock
          wait for clock_stop_margin;
          src_rst <= '1';
          dst_rst <= '1';
          src_period <= get_integer(prop, "src_period_ps") * 1 ps;
          dst_period <= get_integer(prop, "dst_period_ps") * 1 ps;
          dst_phase <= get_integer(prop, "dst_phase_ps") * 1 ps;
          clk_enable <= true;
          -- 2 source cycles of reset: shorter than the strategy's minimum event spacing (>= 3),
          -- so it never overlaps an event
          wait until rising_edge(src_clk);
          wait until rising_edge(src_clk);
          src_rst <= '0';
          if has_field(prop, "reset_release_ps") then
            wait for get_integer(prop, "reset_release_ps") * 1 ps;
          end if;
          wait until rising_edge(dst_clk);
          dst_rst <= '0';

          expected := get_length(prop, "events");
          prev_cycle := 0;
          for idx in 0 to expected - 1 loop
            cycle := get_integer(prop, "events(" & integer'image(idx) & ")");
            -- The strategy already spaced consecutive events >= min_spacing source cycles apart
            for skip in prev_cycle + 1 to cycle loop
              wait until rising_edge(src_clk);
            end loop;
            pulse_src;
            prev_cycle := cycle;
          end loop;

          -- min_spacing = ceil(3 * dst_period / src_period) + 2 source cycles is the
          -- synchronizer's 3-cycle destination latency plus margin; 8 destination cycles
          -- comfortably covers that latency however the ratio falls
          for settle in 1 to settle_dst_cycles loop
            wait until rising_edge(dst_clk);
          end loop;
          timed_out := dst_count < expected;
          report_example(prop, passed => dst_count = expected, timed_out => timed_out, recovered => true);
        end loop;
        check_property(prop);
        -- docs-end: cdc-property
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.toggle_synchronizer
    generic map (inject_bug => inject_bug)
    port map (
      src_clk => src_clk, src_rst => src_rst, src_event => src_event,
      dst_clk => dst_clk, dst_rst => dst_rst, dst_event => dst_event
    );
end architecture;
