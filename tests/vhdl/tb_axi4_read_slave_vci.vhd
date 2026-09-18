-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the AXI4 read slave
-- VC: ids, loggers, actors and checkers, the identity of its memory,
-- unexpected messages, sync_pkg, reset with a stopped clock and ARESETn, and
-- the narrowest and widest buses, AXI3 included.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_read_slave_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_read_slave_vci is

  constant memory : axi4_memory_t := new_axi4_memory;
  -- The first slave with a default id of this architecture
  constant default_slave : axi4_slave_t := new_axi4_slave(memory);

  constant custom_logger : logger_t := get_logger("tb_axi4_read_slave_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_axi4_read_slave_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_axi4_read_slave_vci:custom_checker"));
  constant custom_slave : axi4_slave_t := new_axi4_slave(
    memory,
    id => get_id("tb_axi4_read_slave_vci:custom_slave"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );
  constant ignoring_slave : axi4_slave_t :=
    new_axi4_slave(memory, id => get_id("tb_axi4_read_slave_vci:ignoring_slave"), unexpected_msg_type_policy => ignore);
  -- An 8-bit AXI3 bus with 12-bit addresses, and a 1024-bit bus with 64-bit addresses
  constant narrow_slave : axi4_slave_t := new_axi4_slave(
    memory,
    new_axi4_bus(data_length => 8, address_length => 12, id_length => 1),
    id => get_id("tb_axi4_read_slave_vci:narrow_slave")
  );
  constant wide_slave : axi4_slave_t := new_axi4_slave(
    memory,
    new_axi4_bus(data_length => 1024, address_length => 64, id_length => 8),
    id => get_id("tb_axi4_read_slave_vci:wide_slave")
  );

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown axi4_read_slave message");

  type slave_array_t is array (natural range <>) of axi4_slave_t;

  constant slaves : slave_array_t(0 to 2) := (default_slave, custom_slave, ignoring_slave);

  signal aclk : std_ulogic := '0';
  signal clock_enabled : boolean := true;
  signal aresetn : std_ulogic := '1';
  signal arvalid : std_ulogic := '0';
  signal araddr : std_ulogic_vector(31 downto 0) := (others => '0');
  signal rready : std_ulogic := '1';
  signal rvalid : std_ulogic_vector(slaves'range);

  signal narrow_arvalid : std_ulogic := '0';
  signal narrow_arready : std_ulogic := '0';
  signal narrow_rvalid : std_ulogic := '0';
  signal narrow_araddr : std_ulogic_vector(11 downto 0) := (others => '0');
  signal narrow_rdata : std_ulogic_vector(7 downto 0);
  signal narrow_rlast : std_ulogic;
  signal wide_arvalid : std_ulogic := '0';
  signal wide_arready : std_ulogic := '0';
  signal wide_rvalid : std_ulogic := '0';
  signal wide_araddr : std_ulogic_vector(63 downto 0) := (others => '0');
  signal wide_rdata : std_ulogic_vector(1023 downto 0);

begin

  aclk <= not aclk after 5 ns when clock_enabled;

  slaves_gen : for idx in slaves'range generate
    axi4_read_slave_inst : entity awesome_vunit_vcs.axi4_read_slave
      generic map (
        axi_slave => slaves(idx)
      )
      port map (
        aclk => aclk,
        aresetn => aresetn,
        arvalid => arvalid,
        araddr => araddr,
        arlen => x"03",
        rvalid => rvalid(idx),
        rready => rready
      );

  end generate slaves_gen;

  narrow_slave_inst : entity awesome_vunit_vcs.axi4_read_slave
    generic map (
      axi_slave => narrow_slave
    )
    port map (
      aclk => aclk,
      arvalid => narrow_arvalid,
      arready => narrow_arready,
      araddr => narrow_araddr,
      arlen => x"1",
      rvalid => narrow_rvalid,
      rready => '1',
      rdata => narrow_rdata,
      rlast => narrow_rlast
    );

  wide_slave_inst : entity awesome_vunit_vcs.axi4_read_slave
    generic map (
      axi_slave => wide_slave
    )
    port map (
      aclk => aclk,
      arvalid => wide_arvalid,
      arready => wide_arready,
      araddr => wide_araddr,
      arlen => x"00",
      rvalid => wide_rvalid,
      rready => '1',
      rdata => wide_rdata
    );

  main : process

    variable start : time;

    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown axi4_read_slave message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    wait until rising_edge(aclk);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_slave))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_slave))), "axi4_slave", "name of its parent");
        check(get_parent(get_parent(get_id(default_slave))) = get_id("awesome_vunit_vcs"), "grandparent");
        check_equal(name(get_parent(get_id(memory))), "axi4_memory", "the parent of the memory id");
        check(get_bus(default_slave) = default_axi4_bus, "its bus");
        check(get_memory(default_slave) = memory, "its memory");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_slave) = get_logger(get_id(default_slave)), "logger of the id");
        check(get_actor(default_slave) = find(get_id(default_slave), enable_deferred_creation => false), "actor");
        check(as_sync(default_slave) = get_actor(default_slave), "as_sync");
        check(get_logger(get_checker(default_slave)) = get_logger(default_slave), "checker on the logger");
        check(get_logger(get_checker(memory)) = get_logger(memory), "the checker of the memory");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_slave) = custom_logger, "logger");
        check(get_actor(custom_slave) = custom_actor, "actor");
        check(get_checker(custom_slave) = custom_checker, "checker");
        -- A failure of the slave is logged on its checker: 4 beats from 0xFFF
        -- cross 4 KB, which all three slaves on these pins see
        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(default_slave), error);
        disable_stop(get_logger(ignoring_slave), error);
        arvalid <= '1';
        araddr <= x"0000_0FFF";
        wait until rising_edge(aclk);
        arvalid <= '0';
        for idx in slaves'range loop

          wait_until_idle(net, as_sync(slaves(idx)));
        end loop;

        check_equal(get_log_count(get_logger(custom_checker), error), 1, "a failure on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);
        reset_log_count(get_logger(default_slave), error);
        reset_log_count(get_logger(ignoring_slave), error);

      elsif run("test_unexpected_message_is_a_check_failure") then
        check_unexpected_message(get_actor(default_slave), get_logger(default_slave), expect_failure => true);
        check_unexpected_message(custom_actor, get_logger(custom_checker), expect_failure => true);

      elsif run("test_unexpected_message_is_ignored") then
        check_unexpected_message(get_actor(ignoring_slave), get_logger(ignoring_slave), expect_failure => false);

      elsif run("test_wait_until_idle_and_wait_for_time") then
        start := now;
        wait_for_time(net, as_sync(default_slave), 1 us);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_slave));
        check_equal(now - start, 1 us, "wait_until_idle waits for the requested time");
        -- A burst in progress keeps the slave busy until its last beat
        set_response_latency(net, default_slave, 100 ns);
        arvalid <= '1';
        wait until rising_edge(aclk);
        arvalid <= '0';
        start := now;
        wait_until_idle(net, as_sync(default_slave));
        check(now - start >= 100 ns + 3 * 10 ns, "idle after the 4 beats");
        wait_until_idle(net, as_sync(custom_slave));
        wait_until_idle(net, as_sync(ignoring_slave));

      elsif run("test_reset_returns_with_a_stopped_clock") then
        set_response_latency(net, default_slave, 100 ns);
        arvalid <= '1';
        wait until rising_edge(aclk);
        arvalid <= '0';
        clock_enabled <= false;
        wait for 20 ns;
        start := now;
        reset(net, default_slave);
        check_equal(now, start, "reset returns without clock edges");
        wait_until_idle(net, as_sync(default_slave));
        clock_enabled <= true;
        for idx in 0 to 20 loop

          wait until rising_edge(aclk);
          check_equal(rvalid(0), '0', "no data after the reset");
        end loop;

      elsif run("test_aresetn_drops_the_bursts") then
        set_response_latency(net, default_slave, 50 ns);
        arvalid <= '1';
        wait until rising_edge(aclk);
        arvalid <= '0';
        aresetn <= '0';
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait_until_idle(net, as_sync(default_slave));
        for idx in 0 to 20 loop

          wait until rising_edge(aclk);
          check_equal(rvalid(0), '0', "no data after ARESETn");
        end loop;

      elsif run("test_narrow_axi3_and_wide_buses") then
        write_byte(memory, 16#10#, 16#AB#);
        write_byte(memory, 16#11#, 16#CD#);
        narrow_araddr <= x"010";
        narrow_arvalid <= '1';
        wait until (narrow_arvalid and narrow_arready) = '1' and rising_edge(aclk);
        narrow_arvalid <= '0';
        wait until narrow_rvalid = '1' and rising_edge(aclk);
        check_equal(narrow_rdata, std_ulogic_vector'(x"AB"));
        check_equal(narrow_rlast, '0');
        wait until narrow_rvalid = '1' and rising_edge(aclk);
        check_equal(narrow_rdata, std_ulogic_vector'(x"CD"));
        check_equal(narrow_rlast, '1');
        write_word(memory, x"FFFF_0000_0000_0000", x"0123456789");
        wide_araddr <= x"FFFF_0000_0000_0000";
        wide_arvalid <= '1';
        wait until (wide_arvalid and wide_arready) = '1' and rising_edge(aclk);
        wide_arvalid <= '0';
        wait until wide_rvalid = '1' and rising_edge(aclk);
        check_equal(wide_rdata(39 downto 0), std_ulogic_vector'(x"0123456789"));
        check_equal(wide_rdata(1023 downto 1016), std_ulogic_vector'(x"00"));
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);

end architecture;
