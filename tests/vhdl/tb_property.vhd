-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Tests of property_pkg: shrinking, flaky designs, seeds, lockups and
-- composite examples. The strategies are in python/property_strategies.py.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_property is
  constant clk_period : time := 10 ns;

  signal clk : std_ulogic := '0';
  signal rst : std_ulogic := '1';
  signal reset_works : boolean := true;
  signal data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal valid : std_ulogic := '0';
  signal ready : std_ulogic;
begin
  clk <= not clk after clk_period / 2;

  main : process
    variable prop : property_t;
    variable payload : integer_vector(0 to 15);
    variable length : natural;
    variable accepted : boolean;
    variable failures : natural;
    variable checksum : integer_vector(1 to 2);

    impure function new_test_property(strategy : string; seed : string := "") return property_t is
    begin
      if seed = "" then
        return new_property(
          "property_strategies:" & strategy, max_examples => 300, seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
      end if;
      return new_property(
        "property_strategies:" & strategy, max_examples => 300, seed => seed,
        search_path => tb_path(runner_cfg) & "python");
    end;

    impure function vector_length(path : string) return natural is
      constant values : integer_vector := get_integer_vector(prop, path);
    begin
      return values'length;
    end;

    impure function string_length(path : string) return natural is
      constant value : string := get_string(prop, path);
    begin
      return value'length;
    end;

    -- The planted bug of the design model: three or more bytes starting at 0x40 or above
    impure function model_passes return boolean is
      constant bytes : integer_vector := get_integer_vector(prop);
    begin
      return not (bytes'length >= 3 and bytes(0) >= 16#40#);
    end;

    procedure reset_dut is
    begin
      valid <= '0';
      rst <= '1';
      wait for 3 * clk_period;
      rst <= '0';
      wait until rising_edge(clk);
    end;

    -- Push the bytes of the example into the lockup DUT, each within a budget
    procedure push_example(variable done : out boolean) is
      constant bytes : integer_vector := get_integer_vector(prop);
    begin
      done := true;
      for idx in bytes'range loop
        data <= std_ulogic_vector(to_unsigned(bytes(idx), 8));
        valid <= '1';
        wait until rising_edge(clk) and ready = '1' for 3 * clk_period;
        valid <= '0';
        if ready /= '1' or clk /= '1' then
          done := false;
          return;
        end if;
      end loop;
      -- The DUT must be ready again after the last byte
      wait until rising_edge(clk);
      if ready /= '1' then
        wait until ready = '1' for example_budget(2 * clk_period, clk_period, bytes'length);
        done := ready = '1';
      end if;
    end;

    procedure run_lockup_property is
      variable done : boolean;
    begin
      prop := new_test_property("lockup_payloads");
      reset_dut;
      while next_example(prop) loop
        push_example(done);
        reset_dut;
        report_example(prop, passed => done, timed_out => not done, recovered => ready = '1');
      end loop;
    end;

    -- A strategy with a bug is one failure on the logger given to new_property,
    -- the outcome error, and nothing else
    procedure check_strategy_error(strategy : string) is
      constant logger : logger_t := get_logger("tb_property:strategy_error:" & strategy);
    begin
      disable_stop(logger, failure);
      prop := new_property(
        "property_strategies:" & strategy, seed => get_seed(runner_cfg),
        search_path => tb_path(runner_cfg) & "python", logger => logger);
      while next_example(prop) loop
        report_example(prop, passed => true);
      end loop;
      check_equal(get_outcome(prop), "error", "outcome of " & strategy);
      check_property(prop);
      check_equal(get_log_count(logger, failure), 1, "failures logged for " & strategy);
      check_equal(get_log_count(logger, error), 0, "errors logged for " & strategy);
      check_equal(get_log_count(get_logger(get_id(prop)), failure), 0, "failures on the id of " & strategy);
      reset_log_count(logger, failure);
    end;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      reset_works <= true;

      if run("test_passing_property_passes") then
        prop := new_test_property("payloads");
        while next_example(prop) loop
          wait for 1 ns;
          report_example(prop, passed => true);
        end loop;
        check_property(prop);
        check_equal(get_outcome(prop), "passed");
        check_equal(get_example_count(prop), 300);

      elsif run("test_failure_shrinks_to_minimal_counterexample") then
        prop := new_test_property("payloads");
        while next_example(prop) loop
          wait for 1 ns;
          report_example(prop, passed => model_passes, msg => "payload rejected");
        end loop;
        check_equal(get_outcome(prop), "failed");
        check_equal(get_counterexample(prop), "[64, 0, 0]");

        disable_stop(get_logger(prop), error);
        check_property(prop);
        check_equal(get_log_count(get_logger(prop), error), 1, "check_property reports the failure");
        reset_log_count(get_logger(prop), error);

      elsif run("test_flaky_design_is_reported") then
        prop := new_test_property("payloads");
        failures := 0;
        while next_example(prop) loop
          if model_passes then
            report_example(prop, passed => true);
          else
            -- State kept between examples: only the first failing example fails
            failures := failures + 1;
            report_example(prop, passed => failures /= 1);
          end if;
        end loop;
        check_equal(get_outcome(prop), "flaky");

      elsif run("test_same_seed_gives_same_examples") then
        for attempt in checksum'range loop
          prop := new_test_property("payloads", seed => "fixed seed");
          checksum(attempt) := 0;
          while next_example(prop) loop
            length := get_length(prop);
            checksum(attempt) := (checksum(attempt) * 31 + length) mod 1000003;
            if length > 0 then
              checksum(attempt) := (checksum(attempt) + get_integer(prop, "(0)")) mod 1000003;
            end if;
            report_example(prop, passed => true);
          end loop;
        end loop;
        check_equal(checksum(1), checksum(2));

      elsif run("test_lockup_is_a_failure_that_shrinks") then
        run_lockup_property;
        check_equal(get_outcome(prop), "failed");
        check_equal(get_counterexample(prop), "[240, 0]");

      elsif run("test_unrecovered_lockup_aborts") then
        reset_works <= false;
        run_lockup_property;
        check_equal(get_outcome(prop), "aborted");
        check(get_counterexample(prop) /= "", "The smallest failing example is kept");

      elsif run("test_scores_reach_hypothesis") then
        prop := new_test_property("payloads");
        while next_example(prop) loop
          report_score(prop, "length", real(get_length(prop)));
          report_example(prop, passed => true);
        end loop;
        check_property(prop);

      elsif run("test_composite_fields") then
        prop := new_test_property("composite");
        while next_example(prop) loop
          check(get_integer(prop, "config.lanes") = 4 or get_integer(prop, "config.lanes") = 8);
          length := get_length(prop, "frames");
          check(length >= 1 and length <= 3);
          check_equal(
            vector_length("frames(" & integer'image(length - 1) & ").payload"),
            get_length(prop, "frames(" & integer'image(length - 1) & ").payload"));
          check(string_length("frames(0).name") <= 3);
          if has_field(prop, "vlan") then
            check(get_integer(prop, "vlan") >= 1);
            check_equal(
              get_unsigned(prop, "vlan", 12), std_ulogic_vector(to_unsigned(get_integer(prop, "vlan"), 12)));
          end if;
          check(not has_field(prop, "frames(9)"));
          report_example(prop, passed => get_boolean(prop, "config.enabled") or true);
        end loop;
        check_property(prop);

      elsif run("test_a_strategy_with_a_bug_is_one_failure") then
        check_strategy_error("broken_function");
        check_strategy_error("crashes_while_drawing");
        check_strategy_error("not_a_strategy");
        check_strategy_error("broken_machine");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 sec);

  dut_inst : entity work.property_lockup_dut
    port map (
      clk => clk,
      rst => rst,
      reset_works => reset_works,
      data => data,
      valid => valid,
      ready => ready
    );
end architecture;
