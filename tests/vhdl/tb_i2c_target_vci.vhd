-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the I2C target VC:
-- ids, loggers, actors and checkers, unexpected messages, sync_pkg, the
-- blocking and non-blocking memory reads, independent backends and reset.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c_target_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_i2c_target_vci is

  -- The first target with a default id of this architecture
  constant default_target : i2c_target_t := new_i2c_target(address => 16#50#);
  constant second_default_target : i2c_target_t := new_i2c_target(address => 16#51#);

  constant explicit_target : i2c_target_t :=
    new_i2c_target(address => 16#52#, id => get_id("tb_i2c_target_vci:explicit_target"));

  constant custom_logger : logger_t := get_logger("tb_i2c_target_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_i2c_target_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_i2c_target_vci:custom_checker"));
  constant custom_target : i2c_target_t := new_i2c_target(
    address => 16#53#,
    id => get_id("tb_i2c_target_vci:custom_target"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );

  constant ignoring_target : i2c_target_t := new_i2c_target(
    address => 16#54#,
    id => get_id("tb_i2c_target_vci:ignoring_target"),
    unexpected_msg_type_policy => ignore
  );

  constant master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode_plus);

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown i2c_target message");

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

  default_target_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => default_target
    )
    port map (
      scl => scl,
      sda => sda
    );

  second_default_target_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => second_default_target
    )
    port map (
      scl => scl,
      sda => sda
    );

  custom_target_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => custom_target
    )
    port map (
      scl => scl,
      sda => sda
    );

  ignoring_target_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => ignoring_target
    )
    port map (
      scl => scl,
      sda => sda
    );

  main : process

    variable data : std_ulogic_vector(15 downto 0);
    variable reference_data : std_ulogic_vector(15 downto 0);
    variable reference : i2c_target_reference_t;
    variable status : i2c_status_t;
    variable start : time;

    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown i2c_target message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_target))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_target))), "i2c_target", "name of its parent");
        check(get_parent(get_parent(get_id(default_target))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(second_default_target) /= get_id(default_target), "a second default id differs");
        check_equal(address(default_target), 16#50#, "address");
        check_equal(t_hd_dat(default_target), 100 ns, "default t_hd_dat");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_target) = get_logger(get_id(default_target)), "logger of the id");
        check(get_actor(default_target) = find(get_id(default_target), enable_deferred_creation => false), "actor");
        check(as_sync(default_target) = get_actor(default_target), "as_sync");
        check(get_logger(get_checker(default_target)) = get_logger(default_target), "checker on the logger");
        disable_stop(get_logger(default_target), error);
        i2c_target_check_memory(net, default_target, 0, x"01");
        wait_until_idle(net, as_sync(default_target));
        check_equal(get_log_count(get_logger(default_target), error), 1, "a memory difference on the default logger");
        reset_log_count(get_logger(default_target), error);

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_target) = get_id("tb_i2c_target_vci:explicit_target"), "id");
        check_equal(get_full_name(get_logger(explicit_target)), full_name(get_id(explicit_target)), "logger name");
        check(get_actor(explicit_target) = find(get_id(explicit_target), enable_deferred_creation => false), "actor");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_target) = custom_logger, "logger");
        check(get_actor(custom_target) = custom_actor, "actor");
        check(as_sync(custom_target) = custom_actor, "as_sync");
        check(get_checker(custom_target) = custom_checker, "checker");
        disable_stop(get_logger(custom_checker), error);
        i2c_target_check_memory(net, custom_target, 0, x"01", "custom");
        wait_until_idle(net, custom_actor);
        check_equal(get_log_count(get_logger(custom_checker), error), 1, "a memory difference on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_target), get_logger(default_target), expect_failure => true);
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_target), get_logger(ignoring_target), expect_failure => false);
        i2c_write(net, master, 16#54#, x"00", status);
        check(status = i2c_ok, "the target answers after the unexpected message");

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_target), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_target));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");

      elsif run("test_blocking_and_reference_variants_agree") then
        i2c_target_preload(net, default_target, 16#20#, x"BEEF");
        i2c_target_read_memory(net, default_target, 16#20#, data);
        i2c_target_read_memory(net, default_target, 16#20#, 2, reference);
        await_i2c_target_read_memory_reply(net, reference, reference_data);
        check_equal(data, std_ulogic_vector'(x"BEEF"), "blocking");
        check_equal(reference_data, data, "reference");

      elsif run("test_default_instances_have_independent_backends") then
        i2c_write(net, master, 16#50#, x"0011");
        i2c_write(net, master, 16#51#, x"0022");
        wait_until_idle(net, as_sync(master));
        i2c_target_check_memory(net, default_target, 0, x"11");
        i2c_target_check_memory(net, second_default_target, 0, x"22");

      elsif run("test_reset_releases_the_bus") then
        -- A read left without a STOP: the target holds SDA low for a 0 bit
        i2c_target_preload(net, default_target, 0, x"00");
        i2c_transfer(net, master, "S 0xA1 B1", reference);
        wait_until_idle(net, as_sync(master));
        check(sda = '0', "the target drives SDA");
        start := now;
        reset(net, default_target);
        check_equal(now, start, "reset returns at once");
        check(sda = 'H', "the target releases SDA");
        reset(net, master);
        i2c_write(net, master, 16#50#, x"0033", status);
        check(status = i2c_ok, "a transfer after the reset");
        delete(reference);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
