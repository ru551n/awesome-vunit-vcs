-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the flash VC: ids,
-- loggers, actors and checkers, unexpected messages, sync_pkg, and the
-- blocking and non-blocking variants of the procedures that return a value.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals, except the first default flash of this
-- architecture.

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_flash_vci is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_flash_vci is
  -- The first flash with a default id of this architecture, with a master
  constant default_flash : flash_t := new_flash;
  constant default_master : qspi_master_t := new_qspi_master(id => get_id("tb_flash_vci:default_master"));
  signal default_m2s : qspi_m2s_t := qspi_m2s_init;
  signal default_s2m : qspi_s2m_t := qspi_s2m_init;

  constant explicit_flash : flash_t := new_flash(id => get_id("tb_flash_vci:explicit_flash"));

  constant custom_logger : logger_t := get_logger("tb_flash_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_flash_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_flash_vci:custom_checker"));
  constant custom_flash : flash_t := new_flash(
    id => get_id("tb_flash_vci:custom_flash"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );
  signal custom_s2m : qspi_s2m_t := qspi_s2m_init;

  constant ignoring_flash : flash_t := new_flash(
    id => get_id("tb_flash_vci:ignoring_flash"),
    unexpected_msg_type_policy => ignore
  );
  signal ignoring_s2m : qspi_s2m_t := qspi_s2m_init;

  -- Flashes with a protocol checker, on buses the testbench drives
  constant checked_flash : flash_t := new_flash(
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_flash_vci:checked_flash")
  );
  signal checked_m2s : qspi_m2s_t := qspi_m2s_init;
  signal checked_s2m : qspi_s2m_t := qspi_s2m_init;

  constant default_checked_flash : flash_t := new_flash(protocol_checker => new_qspi_protocol_checker);
  signal default_checked_m2s : qspi_m2s_t := qspi_m2s_init;
  signal default_checked_s2m : qspi_s2m_t := qspi_s2m_init;

  -- Handles only: protocol checkers with explicit parts
  constant kept_id_checker : qspi_protocol_checker_t := new_qspi_protocol_checker(
    id => get_id("tb_flash_vci:kept_id_checker")
  );
  constant kept_id_flash : flash_t := new_flash(
    protocol_checker => kept_id_checker,
    id => get_id("tb_flash_vci:kept_id_flash")
  );
  constant kept_logger : logger_t := get_logger("tb_flash_vci:kept_logger");
  constant kept_logger_flash : flash_t := new_flash(
    protocol_checker => new_qspi_protocol_checker(t_shsl => 40 ns, logger => kept_logger),
    id => get_id("tb_flash_vci:kept_logger_flash")
  );

  signal idle_m2s : qspi_m2s_t := qspi_m2s_init;

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown flash message");

  procedure check_arrays(got : integer_array_t; expected : integer_array_t; msg : string) is
  begin
    check_equal(length(got), length(expected), msg & ": length");
    for idx in 0 to length(expected) - 1 loop
      check_equal(get(got, idx), get(expected, idx), msg & ": element " & to_string(idx));
    end loop;
  end;
begin
  default_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => default_flash
    )
    port map (
      m2s => default_m2s,
      s2m => default_s2m
    );

  default_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => default_master
    )
    port map (
      m2s => default_m2s,
      s2m => default_s2m
    );

  custom_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => custom_flash
    )
    port map (
      m2s => idle_m2s,
      s2m => custom_s2m
    );

  ignoring_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => ignoring_flash
    )
    port map (
      m2s => idle_m2s,
      s2m => ignoring_s2m
    );

  checked_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => checked_flash
    )
    port map (
      m2s => checked_m2s,
      s2m => checked_s2m
    );

  default_checked_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => default_checked_flash
    )
    port map (
      m2s => default_checked_m2s,
      s2m => default_checked_s2m
    );

  main : process
    variable reference : flash_reference_t;
    variable got : integer_array_t;
    variable expected : integer_array_t;
    variable value : integer;
    variable reference_value : integer;
    variable count : natural;
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
        check_only_log(logger, "Got unexpected message unknown flash message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

    -- Two empty commands 10 ns apart on both driven buses: one tSHSL
    -- violation for each protocol checker
    procedure deselect_too_briefly is
    begin
      for idx in 1 to 2 loop
        checked_m2s.cs_n <= '0';
        default_checked_m2s.cs_n <= '0';
        wait for 10 ns;
        checked_m2s.cs_n <= '1';
        default_checked_m2s.cs_n <= '1';
        wait for 10 ns;
      end loop;
      wait for 50 ns;
    end;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("test_default_id_is_enumerated") then
        check_equal(name(get_id(default_flash)), "1", "name of the first default id");
        check_equal(name(get_parent(get_id(default_flash))), "flash", "name of its parent");
        check(get_parent(get_parent(get_id(default_flash))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(default_checked_flash) /= get_id(default_flash), "a second default id differs");
        check(
          get_parent(get_id(default_checked_flash)) = get_parent(get_id(default_flash)),
          "a second default id has the same parent"
        );

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_flash) = get_logger(get_id(default_flash)), "logger of the id");
        check(get_actor(default_flash) = find(get_id(default_flash), enable_deferred_creation => false), "actor");
        check(as_sync(default_flash) = get_actor(default_flash), "as_sync");
        check(get_logger(get_checker(default_flash)) = get_logger(default_flash), "checker on the logger");
        check(protocol_checker(default_flash) = null_qspi_protocol_checker, "no protocol checker");

        disable_stop(get_logger(default_flash), error);
        flash_check_content(net, default_flash, 16#000100#, new_byte_array((0 => 16#00#)));
        wait_until_idle(net, as_sync(default_flash));
        check_equal(get_log_count(get_logger(default_flash), error), 1, "mismatch on the default logger");
        reset_log_count(get_logger(default_flash), error);

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_flash) = get_id("tb_flash_vci:explicit_flash"), "id");
        check_equal(get_full_name(get_logger(explicit_flash)), full_name(get_id(explicit_flash)), "logger name");
        check(get_actor(explicit_flash) = find(get_id(explicit_flash), enable_deferred_creation => false), "actor");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_flash) = custom_logger, "logger");
        check(get_actor(custom_flash) = custom_actor, "actor");
        check(as_sync(custom_flash) = custom_actor, "as_sync");
        check(get_checker(custom_flash) = custom_checker, "checker");

        disable_stop(get_logger(custom_checker), error);
        flash_check_content(net, custom_flash, 16#000100#, new_byte_array((0 => 16#00#)));
        -- The flash serves the actor that was passed
        wait_until_idle(net, custom_actor);
        check_equal(get_log_count(get_logger(custom_checker), error), 1, "mismatch on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_flash), get_logger(default_flash), expect_failure => true);
        -- On the checker of the flash, not on its logger
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_flash), get_logger(ignoring_flash), expect_failure => false);
        flash_get_stat(net, ignoring_flash, "program_count", value);
        check_equal(value, 0, "the flash answers after the unexpected message");

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_flash), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_flash));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");

      elsif run("test_blocking_and_reference_variants_agree") then
        flash_set_timing_enable(net, default_flash, false);
        expected := new_byte_array((16#11#, 16#22#, 16#33#, 16#44#));
        qspi_flash_write_enable(net, default_master);
        qspi_flash_page_program(net, default_master, 16#002000#, expected);

        flash_read_back(net, default_flash, 16#002000#, 4, got);
        check_arrays(got, expected, "blocking read back");
        deallocate(got);
        flash_read_back(net, default_flash, 16#002000#, 4, reference);
        await_flash_read_back_reply(net, reference, got);
        check_arrays(got, expected, "read back by reference");
        deallocate(got);
        deallocate(expected);

        flash_get_written_regions(net, default_flash, expected);
        check_equal(length(expected), 2, "one written region");
        flash_get_written_regions(net, default_flash, reference);
        await_flash_get_written_regions_reply(net, reference, got);
        check_arrays(got, expected, "written regions by reference");
        deallocate(got);
        deallocate(expected);

        flash_get_stat(net, default_flash, "program_count", value);
        check_equal(value, 1, "blocking program_count");
        flash_get_stat(net, default_flash, "program_count", reference);
        await_flash_get_stat_reply(net, reference, reference_value);
        check_equal(reference_value, value, "program_count by reference");

      elsif run("test_reset_of_an_idle_flash_returns_at_once") then
        flash_preload(net, default_flash, 16#003000#, new_byte_array((16#12#, 16#34#)));
        start := now;
        reset(net, default_flash);
        check_equal(now, start, "reset of an idle flash");
        flash_check_content(net, default_flash, 16#003000#, new_byte_array((16#12#, 16#34#)));
        flash_get_stat(net, default_flash, "wip", value);
        check_equal(value, 0, "wip after a reset");

      elsif run("test_protocol_checker_is_a_child_of_the_flash") then
        check(get_parent(get_id(protocol_checker(checked_flash))) = get_id(checked_flash), "parent id");
        check(
          get_parent(get_id(protocol_checker(default_checked_flash))) = get_id(default_checked_flash),
          "parent of the child of a default id"
        );
        check_equal(
          get_full_name(get_logger(protocol_checker(checked_flash))),
          "tb_flash_vci:checked_flash:protocol_checker",
          "logger of the child"
        );
        check_equal(
          get_full_name(get_logger(protocol_checker(default_checked_flash))),
          full_name(get_id(default_checked_flash)) & ":protocol_checker",
          "logger of the child of a default id"
        );
        check(
          get_actor(protocol_checker(checked_flash)) =
          find(get_id(protocol_checker(checked_flash)), enable_deferred_creation => false),
          "actor of the child"
        );

        disable_stop(get_logger(protocol_checker(checked_flash)), error);
        disable_stop(get_logger(protocol_checker(default_checked_flash)), error);
        deselect_too_briefly;
        check_equal(get_log_count(get_logger(protocol_checker(checked_flash)), error), 1, "violation on the child");
        check_equal(
          get_log_count(get_logger(protocol_checker(default_checked_flash)), error),
          1,
          "violation on the child of a default id"
        );
        check_equal(get_log_count(get_logger(checked_flash), error), 0, "errors on the flash");
        get_check_count(net, protocol_checker(checked_flash), qspi_cs_deselect, count);
        check_equal(count, 1, "qspi_cs_deselect count of the child");
        reset_log_count(get_logger(protocol_checker(checked_flash)), error);
        reset_log_count(get_logger(protocol_checker(default_checked_flash)), error);

      elsif run("test_explicit_protocol_checker_parts_are_kept") then
        check(protocol_checker(kept_id_flash) = kept_id_checker, "a checker with an explicit id is kept");

        check(
          get_parent(get_id(protocol_checker(kept_logger_flash))) = get_id(kept_logger_flash),
          "a checker without an explicit id becomes a child"
        );
        check(get_logger(protocol_checker(kept_logger_flash)) = kept_logger, "explicit logger kept");
        check(get_logger(get_checker(protocol_checker(kept_logger_flash))) = kept_logger, "checker on it");
        check_equal(t_shsl(protocol_checker(kept_logger_flash)), 40 ns, "limits kept");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
