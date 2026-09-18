-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the AXI4 protocol
-- checker VC: ids, loggers, actors and checkers, unexpected messages,
-- sync_pkg, the blocking and non-blocking check counts, check switches,
-- reset, and the handle a monitor derives from it.
--
-- The testbench drives the interface. Expected values that involve a default
-- id are taken from the handle, never written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_protocol_checker_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_protocol_checker_vci is

  -- The first protocol checker with a default id of this architecture
  constant default_checker : axi4_protocol_checker_t := new_axi4_protocol_checker;
  constant second_default_checker : axi4_protocol_checker_t := new_axi4_protocol_checker;

  constant explicit_checker : axi4_protocol_checker_t :=
    new_axi4_protocol_checker(id => get_id("tb_axi4_protocol_checker_vci:explicit_checker"));

  constant custom_logger : logger_t := get_logger("tb_axi4_protocol_checker_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_axi4_protocol_checker_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_axi4_protocol_checker_vci:custom_checker"));
  constant custom_protocol_checker : axi4_protocol_checker_t :=
    new_axi4_protocol_checker(logger => custom_logger, actor => custom_actor, checker => custom_checker);

  constant ignoring_checker : axi4_protocol_checker_t := new_axi4_protocol_checker(
    id => get_id("tb_axi4_protocol_checker_vci:ignoring_checker"),
    unexpected_msg_type_policy => ignore
  );

  -- Handles only: a monitor derives the id of a checker, keeps explicit parts
  -- and gives it its bus
  constant wide_bus : axi4_bus_t := new_axi4_bus(data_length => 128, address_length => 48, id_length => 6);
  constant adopted_logger : logger_t := get_logger("tb_axi4_protocol_checker_vci:adopted_logger");
  constant adopted_actor : actor_t := new_actor("tb_axi4_protocol_checker_vci:adopted_actor");
  constant adopted_checker : checker_t := new_checker(adopted_logger);
  constant parent_monitor : axi4_monitor_t := new_axi4_monitor(
    wide_bus,
    protocol_checker => new_axi4_protocol_checker(
      timeout_cycles => 77,
      logger => adopted_logger,
      actor => adopted_actor,
      checker => adopted_checker
    ),
    id => get_id("tb_axi4_protocol_checker_vci:parent_monitor")
  );

  -- Checkers constructed before and after a monitor adopts an anonymous one.
  -- The adopted checker must use up no default id.
  constant before_adoption_checker : axi4_protocol_checker_t := new_axi4_protocol_checker;
  constant adopting_monitor : axi4_monitor_t := new_axi4_monitor(
    default_axi4_bus,
    protocol_checker => new_axi4_protocol_checker,
    id => get_id("tb_axi4_protocol_checker_vci:adopting_monitor")
  );
  constant after_adoption_checker : axi4_protocol_checker_t := new_axi4_protocol_checker;

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown axi4_protocol_checker message");

  signal aclk : std_ulogic := '0';
  signal bvalid, bready : std_ulogic := '0';

begin

  aclk <= not aclk after 5 ns;

  default_checker_inst : entity awesome_vunit_vcs.axi4_protocol_checker
    generic map (
      protocol_checker => default_checker
    )
    port map (
      aclk => aclk,
      bvalid => bvalid,
      bready => bready
    );

  custom_checker_inst : entity awesome_vunit_vcs.axi4_protocol_checker
    generic map (
      protocol_checker => custom_protocol_checker
    )
    port map (
      aclk => aclk,
      bvalid => bvalid,
      bready => bready
    );

  ignoring_checker_inst : entity awesome_vunit_vcs.axi4_protocol_checker
    generic map (
      protocol_checker => ignoring_checker
    )
    port map (
      aclk => aclk
    );

  main : process

    variable reference : axi4_protocol_checker_reference_t;
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
        check_only_log(logger, "Got unexpected message unknown axi4_protocol_checker message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

    -- A write response without a write: one AXI4_UNEXPECTED_RESP on both checkers
    procedure unexpected_response is
    begin

      bvalid <= '1';
      bready <= '1';
      wait until rising_edge(aclk);
      bvalid <= '0';
      bready <= '0';
      wait until rising_edge(aclk);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    disable_stop(get_logger(custom_checker), error);
    disable_stop(get_logger(default_checker), error);
    wait until rising_edge(aclk);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_checker))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_checker))), "axi4_protocol_checker", "name of its parent");
        check(get_parent(get_parent(get_id(default_checker))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(second_default_checker) /= get_id(default_checker), "a second default id differs");
        check(get_bus(default_checker) = default_axi4_bus, "the default bus");
        check_equal(timeout_cycles(default_checker), 1000, "the default timeout");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_checker) = get_logger(get_id(default_checker)), "logger of the id");
        check(get_actor(default_checker) = find(get_id(default_checker), enable_deferred_creation => false), "actor");
        check(as_sync(default_checker) = get_actor(default_checker), "as_sync");
        check(get_logger(get_checker(default_checker)) = get_logger(default_checker), "checker on the logger");
        unexpected_response;
        wait_until_idle(net, as_sync(default_checker));
        check_equal(get_log_count(get_logger(default_checker), error), 1, "violation on the default logger");

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_checker) = get_id("tb_axi4_protocol_checker_vci:explicit_checker"), "id");
        check_equal(get_full_name(get_logger(explicit_checker)), full_name(get_id(explicit_checker)), "logger name");
        check(get_actor(explicit_checker) = find(get_id(explicit_checker), enable_deferred_creation => false), "actor");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_protocol_checker) = custom_logger, "logger");
        check(get_actor(custom_protocol_checker) = custom_actor, "actor");
        check(as_sync(custom_protocol_checker) = custom_actor, "as_sync");
        check(get_checker(custom_protocol_checker) = custom_checker, "checker");
        unexpected_response;
        -- The checker serves the actor that was passed
        wait_until_idle(net, custom_actor);
        check_equal(get_log_count(get_logger(custom_checker), error), 1, "violation on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        get_check_count(net, custom_protocol_checker, axi4_unexpected_resp, count);
        check_equal(count, 1, "count through the custom actor");

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_checker), get_logger(default_checker), expect_failure => true);
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_checker), get_logger(ignoring_checker), expect_failure => false);
        get_check_count(net, ignoring_checker, axi4_wlast, count);
        check_equal(count, 0, "the checker answers after the unexpected message");

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_checker), 1 us);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_checker));
        check_equal(now - start, 1 us, "wait_until_idle waits for the requested time");

      elsif run("test_blocking_and_reference_variants_agree") then
        unexpected_response;
        for item in axi4_check_t'low to axi4_timeout loop

          get_check_count(net, default_checker, item, count);
          get_check_count(net, default_checker, item, reference);
          await_get_check_count_reply(net, reference, reference_count);
          check_equal(reference_count, count, "count of " & axi4_check_t'image(item));
        end loop;

        get_check_count(net, default_checker, axi4_unexpected_resp, count);
        check_equal(count, 1, "blocking axi4_unexpected_resp count");

      elsif run("test_a_disabled_check_neither_reports_nor_counts") then
        set_check_enabled(net, default_checker, axi4_unexpected_resp, false);
        unexpected_response;
        get_check_count(net, default_checker, axi4_unexpected_resp, count);
        check_equal(count, 0, "no count while disabled");
        check_equal(get_log_count(get_logger(default_checker), error), 0, "no error while disabled");
        set_check_enabled(net, default_checker, axi4_unexpected_resp);
        unexpected_response;
        get_check_count(net, default_checker, axi4_unexpected_resp, count);
        check_equal(count, 1, "counted again");

      elsif run("test_reset_clears_the_counts_and_returns_at_once") then
        unexpected_response;
        get_check_count(net, default_checker, axi4_unexpected_resp, count);
        check_equal(count, 1, "count before the reset");
        start := now;
        reset(net, default_checker);
        check_equal(now, start, "reset of a protocol checker");
        get_check_count(net, default_checker, axi4_unexpected_resp, count);
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

      elsif run("test_parent_derives_the_id_keeps_explicit_parts_and_gives_its_bus") then
        check(
          get_parent(get_id(protocol_checker(parent_monitor))) = get_id(parent_monitor),
          "the id is a child even with explicit parts"
        );
        check(get_logger(protocol_checker(parent_monitor)) = adopted_logger, "explicit logger kept");
        check(get_actor(protocol_checker(parent_monitor)) = adopted_actor, "explicit actor kept");
        check(get_checker(protocol_checker(parent_monitor)) = adopted_checker, "explicit checker kept");
        check_equal(timeout_cycles(protocol_checker(parent_monitor)), 77, "timeout kept");
        check(get_bus(protocol_checker(parent_monitor)) = wide_bus, "the bus of the monitor");
        check_equal(data_length(get_bus(protocol_checker(parent_monitor))), 128, "its data length");
      end if;
    end loop;

    -- Both checkers see the responses; the errors of the other one count here
    wait_until_idle(net, as_sync(default_checker));
    wait_until_idle(net, custom_actor);
    reset_log_count(get_logger(default_checker), error);
    reset_log_count(get_logger(custom_checker), error);
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);
end architecture;
