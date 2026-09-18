-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the I2C protocol
-- checker VC: ids, loggers, actors and checkers, unexpected messages,
-- sync_pkg, the blocking and non-blocking check counts, reset, and the handle
-- a monitor derives from it.
--
-- The testbench drives the buses. Expected values that involve a default id
-- are taken from the handle, never written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c_protocol_checker_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_i2c_protocol_checker_vci is

  -- The first protocol checker with a default id of this architecture
  constant default_checker : i2c_protocol_checker_t := new_i2c_protocol_checker;
  constant second_default_checker : i2c_protocol_checker_t := new_i2c_protocol_checker;

  constant explicit_checker : i2c_protocol_checker_t :=
    new_i2c_protocol_checker(id => get_id("tb_i2c_protocol_checker_vci:explicit_checker"));

  constant custom_logger : logger_t := get_logger("tb_i2c_protocol_checker_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_i2c_protocol_checker_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_i2c_protocol_checker_vci:custom_checker"));
  constant custom_protocol_checker : i2c_protocol_checker_t :=
    new_i2c_protocol_checker(logger => custom_logger, actor => custom_actor, checker => custom_checker);

  constant ignoring_checker : i2c_protocol_checker_t := new_i2c_protocol_checker(
    id => get_id("tb_i2c_protocol_checker_vci:ignoring_checker"),
    unexpected_msg_type_policy => ignore
  );

  -- Handles only: a monitor derives the id of a checker, and keeps explicit parts
  constant adopted_logger : logger_t := get_logger("tb_i2c_protocol_checker_vci:adopted_logger");
  constant adopted_actor : actor_t := new_actor("tb_i2c_protocol_checker_vci:adopted_actor");
  constant adopted_checker : checker_t := new_checker(adopted_logger);
  constant parent_monitor : i2c_monitor_t := new_i2c_monitor(
    protocol_checker => new_i2c_protocol_checker(
      speed => i2c_fast_mode,
      t_stuck => 1 ms,
      logger => adopted_logger,
      actor => adopted_actor,
      checker => adopted_checker
    ),
    id => get_id("tb_i2c_protocol_checker_vci:parent_monitor")
  );

  -- Checkers constructed before and after a monitor adopts an anonymous one.
  -- The adopted checker must use up no default id.
  constant before_adoption_checker : i2c_protocol_checker_t := new_i2c_protocol_checker;
  constant adopting_monitor : i2c_monitor_t := new_i2c_monitor(
    protocol_checker => new_i2c_protocol_checker,
    id => get_id("tb_i2c_protocol_checker_vci:adopting_monitor")
  );
  constant after_adoption_checker : i2c_protocol_checker_t := new_i2c_protocol_checker;

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown i2c_protocol_checker message");

  signal default_scl : std_logic := 'H';
  signal default_sda : std_logic := 'H';
  signal custom_scl : std_logic := 'H';
  signal custom_sda : std_logic := 'H';

begin

  default_scl <= 'H';
  default_sda <= 'H';
  custom_scl <= 'H';
  custom_sda <= 'H';

  default_checker_inst : entity awesome_vunit_vcs.i2c_protocol_checker
    generic map (
      protocol_checker => default_checker
    )
    port map (
      scl => default_scl,
      sda => default_sda
    );

  custom_checker_inst : entity awesome_vunit_vcs.i2c_protocol_checker
    generic map (
      protocol_checker => custom_protocol_checker
    )
    port map (
      scl => custom_scl,
      sda => custom_sda
    );

  ignoring_checker_inst : entity awesome_vunit_vcs.i2c_protocol_checker
    generic map (
      protocol_checker => ignoring_checker
    )
    port map (
      scl => '1',
      sda => '1'
    );

  main : process

    variable reference : i2c_protocol_checker_reference_t;
    variable count : natural;
    variable reference_count : natural;
    variable start : time;

    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown i2c_protocol_checker message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

    -- A START 100 ns after a STOP on both buses: one I2C_T_BUF violation each
    procedure start_too_early is
    begin

      for idx in 1 to 2 loop

        default_sda <= '0';
        custom_sda <= '0';
        wait for 5 us;
        default_sda <= 'Z';
        custom_sda <= 'Z';
        wait for 100 ns;
      end loop;

      wait for 5 us;
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    disable_stop(get_logger(custom_checker), error);
    disable_stop(get_logger(default_checker), error);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_checker))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_checker))), "i2c_protocol_checker", "name of its parent");
        check(get_parent(get_parent(get_id(default_checker))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(second_default_checker) /= get_id(default_checker), "a second default id differs");
        check(speed(default_checker) = i2c_standard_mode, "speed");
        check_equal(t_stuck(default_checker), 35 ms, "default stuck-low time");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_checker) = get_logger(get_id(default_checker)), "logger of the id");
        check(get_actor(default_checker) = find(get_id(default_checker), enable_deferred_creation => false), "actor");
        check(as_sync(default_checker) = get_actor(default_checker), "as_sync");
        check(get_logger(get_checker(default_checker)) = get_logger(default_checker), "checker on the logger");
        start_too_early;
        wait_until_idle(net, as_sync(default_checker));
        check_equal(get_log_count(get_logger(default_checker), error), 1, "violation on the default logger");

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_checker) = get_id("tb_i2c_protocol_checker_vci:explicit_checker"), "id");
        check_equal(get_full_name(get_logger(explicit_checker)), full_name(get_id(explicit_checker)), "logger name");
        check(get_actor(explicit_checker) = find(get_id(explicit_checker), enable_deferred_creation => false), "actor");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_protocol_checker) = custom_logger, "logger");
        check(get_actor(custom_protocol_checker) = custom_actor, "actor");
        check(as_sync(custom_protocol_checker) = custom_actor, "as_sync");
        check(get_checker(custom_protocol_checker) = custom_checker, "checker");
        start_too_early;
        -- The checker serves the actor that was passed
        wait_until_idle(net, custom_actor);
        check_equal(get_log_count(get_logger(custom_checker), error), 1, "violation on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        get_check_count(net, custom_protocol_checker, i2c_t_buf, count);
        check_equal(count, 1, "count through the custom actor");

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_checker), get_logger(default_checker), expect_failure => true);
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_checker), get_logger(ignoring_checker), expect_failure => false);
        get_check_count(net, ignoring_checker, i2c_f_scl, count);
        check_equal(count, 0, "the checker answers after the unexpected message");

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_checker), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_checker));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");

      elsif run("test_blocking_and_reference_variants_agree") then
        start_too_early;
        for item in i2c_check_t'low to i2c_stuck_low loop

          get_check_count(net, default_checker, item, count);
          get_check_count(net, default_checker, item, reference);
          await_get_check_count_reply(net, reference, reference_count);
          check_equal(reference_count, count, "count of " & i2c_check_t'image(item));
        end loop;

        get_check_count(net, default_checker, i2c_t_buf, count);
        check_equal(count, 1, "blocking i2c_t_buf count");

      elsif run("test_reset_clears_the_counts_and_returns_at_once") then
        start_too_early;
        get_check_count(net, default_checker, i2c_t_buf, count);
        check_equal(count, 1, "count before the reset");
        start := now;
        reset(net, default_checker);
        check_equal(now, start, "reset of a protocol checker");
        get_check_count(net, default_checker, i2c_t_buf, count);
        check_equal(count, 0, "count after the reset");

      elsif run("test_an_adopted_checker_uses_no_default_id") then
        check(
          get_parent(get_id(protocol_checker(adopting_monitor))) = get_id(adopting_monitor),
          "the adopted checker is a child of the monitor"
        );
        count := integer'value(name(get_id(before_adoption_checker)));
        check_equal(name(get_id(after_adoption_checker)), to_string(count + 1), "the default id after the adoption");
        check(
          get_actor(after_adoption_checker) = find(get_id(after_adoption_checker), enable_deferred_creation => false),
          "the actor of the id"
        );

      elsif run("test_parent_derives_the_id_and_keeps_explicit_parts") then
        check(
          get_parent(get_id(protocol_checker(parent_monitor))) = get_id(parent_monitor),
          "the id is a child even with explicit parts"
        );
        check(get_logger(protocol_checker(parent_monitor)) = adopted_logger, "explicit logger kept");
        check(get_actor(protocol_checker(parent_monitor)) = adopted_actor, "explicit actor kept");
        check(get_checker(protocol_checker(parent_monitor)) = adopted_checker, "explicit checker kept");
        check(speed(protocol_checker(parent_monitor)) = i2c_fast_mode, "speed kept");
        check_equal(t_stuck(protocol_checker(parent_monitor)), 1 ms, "stuck-low time kept");
      end if;
    end loop;

    reset_log_count(get_logger(default_checker), error);
    reset_log_count(get_logger(custom_checker), error);
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
