-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the QSPI master VC:
-- ids, loggers, actors and checkers, unexpected messages, sync_pkg, and the
-- blocking and non-blocking transfer.
--
-- The far end of each bus is a constant drive set by the testbench. Expected
-- values that involve a default id are taken from the handle, never written
-- as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_qspi_master_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_qspi_master_vci is

  -- The first master with a default id of this architecture
  constant default_master : qspi_master_t := new_qspi_master;
  signal default_m2s : qspi_m2s_t := qspi_m2s_init;
  signal default_s2m : qspi_s2m_t := qspi_s2m_init;

  constant explicit_master : qspi_master_t := new_qspi_master(id => get_id("tb_qspi_master_vci:explicit_master"));

  constant custom_logger : logger_t := get_logger("tb_qspi_master_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_qspi_master_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_qspi_master_vci:custom_checker"));
  constant custom_master : qspi_master_t := new_qspi_master(
    id => get_id("tb_qspi_master_vci:custom_master"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );
  signal custom_m2s : qspi_m2s_t := qspi_m2s_init;

  constant ignoring_master : qspi_master_t :=
    new_qspi_master(id => get_id("tb_qspi_master_vci:ignoring_master"), unexpected_msg_type_policy => ignore);
  signal ignoring_m2s : qspi_m2s_t := qspi_m2s_init;

  -- Masters that deselect CS for one 20 ns SCK period, short of the 30 ns
  -- tSHSL of their protocol checkers
  constant checked_master : qspi_master_t := new_qspi_master(
    cs_deselect_time => 5 ns,
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_qspi_master_vci:checked_master")
  );
  signal checked_m2s : qspi_m2s_t := qspi_m2s_init;

  constant default_checked_master : qspi_master_t :=
    new_qspi_master(cs_deselect_time => 5 ns, protocol_checker => new_qspi_protocol_checker);
  signal default_checked_m2s : qspi_m2s_t := qspi_m2s_init;

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown qspi_master message");

begin

  default_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => default_master
    )
    port map (
      m2s => default_m2s,
      s2m => default_s2m
    );

  custom_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => custom_master
    )
    port map (
      m2s => custom_m2s,
      s2m => qspi_s2m_init
    );

  ignoring_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => ignoring_master
    )
    port map (
      m2s => ignoring_m2s,
      s2m => qspi_s2m_init
    );

  checked_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => checked_master
    )
    port map (
      m2s => checked_m2s,
      s2m => qspi_s2m_init
    );

  default_checked_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => default_checked_master
    )
    port map (
      m2s => default_checked_m2s,
      s2m => qspi_s2m_init
    );

  main : process

    variable cmd : integer_array_t;
    variable data : integer_array_t := null_integer_array;
    variable reference_data : integer_array_t := null_integer_array;
    variable reference : qspi_transfer_reference_t;
    variable references : msg_vec_t(0 to 2);
    variable check_reference : qspi_protocol_checker_reference_t;

    -- An idle bus, then two transfers of checked_master back to back
    procedure transfer_pair is
    begin

      wait for 1 ms;
      qspi_transfer(net, checked_master, cmd);
      qspi_transfer(net, checked_master, cmd);
    end;

    variable count : natural;
    variable start : time;

    -- A message of an unknown type, like the VCI tests of the Ethernet VCs
    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown qspi_master message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    cmd := new_byte_array((0 => 16#9F#));

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_master))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_master))), "qspi_master", "name of its parent");
        check(get_parent(get_parent(get_id(default_master))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(default_checked_master) /= get_id(default_master), "a second default id differs");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_master) = get_logger(get_id(default_master)), "logger of the id");
        check(get_actor(default_master) = find(get_id(default_master), enable_deferred_creation => false), "actor");
        check(as_sync(default_master) = get_actor(default_master), "as_sync");
        check(get_logger(get_checker(default_master)) = get_logger(default_master), "checker on the logger");
        check(protocol_checker(default_master) = null_qspi_protocol_checker, "no protocol checker");

        -- Nothing drives the far end: 8 metavalue beats on the default logger
        disable_stop(get_logger(default_master), error);
        qspi_transfer(net, default_master, cmd, data, num_read_bytes => 1);
        check_equal(get_log_count(get_logger(default_master), error), 8, "metavalues on the default logger");
        reset_log_count(get_logger(default_master), error);

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_master) = get_id("tb_qspi_master_vci:explicit_master"), "id");
        check_equal(get_full_name(get_logger(explicit_master)), full_name(get_id(explicit_master)), "logger name");
        check(get_actor(explicit_master) = find(get_id(explicit_master), enable_deferred_creation => false), "actor");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_master) = custom_logger, "logger");
        check(get_actor(custom_master) = custom_actor, "actor");
        check(as_sync(custom_master) = custom_actor, "as_sync");
        check(get_checker(custom_master) = custom_checker, "checker");

        disable_stop(get_logger(custom_checker), error);
        qspi_transfer(net, custom_master, cmd, reference, num_read_bytes => 1);
        -- The master serves the actor that was passed
        wait_until_idle(net, custom_actor);
        await_qspi_transfer_reply(net, reference);
        check_equal(get_log_count(get_logger(custom_checker), error), 8, "metavalues on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_master), get_logger(default_master), expect_failure => true);
        -- On the checker of the master, not on its logger
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_master), get_logger(ignoring_master), expect_failure => false);
        qspi_transfer(net, ignoring_master, cmd);

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_master), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_master));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");

      elsif run("test_blocking_and_reference_variants_agree") then
        -- The far end drives 1010 on all four lanes
        default_s2m.io <= (value => "1010", enable => "1111");
        qspi_transfer(net, default_master, cmd, data, num_read_bytes => 2, read_lanes => 4);
        qspi_transfer(net, default_master, cmd, reference, num_read_bytes => 2, read_lanes => 4);
        await_qspi_transfer_reply(net, reference, reference_data);
        check_equal(length(data), 2, "blocking length");
        check_equal(length(reference_data), 2, "reference length");
        for idx in 0 to 1 loop

          check_equal(get(data, idx), 16#AA#, "blocking byte " & to_string(idx));
          check_equal(get(reference_data, idx), get(data, idx), "reference byte " & to_string(idx));
        end loop;

      elsif run("test_reset_of_an_idle_master_returns_at_once") then
        start := now;
        reset(net, default_master);
        check_equal(now, start, "reset of an idle master");
        qspi_transfer(net, default_master, cmd);
        check(default_m2s.cs_n = '1', "CS high after a transfer that follows a reset");

      elsif run("test_reset_answers_every_transfer_it_drops") then
        -- The first transfer is aborted before its first SCK edge, the others
        -- are dropped, and every caller gets its reply
        for idx in references'range loop

          qspi_transfer(net, default_master, cmd, references(idx));
        end loop;

        reset(net, default_master);
        for idx in references'range loop

          await_qspi_transfer_reply(net, references(idx));
        end loop;

        check(default_m2s.cs_n = '1', "CS high after the reset");

      elsif run("test_protocol_checker_is_a_child_of_the_master") then
        check(get_parent(get_id(protocol_checker(checked_master))) = get_id(checked_master), "parent id");
        check_equal(
          get_full_name(get_logger(protocol_checker(checked_master))),
          "tb_qspi_master_vci:checked_master:protocol_checker",
          "logger of the child"
        );
        check_equal(
          get_full_name(get_logger(protocol_checker(default_checked_master))),
          full_name(get_id(default_checked_master)) & ":protocol_checker",
          "logger of the child of a default id"
        );

        disable_stop(get_logger(protocol_checker(checked_master)), error);
        disable_stop(get_logger(protocol_checker(default_checked_master)), error);
        for idx in 1 to 2 loop

          qspi_transfer(net, checked_master, cmd, reference);
          qspi_transfer(net, default_checked_master, cmd);
          await_qspi_transfer_reply(net, reference);
        end loop;

        check_equal(get_log_count(get_logger(protocol_checker(checked_master)), error), 1, "violation on the child");
        check_equal(
          get_log_count(get_logger(protocol_checker(default_checked_master)), error),
          1,
          "violation on the child of a default id"
        );
        get_check_count(net, protocol_checker(checked_master), qspi_cs_deselect, count);
        check_equal(count, 1, "qspi_cs_deselect count of the child");
        reset_log_count(get_logger(protocol_checker(checked_master)), error);
        reset_log_count(get_logger(protocol_checker(default_checked_master)), error);

      elsif run("test_check_procedures_forward_to_the_protocol_checker") then
        -- Two transfers back to back after an idle bus: one CS deselect time
        -- shorter than tSHSL. The rule is switched while the bus is idle.
        disable_stop(get_logger(protocol_checker(checked_master)), error);
        transfer_pair;
        get_check_count(net, checked_master, qspi_cs_deselect, count);
        check_equal(count, 1, "blocking count through the master");
        get_check_count(net, checked_master, qspi_cs_deselect, check_reference);
        await_get_check_count_reply(net, check_reference, count);
        check_equal(count, 1, "count by reference through the master");

        set_check_enabled(net, checked_master, qspi_cs_deselect, false);
        transfer_pair;
        get_check_count(net, protocol_checker(checked_master), qspi_cs_deselect, count);
        check_equal(count, 1, "switched off through the master");

        set_check_enabled(net, checked_master, qspi_cs_deselect);
        transfer_pair;
        get_check_count(net, checked_master, qspi_cs_deselect, count);
        check_equal(count, 2, "switched on again through the master");
        check_equal(get_log_count(get_logger(protocol_checker(checked_master)), error), 2, "violations logged");
        reset_log_count(get_logger(protocol_checker(checked_master)), error);

      elsif run("test_check_procedures_of_a_master_without_protocol_checker_fail") then
        mock(get_logger(explicit_master), error);
        set_check_enabled(net, explicit_master, qspi_cs_deselect, false);
        check_log(get_logger(explicit_master), "tb_qspi_master_vci:explicit_master has no protocol checker", error);
        count := 1;
        get_check_count(net, explicit_master, qspi_cs_deselect, count);
        check_log(get_logger(explicit_master), "tb_qspi_master_vci:explicit_master has no protocol checker", error);
        check_equal(count, 0, "blocking count without a protocol checker");
        get_check_count(net, explicit_master, qspi_cs_deselect, check_reference);
        check_only_log(
          get_logger(explicit_master),
          "tb_qspi_master_vci:explicit_master has no protocol checker",
          error
        );
        check(check_reference = null_msg, "no reference without a protocol checker");
        unmock(get_logger(explicit_master));
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
