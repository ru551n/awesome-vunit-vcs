-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the QSPI protocol
-- checker VC: ids, loggers, actors and checkers, unexpected messages,
-- sync_pkg, the blocking and non-blocking check counts, and the handle a
-- parent VC derives from it.
--
-- The testbench drives the buses. Expected values that involve a default id
-- are taken from the handle, never written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_qspi_protocol_checker_vci is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_qspi_protocol_checker_vci is
  -- The first protocol checker with a default id of this architecture
  constant default_checker : qspi_protocol_checker_t := new_qspi_protocol_checker;
  signal default_m2s : qspi_m2s_t := qspi_m2s_init;

  constant second_default_checker : qspi_protocol_checker_t := new_qspi_protocol_checker;

  constant explicit_checker : qspi_protocol_checker_t := new_qspi_protocol_checker(
    id => get_id("tb_qspi_protocol_checker_vci:explicit_checker")
  );

  constant custom_logger : logger_t := get_logger("tb_qspi_protocol_checker_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_qspi_protocol_checker_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_qspi_protocol_checker_vci:custom_checker"));
  constant custom_protocol_checker : qspi_protocol_checker_t := new_qspi_protocol_checker(
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );
  signal custom_m2s : qspi_m2s_t := qspi_m2s_init;

  constant ignoring_checker : qspi_protocol_checker_t := new_qspi_protocol_checker(
    id => get_id("tb_qspi_protocol_checker_vci:ignoring_checker"),
    unexpected_msg_type_policy => ignore
  );

  -- Handles only: a parent derives the id of a checker, and keeps explicit
  -- parts and limits
  constant adopted_logger : logger_t := get_logger("tb_qspi_protocol_checker_vci:adopted_logger");
  constant adopted_actor : actor_t := new_actor("tb_qspi_protocol_checker_vci:adopted_actor");
  constant adopted_checker : checker_t := new_checker(adopted_logger);
  constant parent_master : qspi_master_t := new_qspi_master(
    protocol_checker => new_qspi_protocol_checker(
      t_sck_min => 10 ns,
      t_shsl => 45 ns,
      logger => adopted_logger,
      actor => adopted_actor,
      checker => adopted_checker
    ),
    id => get_id("tb_qspi_protocol_checker_vci:parent_master")
  );
  constant derived_master : qspi_master_t := new_qspi_master(
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_qspi_protocol_checker_vci:derived_master")
  );

  -- Checkers constructed before and after a master adopts an anonymous
  -- checker. The adopted checker must use up no default id.
  constant before_adoption_checker : qspi_protocol_checker_t := new_qspi_protocol_checker;
  constant adopting_master : qspi_master_t := new_qspi_master(
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_qspi_protocol_checker_vci:adopting_master")
  );
  constant after_adoption_checker : qspi_protocol_checker_t := new_qspi_protocol_checker;

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown qspi_protocol_checker message");
begin
  default_checker_inst : entity awesome_vunit_vcs.qspi_protocol_checker
    generic map (
      protocol_checker => default_checker
    )
    port map (
      m2s => default_m2s,
      s2m => qspi_s2m_init
    );

  custom_checker_inst : entity awesome_vunit_vcs.qspi_protocol_checker
    generic map (
      protocol_checker => custom_protocol_checker
    )
    port map (
      m2s => custom_m2s,
      s2m => qspi_s2m_init
    );

  ignoring_checker_inst : entity awesome_vunit_vcs.qspi_protocol_checker
    generic map (
      protocol_checker => ignoring_checker
    )
    port map (
      m2s => qspi_m2s_init,
      s2m => qspi_s2m_init
    );

  main : process
    variable reference : qspi_protocol_checker_reference_t;
    variable count : natural;
    variable reference_count : natural;
    variable start : time;

    -- A message of an unknown type, like the VCI tests of the Ethernet VCs
    procedure check_unexpected_message(actor : actor_t; logger : logger_t; expect_failure : boolean) is
      variable request_msg : msg_t;
    begin
      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown qspi_protocol_checker message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

    -- Two empty commands 10 ns apart on both buses: one tSHSL violation for
    -- each checker
    procedure deselect_too_briefly is
    begin
      for idx in 1 to 2 loop
        default_m2s.cs_n <= '0';
        custom_m2s.cs_n <= '0';
        wait for 10 ns;
        default_m2s.cs_n <= '1';
        custom_m2s.cs_n <= '1';
        wait for 10 ns;
      end loop;
      wait for 50 ns;
    end;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_checker))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_checker))), "qspi_protocol_checker", "name of its parent");
        check(get_parent(get_parent(get_id(default_checker))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(second_default_checker) /= get_id(default_checker), "a second default id differs");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_checker) = get_logger(get_id(default_checker)), "logger of the id");
        check(
          get_actor(default_checker) = find(get_id(default_checker), enable_deferred_creation => false),
          "actor"
        );
        check(as_sync(default_checker) = get_actor(default_checker), "as_sync");
        check(get_logger(get_checker(default_checker)) = get_logger(default_checker), "checker on the logger");

        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(default_checker), error);
        deselect_too_briefly;
        check_equal(get_log_count(get_logger(default_checker), error), 1, "violation on the default logger");
        reset_log_count(get_logger(default_checker), error);
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_checker) = get_id("tb_qspi_protocol_checker_vci:explicit_checker"), "id");
        check_equal(
          get_full_name(get_logger(explicit_checker)),
          full_name(get_id(explicit_checker)),
          "logger name"
        );
        check(
          get_actor(explicit_checker) = find(get_id(explicit_checker), enable_deferred_creation => false),
          "actor"
        );

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_protocol_checker) = custom_logger, "logger");
        check(get_actor(custom_protocol_checker) = custom_actor, "actor");
        check(as_sync(custom_protocol_checker) = custom_actor, "as_sync");
        check(get_checker(custom_protocol_checker) = custom_checker, "checker");

        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(default_checker), error);
        deselect_too_briefly;
        check_equal(get_log_count(get_logger(custom_checker), error), 1, "violation on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        -- The checker serves the actor that was passed
        wait_until_idle(net, custom_actor);
        get_check_count(net, custom_protocol_checker, qspi_cs_deselect, count);
        check_equal(count, 1, "count through the custom actor");
        reset_log_count(get_logger(custom_checker), error);
        reset_log_count(get_logger(default_checker), error);

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_checker), get_logger(default_checker), expect_failure => true);
        -- On the checker of the protocol checker, not on its logger
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_checker), get_logger(ignoring_checker), expect_failure => false);
        get_check_count(net, ignoring_checker, qspi_sck_period, count);
        check_equal(count, 0, "the checker answers after the unexpected message");

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_checker), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_checker));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");

      elsif run("test_blocking_and_reference_variants_agree") then
        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(default_checker), error);
        deselect_too_briefly;
        for rule in qspi_check_t loop
          get_check_count(net, default_checker, rule, count);
          get_check_count(net, default_checker, rule, reference);
          await_get_check_count_reply(net, reference, reference_count);
          check_equal(reference_count, count, "count of " & qspi_check_t'image(rule));
        end loop;
        get_check_count(net, default_checker, qspi_cs_deselect, count);
        check_equal(count, 1, "blocking qspi_cs_deselect count");
        reset_log_count(get_logger(default_checker), error);
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_reset_clears_the_counts_and_returns_at_once") then
        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(default_checker), error);
        deselect_too_briefly;
        get_check_count(net, default_checker, qspi_cs_deselect, count);
        check_equal(count, 1, "qspi_cs_deselect count before the reset");
        start := now;
        reset(net, default_checker);
        check_equal(now, start, "reset of a protocol checker");
        get_check_count(net, default_checker, qspi_cs_deselect, count);
        check_equal(count, 0, "qspi_cs_deselect count after the reset");
        reset_log_count(get_logger(default_checker), error);
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_an_adopted_checker_uses_no_default_id") then
        check(
          get_parent(get_id(protocol_checker(adopting_master))) = get_id(adopting_master),
          "the adopted checker is a child of the master"
        );
        -- The default ids are made in this order, one after the other
        count := integer'value(name(get_id(before_adoption_checker)));
        check_equal(
          name(get_id(after_adoption_checker)),
          to_string(count + 1),
          "the default id after one a master adopted"
        );
        check(get_id(after_adoption_checker) = get_id(after_adoption_checker), "the same id on every use");
        check(
          get_actor(after_adoption_checker) = find(get_id(after_adoption_checker), enable_deferred_creation => false),
          "the actor of the id"
        );

      elsif run("test_parent_derives_the_id_and_keeps_explicit_parts") then
        check(
          get_parent(get_id(protocol_checker(derived_master))) = get_id(derived_master),
          "the id is a child of the parent"
        );
        check_equal(
          get_full_name(get_logger(protocol_checker(derived_master))),
          "tb_qspi_protocol_checker_vci:derived_master:protocol_checker",
          "the logger follows the child id"
        );
        check(
          get_actor(protocol_checker(derived_master)) =
          find(get_id(protocol_checker(derived_master)), enable_deferred_creation => false),
          "the actor follows the child id"
        );

        check(
          get_parent(get_id(protocol_checker(parent_master))) = get_id(parent_master),
          "the id is a child even with explicit parts"
        );
        check(get_logger(protocol_checker(parent_master)) = adopted_logger, "explicit logger kept");
        check(get_actor(protocol_checker(parent_master)) = adopted_actor, "explicit actor kept");
        check(get_checker(protocol_checker(parent_master)) = adopted_checker, "explicit checker kept");
        check_equal(t_sck_min(protocol_checker(parent_master)), 10 ns, "t_sck_min kept");
        check_equal(t_shsl(protocol_checker(parent_master)), 45 ns, "t_shsl kept");
        check_equal(t_chdx(protocol_checker(parent_master)), 3 ns, "default t_chdx kept");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
