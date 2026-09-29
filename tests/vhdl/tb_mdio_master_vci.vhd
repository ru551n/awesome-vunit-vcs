-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the MDIO master VC:
-- ids, loggers, actors and checkers, unexpected messages, sync_pkg, the
-- blocking and non-blocking reads and transfers, the MDC timing and reset.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.mdio_context;

entity tb_mdio_master_vci is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_mdio_master_vci is

  -- The first master with a default id of this architecture
  constant default_master : mdio_master_t := new_mdio_master;
  constant second_default_master : mdio_master_t := new_mdio_master(mdc_period => 1 us);

  constant custom_logger : logger_t := get_logger("tb_mdio_master_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_mdio_master_vci:custom_actor");
  constant custom_checker : checker_t :=
    new_checker(get_logger("tb_mdio_master_vci:custom_checker"));
  constant custom_master : mdio_master_t := new_mdio_master(
    id => get_id("tb_mdio_master_vci:custom_master"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );

  constant ignoring_master : mdio_master_t := new_mdio_master(
    id => get_id("tb_mdio_master_vci:ignoring_master"),
    unexpected_msg_type_policy => ignore
  );

  constant phy : mdio_phy_t := new_mdio_phy(phy_address => 1);

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown mdio_master message");

  signal mdc : std_ulogic;
  signal mdio : std_logic := 'H';

begin

  mdio <= 'H';

  -- Only the default master drives the bus; the others take messages only
  master_inst : entity awesome_vunit_vcs.mdio_master
    generic map (
      master => default_master
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  second_master_inst : entity awesome_vunit_vcs.mdio_master
    generic map (
      master => second_default_master
    )
    port map (
      mdc => open,
      mdio => open
    );

  custom_master_inst : entity awesome_vunit_vcs.mdio_master
    generic map (
      master => custom_master
    )
    port map (
      mdc => open,
      mdio => open
    );

  ignoring_master_inst : entity awesome_vunit_vcs.mdio_master
    generic map (
      master => ignoring_master
    )
    port map (
      mdc => open,
      mdio => open
    );

  phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  main : process

    variable data : std_ulogic_vector(15 downto 0);
    variable reference_data : std_ulogic_vector(15 downto 0);
    variable reference : mdio_master_reference_t;
    variable sampled : std_ulogic_vector(0 to 63);
    variable reference_sampled : std_ulogic_vector(0 to 63);
    variable start : time;

    procedure check_unexpected_message(
      actor : actor_t;
      logger : logger_t;
      expect_failure : boolean
    )is
      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown mdio_master message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end procedure;

  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_master))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_master))), "mdio_master", "name of its parent");
        check(
          get_parent(get_parent(get_id(default_master))) = get_id("awesome_vunit_vcs"),
          "grandparent"
        );
        check(
          get_id(second_default_master) /= get_id(default_master),
          "a second default id differs"
        );
        check_equal(mdc_period(default_master), 400 ns, "default MDC period");
        check_equal(preamble_bits(default_master), 32, "default preamble");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_master) = get_logger(get_id(default_master)), "logger of the id");
        check(
          get_actor(default_master)
          = find(get_id(default_master), enable_deferred_creation => false),
          "actor"
        );
        check(as_sync(default_master) = get_actor(default_master), "as_sync");
        check(
          get_logger(get_checker(default_master)) = get_logger(default_master),
          "checker on the logger"
        );

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_master) = custom_logger, "logger");
        check(get_actor(custom_master) = custom_actor, "actor");
        check(as_sync(custom_master) = custom_actor, "as_sync");
        check(get_checker(custom_master) = custom_checker, "checker");

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(
          get_actor(default_master),
          get_logger(default_master),
          expect_failure => true
        );
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(
          get_actor(ignoring_master),
          get_logger(ignoring_master),
          expect_failure => false
        );

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_master), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_master));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");
        start := now;
        write_mdio(net, default_master, 1, 0, x"0001");
        check_equal(now, start, "write_mdio returns at once");
        wait_until_idle(net, as_sync(default_master));
        check_equal(now - start, 64 * 400 ns, "a frame takes 64 MDC periods");

      elsif run("test_blocking_and_reference_variants_agree") then
        write_mdio(net, default_master, 1, 3, x"C0DE");
        read_mdio(net, default_master, 1, 3, data);
        read_mdio(net, default_master, 1, 3, reference);
        await_read_mdio_reply(net, reference, reference_data);
        check_equal(data, std_ulogic_vector'(x"C0DE"), "blocking read");
        check_equal(reference_data, data, "reference read");
        transfer_mdio(net, default_master, mdio_frame(mdio_read_op, 1, 3), sampled);
        transfer_mdio(net, default_master, mdio_frame(mdio_read_op, 1, 3), reference);
        await_transfer_mdio_reply(net, reference, reference_sampled);
        check_equal(sampled(48 to 63), std_ulogic_vector'(x"C0DE"), "blocking transfer");
        check_equal(reference_sampled, sampled, "reference transfer");

      elsif run("test_mdc_timing") then
        write_mdio(net, default_master, 1, 0, x"0000");
        wait until rising_edge(mdc);
        start := now;
        wait until falling_edge(mdc);
        check_equal(now - start, 200 ns, "MDC high");
        wait until rising_edge(mdc);
        check_equal(now - start, 400 ns, "MDC period");
        wait_until_idle(net, as_sync(default_master));
        set_mdio_master_mdc_period(net, default_master, 1 us);
        write_mdio(net, default_master, 1, 0, x"0000");
        wait until rising_edge(mdc);
        start := now;
        wait until rising_edge(mdc);
        check_equal(now - start, 1 us, "the new MDC period");

      elsif run("test_mdio_changes_when_mdc_falls") then
        write_mdio(net, default_master, 1, 0, x"5555");
        -- The 25 changes of MDIO in the frame, and its release
        for change in 0 to 25 loop

          wait on mdio;
          check_equal(mdc, '0', "MDC when MDIO changes");
        end loop;

      elsif run("test_reset_releases_mdio") then
        write_mdio(net, default_master, 1, 0, x"0000");
        start := now;
        reset(net, default_master);
        check_equal(now - start, 64 * 400 ns, "reset waits for the frame");
        check_equal(mdio, 'H', "MDIO released");
        check_equal(mdc, '0', "MDC low");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);

end architecture;
