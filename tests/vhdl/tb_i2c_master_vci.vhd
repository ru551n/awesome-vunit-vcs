-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the I2C master VC:
-- ids, loggers, actors and checkers, unexpected messages, sync_pkg, the
-- blocking and non-blocking reads, and reset.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c_master_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_i2c_master_vci is

  -- The first master with a default id of this architecture
  constant default_master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode_plus);
  constant second_default_master : i2c_master_t := new_i2c_master;

  constant explicit_master : i2c_master_t := new_i2c_master(id => get_id("tb_i2c_master_vci:explicit_master"));

  constant custom_logger : logger_t := get_logger("tb_i2c_master_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_i2c_master_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_i2c_master_vci:custom_checker"));
  constant custom_master : i2c_master_t := new_i2c_master(
    speed => i2c_fast_mode_plus,
    stretch_timeout => 100 us,
    id => get_id("tb_i2c_master_vci:custom_master"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );

  constant ignoring_master : i2c_master_t :=
    new_i2c_master(id => get_id("tb_i2c_master_vci:ignoring_master"), unexpected_msg_type_policy => ignore);

  constant target : i2c_target_t := new_i2c_target(address => 16#50#);

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown i2c_master message");

  signal scl : std_logic := 'H';
  signal sda : std_logic := 'H';

begin

  scl <= 'H';
  sda <= 'H';

  default_master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => default_master
    )
    port map (
      scl => scl,
      sda => sda
    );

  custom_master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => custom_master
    )
    port map (
      scl => scl,
      sda => sda
    );

  ignoring_master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => ignoring_master
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

  main : process

    variable data : std_ulogic_vector(15 downto 0);
    variable reference_data : std_ulogic_vector(15 downto 0);
    variable status : i2c_status_t;
    variable reference : i2c_master_reference_t;
    variable result : i2c_result_t;
    variable start : time;

    -- A message of an unknown type, like the VCI tests of the other VCs
    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown i2c_master message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_master))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_master))), "i2c_master", "name of its parent");
        check(get_parent(get_parent(get_id(default_master))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(second_default_master) /= get_id(default_master), "a second default id differs");
        check(speed(default_master) = i2c_fast_mode_plus, "speed");
        check_equal(stretch_timeout(default_master), 25 ms, "default stretch timeout");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_master) = get_logger(get_id(default_master)), "logger of the id");
        check(get_actor(default_master) = find(get_id(default_master), enable_deferred_creation => false), "actor");
        check(as_sync(default_master) = get_actor(default_master), "as_sync");
        check(get_logger(get_checker(default_master)) = get_logger(default_master), "checker on the logger");
        -- No target at 0x51: a check failure on the default logger
        disable_stop(get_logger(default_master), error);
        i2c_write(net, default_master, 16#51#, x"00");
        wait_until_idle(net, as_sync(default_master));
        check_equal(get_log_count(get_logger(default_master), error), 1, "address NACK on the default logger");
        reset_log_count(get_logger(default_master), error);

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_master) = get_id("tb_i2c_master_vci:explicit_master"), "id");
        check_equal(get_full_name(get_logger(explicit_master)), full_name(get_id(explicit_master)), "logger name");
        check(get_actor(explicit_master) = find(get_id(explicit_master), enable_deferred_creation => false), "actor");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_master) = custom_logger, "logger");
        check(get_actor(custom_master) = custom_actor, "actor");
        check(as_sync(custom_master) = custom_actor, "as_sync");
        check(get_checker(custom_master) = custom_checker, "checker");
        disable_stop(get_logger(custom_checker), error);
        i2c_write(net, custom_master, 16#51#, x"00");
        -- The master serves the actor that was passed
        wait_until_idle(net, custom_actor);
        check_equal(get_log_count(get_logger(custom_checker), error), 1, "address NACK on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_master), get_logger(default_master), expect_failure => true);
        -- On the checker of the master, not on its logger
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_master), get_logger(ignoring_master), expect_failure => false);
        i2c_write(net, ignoring_master, 16#50#, x"00", status);
        check(status = i2c_ok, "the master works after the unexpected message");

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_master), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_master));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");
        -- A non-blocking write is done when wait_until_idle returns
        i2c_write(net, default_master, 16#50#, x"00ABCD");
        wait_until_idle(net, as_sync(default_master));
        i2c_target_check_memory(net, target, 0, x"ABCD");

      elsif run("test_blocking_and_reference_variants_agree") then
        i2c_target_preload(net, target, 16#10#, x"1234");
        i2c_write_read(net, default_master, 16#50#, x"10", data);
        i2c_write_read(net, default_master, 16#50#, x"10", 2, reference);
        await_i2c_read_reply(net, reference, reference_data, status);
        check(status = i2c_ok, "status");
        check_equal(reference_data, data, "the same bytes");
        check_equal(data, std_ulogic_vector'(x"1234"), "the bytes");
        i2c_transfer(net, default_master, "S 0xA0 0x10 S 0xA1 R RN P", reference);
        await_i2c_transfer_reply(net, reference, result);
        check_equal(length(result.data), 2, "bytes of the operations");
        check_equal(get(result.data, 1), 16#34#, "the second byte of the operations");
        check_equal(length(result.acks), 3, "acknowledge bits of the operations");
        deallocate(result.data);
        deallocate(result.acks);

      elsif run("test_reset_after_a_transfer_without_stop") then
        i2c_write(net, default_master, 16#50#, x"00", stop => false);
        start := now;
        reset(net, default_master);
        check(sda = 'H' and scl = 'H', "the master releases the bus");
        -- Another master sees the bus busy until the reset of this one
        i2c_write(net, default_master, 16#50#, x"00", status);
        check(status = i2c_ok, "a transfer after the reset");

      elsif run("test_reset_returns_while_scl_is_held_low") then
        disable_stop(get_logger(custom_checker), error);
        i2c_write(net, custom_master, 16#50#, x"00");
        wait for 10 us;
        scl <= '0';
        start := now;
        reset(net, custom_master);
        check(now - start <= 101 us, "the transfer ends after the stretch timeout");
        -- The timeout, and the status the write did not expect
        check_equal(get_log_count(get_logger(custom_checker), error), 2, "SCL held low is a check failure");
        reset_log_count(get_logger(custom_checker), error);
        scl <= 'Z';
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
