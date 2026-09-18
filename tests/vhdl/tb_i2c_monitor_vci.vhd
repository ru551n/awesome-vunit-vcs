-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the I2C monitor VC:
-- ids, loggers, actors and checkers, its protocol checker, unexpected
-- messages, sync_pkg, publishing, the blocking and non-blocking pops and
-- statistics, metavalues and reset.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c_monitor_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_i2c_monitor_vci is

  -- The first monitor with a default id of this architecture
  constant default_monitor : i2c_monitor_t := new_i2c_monitor;
  constant checked_monitor : i2c_monitor_t :=
    new_i2c_monitor(protocol_checker => new_i2c_protocol_checker(speed => i2c_fast_mode_plus));

  constant explicit_monitor : i2c_monitor_t := new_i2c_monitor(id => get_id("tb_i2c_monitor_vci:explicit_monitor"));

  constant custom_logger : logger_t := get_logger("tb_i2c_monitor_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_i2c_monitor_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_i2c_monitor_vci:custom_checker"));
  constant custom_monitor : i2c_monitor_t := new_i2c_monitor(
    id => get_id("tb_i2c_monitor_vci:custom_monitor"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );

  constant ignoring_monitor : i2c_monitor_t :=
    new_i2c_monitor(id => get_id("tb_i2c_monitor_vci:ignoring_monitor"), unexpected_msg_type_policy => ignore);

  constant master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode_plus);
  constant target : i2c_target_t := new_i2c_target(address => 16#50#);

  constant subscriber : actor_t := new_actor("tb_i2c_monitor_vci:subscriber");
  constant unknown_msg_type : msg_type_t := new_msg_type("unknown i2c_monitor message");

  type monitor_array_t is array (natural range <>) of i2c_monitor_t;

  constant monitors : monitor_array_t(0 to 3) := (default_monitor, checked_monitor, custom_monitor, ignoring_monitor);

  signal scl : std_logic := 'H';
  signal sda : std_logic := 'H';

begin

  scl <= 'H';
  sda <= 'H';

  master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => master
    )
    port map (
      scl => scl,
      sda => sda
    );

  target_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => target
    )
    port map (
      scl => scl,
      sda => sda
    );

  monitors_gen : for idx in monitors'range generate
    monitor_inst : entity awesome_vunit_vcs.i2c_monitor
      generic map (
        monitor => monitors(idx)
      )
      port map (
        scl => scl,
        sda => sda
      );

  end generate monitors_gen;

  main : process

    variable transfer : i2c_transfer_t;
    variable reference_transfer : i2c_transfer_t;
    variable reference : i2c_monitor_reference_t;
    variable statistics : i2c_statistics_t;
    variable reference_statistics : i2c_statistics_t;
    variable msg : msg_t;
    variable start : time;

    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown i2c_monitor message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_monitor))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_monitor))), "i2c_monitor", "name of its parent");
        check(get_parent(get_parent(get_id(default_monitor))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(checked_monitor) /= get_id(default_monitor), "a second default id differs");
        check(protocol_checker(default_monitor) = null_i2c_protocol_checker, "no protocol checker");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_monitor) = get_logger(get_id(default_monitor)), "logger of the id");
        check(get_actor(default_monitor) = find(get_id(default_monitor), enable_deferred_creation => false), "actor");
        check(as_sync(default_monitor) = get_actor(default_monitor), "as_sync");
        check(get_logger(get_checker(default_monitor)) = get_logger(default_monitor), "checker on the logger");

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_monitor) = get_id("tb_i2c_monitor_vci:explicit_monitor"), "id");
        check_equal(get_full_name(get_logger(explicit_monitor)), full_name(get_id(explicit_monitor)), "logger name");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_monitor) = custom_logger, "logger");
        check(get_actor(custom_monitor) = custom_actor, "actor");
        check(get_checker(custom_monitor) = custom_checker, "checker");
        disable_stop(get_logger(custom_checker), error);
        check_i2c_transfer(net, custom_monitor, 16#50#, false, x"99", "custom");
        i2c_write(net, master, 16#50#, x"00");
        wait_until_idle(net, as_sync(master));
        wait_until_idle(net, custom_actor);
        check_equal(get_log_count(get_logger(custom_checker), error), 1, "a scoreboard difference on the checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_protocol_checker_is_a_child_of_its_monitor") then
        check(
          get_parent(get_id(protocol_checker(checked_monitor))) = get_id(checked_monitor),
          "the checker is a child of the monitor"
        );
        check_equal(name(get_id(protocol_checker(checked_monitor))), "protocol_checker", "its name");

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_monitor), get_logger(default_monitor), expect_failure => true);
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_monitor), get_logger(ignoring_monitor), expect_failure => false);

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_monitor), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_monitor));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");

      elsif run("test_monitor_publishes_transfers") then
        subscribe(subscriber, get_actor(default_monitor));
        -- The monitor sees the subscriber when it next looks
        wait_until_idle(net, as_sync(default_monitor));
        i2c_write(net, master, 16#50#, x"0177");
        receive(net, subscriber, msg);
        check(message_type(msg) = i2c_transfer_msg, "an i2c_transfer_msg");
        pop_i2c_transfer(msg, transfer);
        check_equal(transfer.address, 16#50#, "published address");
        check_equal(get(transfer.data, 1), 16#77#, "published data");
        deallocate(transfer.data);
        delete(msg);
        unsubscribe(subscriber, get_actor(default_monitor));

      elsif run("test_blocking_and_reference_variants_agree") then
        i2c_write(net, master, 16#50#, x"0212");
        i2c_write(net, master, 16#50#, x"0212");
        pop_i2c_transfer(net, default_monitor, transfer);
        pop_i2c_transfer(net, default_monitor, reference);
        await_pop_i2c_transfer_reply(net, reference, reference_transfer);
        check_equal(reference_transfer.address, transfer.address, "address");
        check_equal(length(reference_transfer.data), length(transfer.data), "bytes");
        check(reference_transfer.start_time > transfer.start_time, "the second transfer");
        deallocate(transfer.data);
        deallocate(reference_transfer.data);
        get_i2c_statistics(net, default_monitor, statistics);
        get_i2c_statistics(net, default_monitor, reference);
        await_get_i2c_statistics_reply(net, reference, reference_statistics);
        check_equal(statistics.transfers, 2, "transfers");
        check_equal(reference_statistics.transfers, statistics.transfers, "reference transfers");
        check_equal(reference_statistics.data_bytes, 4, "reference data bytes");

      elsif run("test_metavalues_without_a_protocol_checker") then
        disable_stop(get_logger(default_monitor), error);
        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(ignoring_monitor), error);
        disable_stop(get_logger(get_checker(protocol_checker(checked_monitor))), error);
        sda <= 'X';
        wait for 1 us;
        sda <= 'Z';
        wait_until_idle(net, as_sync(default_monitor));
        wait_until_idle(net, as_sync(checked_monitor));
        wait_until_idle(net, as_sync(protocol_checker(checked_monitor)));
        check_equal(get_log_count(get_logger(default_monitor), error), 1, "the monitor reports the metavalue");
        check_equal(get_log_count(get_logger(checked_monitor), error), 0, "a monitor with a checker leaves it to it");
        check_equal(
          get_log_count(get_logger(get_checker(protocol_checker(checked_monitor))), error),
          1,
          "the checker of the monitor reports it"
        );
        reset_log_count(get_logger(default_monitor), error);
        reset_log_count(get_logger(custom_checker), error);
        reset_log_count(get_logger(ignoring_monitor), error);
        reset_log_count(get_logger(get_checker(protocol_checker(checked_monitor))), error);

      elsif run("test_reset_forgets_kept_and_expected_transfers") then
        check_i2c_transfer(net, default_monitor, 16#51#, false, x"00");
        i2c_write(net, master, 16#50#, x"00", stop => false);
        wait_until_idle(net, as_sync(master));
        start := now;
        reset(net, default_monitor, clear_statistics => true);
        check_equal(now, start, "reset returns at once");
        reset(net, master);
        i2c_write(net, master, 16#50#, x"0301");
        pop_i2c_transfer(net, default_monitor, transfer);
        check_equal(get(transfer.data, 0), 3, "the transfer after the reset");
        deallocate(transfer.data);
        get_i2c_statistics(net, default_monitor, statistics);
        check_equal(statistics.transfers, 1, "statistics cleared");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
