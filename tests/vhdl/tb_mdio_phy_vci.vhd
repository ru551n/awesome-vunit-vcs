-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the MDIO PHY VC:
-- ids, loggers, actors and checkers, unexpected messages, sync_pkg, the
-- blocking and non-blocking register reads, independent backends and a device
-- model of your own.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.mdio_context;

entity tb_mdio_phy_vci is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_mdio_phy_vci is

  -- The first PHY with a default id of this architecture
  constant default_phy : mdio_phy_t := new_mdio_phy(phy_address => 1);
  constant second_default_phy : mdio_phy_t := new_mdio_phy(phy_address => 2);

  constant explicit_phy : mdio_phy_t :=
    new_mdio_phy(phy_address => 3, id => get_id("tb_mdio_phy_vci:explicit_phy"));

  constant custom_logger : logger_t := get_logger("tb_mdio_phy_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_mdio_phy_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_mdio_phy_vci:custom_checker"));
  constant custom_phy : mdio_phy_t := new_mdio_phy(
    phy_address => 4,
    id => get_id("tb_mdio_phy_vci:custom_phy"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );

  constant ignoring_phy : mdio_phy_t := new_mdio_phy(
    phy_address => 5,
    id => get_id("tb_mdio_phy_vci:ignoring_phy"),
    unexpected_msg_type_policy => ignore
  );

  -- A device model of tests/vhdl/python/mdio_models.py with initial registers
  constant model_phy : mdio_phy_t := new_mdio_phy(
    phy_address => 6,
    model => "mdio_models:SelfClearingReset",
    model_args => kwarg("id_1", 16#0141#),
    id => get_id("tb_mdio_phy_vci:model_phy")
  );

  constant master : mdio_master_t := new_mdio_master(mdc_period => 100 ns);

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown mdio_phy message");

  signal mdc : std_ulogic;
  signal mdio : std_logic := 'H';

begin

  mdio <= 'H';

  master_inst : entity awesome_vunit_vcs.mdio_master
    generic map (
      master => master
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  default_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => default_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  second_default_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => second_default_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  custom_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => custom_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  ignoring_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => ignoring_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  model_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => model_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  main : process

    variable data : std_ulogic_vector(15 downto 0);
    variable reference_data : std_ulogic_vector(15 downto 0);
    variable reference : mdio_phy_reference_t;
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
        check_only_log(logger, "Got unexpected message unknown mdio_phy message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end procedure;

  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_phy))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_phy))), "mdio_phy", "name of its parent");
        check(
          get_parent(get_parent(get_id(default_phy))) = get_id("awesome_vunit_vcs"),
          "grandparent"
        );
        check(get_id(second_default_phy) /= get_id(default_phy), "a second default id differs");
        check_equal(phy_address(default_phy), 1, "address");
        check_equal(clock_to_output_delay(default_phy), 0 ns, "default clock-to-output delay");
        check_equal(preamble_bits(default_phy), 32, "default preamble");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_phy) = get_logger(get_id(default_phy)), "logger of the id");
        check(
          get_actor(default_phy) = find(get_id(default_phy), enable_deferred_creation => false),
          "actor"
        );
        check(as_sync(default_phy) = get_actor(default_phy), "as_sync");
        check(
          get_logger(get_checker(default_phy)) = get_logger(default_phy),
          "checker on the logger"
        );
        disable_stop(get_logger(default_phy), error);
        check_mdio_phy_register(net, default_phy, 0, x"0001");
        wait_until_idle(net, as_sync(default_phy));
        check_equal(
          get_log_count(get_logger(default_phy), error),
          1,
          "a difference on the default logger"
        );
        reset_log_count(get_logger(default_phy), error);

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_phy) = get_id("tb_mdio_phy_vci:explicit_phy"), "id");
        check_equal(
          get_full_name(get_logger(explicit_phy)),
          full_name(get_id(explicit_phy)),
          "logger name"
        );
        check(
          get_actor(explicit_phy) = find(get_id(explicit_phy), enable_deferred_creation => false),
          "actor"
        );

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_phy) = custom_logger, "logger");
        check(get_actor(custom_phy) = custom_actor, "actor");
        check(as_sync(custom_phy) = custom_actor, "as_sync");
        check(get_checker(custom_phy) = custom_checker, "checker");
        disable_stop(get_logger(custom_checker), error);
        check_mdio_phy_register(net, custom_phy, 0, x"0001", "custom");
        wait_until_idle(net, custom_actor);
        check_equal(
          get_log_count(get_logger(custom_checker), error),
          1,
          "a difference on the custom checker"
        );
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(
          get_actor(default_phy),
          get_logger(default_phy),
          expect_failure => true
        );
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(
          get_actor(ignoring_phy),
          get_logger(ignoring_phy),
          expect_failure => false
        );
        write_mdio(net, master, 5, 0, x"00AA");
        read_mdio(net, master, 5, 0, data);
        check_equal(
          data,
          std_ulogic_vector'(x"00AA"),
          "the PHY answers after the unexpected message"
        );

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_phy), 1 ms);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_phy));
        check_equal(now - start, 1 ms, "wait_until_idle waits for the requested time");

      elsif run("test_blocking_and_reference_variants_agree") then
        set_mdio_phy_register(net, default_phy, 7, x"BEEF");
        get_mdio_phy_register(net, default_phy, 7, data);
        get_mdio_phy_register(net, default_phy, 7, reference);
        await_get_mdio_phy_register_reply(net, reference, reference_data);
        check_equal(data, std_ulogic_vector'(x"BEEF"), "blocking");
        check_equal(reference_data, data, "reference");

      elsif run("test_default_instances_have_independent_backends") then
        write_mdio(net, master, 1, 0, x"0011");
        write_mdio(net, master, 2, 0, x"0022");
        wait_until_idle(net, as_sync(master));
        check_mdio_phy_register(net, default_phy, 0, x"0011");
        check_mdio_phy_register(net, second_default_phy, 0, x"0022");

      elsif run("test_device_model_of_your_own") then
        read_mdio(net, master, 6, 2, data);
        check_equal(data, std_ulogic_vector'(x"0141"), "the initial register of the model");
        write_mdio(net, master, 6, 0, x"9140");
        read_mdio(net, master, 6, 0, data);
        check_equal(data, std_ulogic_vector'(x"1140"), "the reset bit clears itself");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);

end architecture;
