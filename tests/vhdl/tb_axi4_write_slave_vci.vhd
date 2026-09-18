-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the AXI4 write slave
-- VC: ids, loggers, actors and checkers, unexpected messages, sync_pkg, reset
-- with a stopped clock and ARESETn, and the narrowest and widest buses, AXI3
-- included.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_write_slave_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_write_slave_vci is

  constant memory : axi4_memory_t := new_axi4_memory;
  -- The first slave with a default id of this architecture
  constant default_slave : axi4_slave_t := new_axi4_slave(memory);

  constant custom_logger : logger_t := get_logger("tb_axi4_write_slave_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_axi4_write_slave_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_axi4_write_slave_vci:custom_checker"));
  constant custom_slave : axi4_slave_t := new_axi4_slave(
    memory,
    id => get_id("tb_axi4_write_slave_vci:custom_slave"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );
  constant ignoring_slave : axi4_slave_t := new_axi4_slave(
    memory,
    id => get_id("tb_axi4_write_slave_vci:ignoring_slave"),
    unexpected_msg_type_policy => ignore
  );
  -- An 8-bit AXI3 bus with 12-bit addresses, and a 1024-bit bus with 64-bit addresses
  constant narrow_slave : axi4_slave_t := new_axi4_slave(
    memory,
    new_axi4_bus(data_length => 8, address_length => 12, id_length => 1),
    id => get_id("tb_axi4_write_slave_vci:narrow_slave")
  );
  constant wide_slave : axi4_slave_t := new_axi4_slave(
    memory,
    new_axi4_bus(data_length => 1024, address_length => 64, id_length => 8),
    id => get_id("tb_axi4_write_slave_vci:wide_slave")
  );

  constant unknown_msg_type : msg_type_t := new_msg_type("unknown axi4_write_slave message");

  type slave_array_t is array (natural range <>) of axi4_slave_t;

  constant slaves : slave_array_t(0 to 2) := (default_slave, custom_slave, ignoring_slave);

  signal aclk : std_ulogic := '0';
  signal clock_enabled : boolean := true;
  signal aresetn : std_ulogic := '1';
  signal awvalid, wvalid : std_ulogic := '0';
  signal awaddr : std_ulogic_vector(31 downto 0) := (others => '0');
  signal wdata : std_ulogic_vector(31 downto 0) := (others => '0');
  signal bready : std_ulogic := '1';
  signal wready, bvalid : std_ulogic_vector(slaves'range);

  signal narrow_awvalid : std_ulogic := '0';
  signal narrow_awready : std_ulogic := '0';
  signal narrow_wvalid : std_ulogic := '0';
  signal narrow_wready : std_ulogic := '0';
  signal narrow_bvalid : std_ulogic := '0';
  signal narrow_awaddr : std_ulogic_vector(11 downto 0) := (others => '0');
  signal narrow_wdata : std_ulogic_vector(7 downto 0) := (others => '0');
  signal narrow_wlast : std_ulogic := '0';
  signal wide_awvalid : std_ulogic := '0';
  signal wide_awready : std_ulogic := '0';
  signal wide_wvalid : std_ulogic := '0';
  signal wide_wready : std_ulogic := '0';
  signal wide_bvalid : std_ulogic := '0';
  signal wide_awaddr : std_ulogic_vector(63 downto 0) := (others => '0');
  signal wide_wdata : std_ulogic_vector(1023 downto 0) := (others => '0');

begin

  aclk <= not aclk after 5 ns when clock_enabled;

  slaves_gen : for idx in slaves'range generate
    axi4_write_slave_inst : entity awesome_vunit_vcs.axi4_write_slave
      generic map (
        axi_slave => slaves(idx)
      )
      port map (
        aclk => aclk,
        aresetn => aresetn,
        awvalid => awvalid,
        awaddr => awaddr,
        awlen => x"00",
        wvalid => wvalid,
        wready => wready(idx),
        wdata => wdata,
        bvalid => bvalid(idx),
        bready => bready
      );

  end generate slaves_gen;

  narrow_slave_inst : entity awesome_vunit_vcs.axi4_write_slave
    generic map (
      axi_slave => narrow_slave
    )
    port map (
      aclk => aclk,
      awvalid => narrow_awvalid,
      awready => narrow_awready,
      awaddr => narrow_awaddr,
      awlen => x"1",
      wvalid => narrow_wvalid,
      wready => narrow_wready,
      wdata => narrow_wdata,
      wlast => narrow_wlast,
      bvalid => narrow_bvalid,
      bready => '1'
    );

  wide_slave_inst : entity awesome_vunit_vcs.axi4_write_slave
    generic map (
      axi_slave => wide_slave
    )
    port map (
      aclk => aclk,
      awvalid => wide_awvalid,
      awready => wide_awready,
      awaddr => wide_awaddr,
      awlen => x"00",
      wvalid => wide_wvalid,
      wready => wide_wready,
      wdata => wide_wdata,
      bvalid => wide_bvalid,
      bready => '1'
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
        check_only_log(logger, "Got unexpected message unknown axi4_write_slave message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

    -- One single beat burst to the three slaves on the shared pins
    procedure write (address : natural; data : std_ulogic_vector(31 downto 0)) is
    begin

      awvalid <= '1';
      awaddr <= std_ulogic_vector(to_unsigned(address, 32));
      wait until rising_edge(aclk);
      awvalid <= '0';
      wvalid <= '1';
      wdata <= data;
      wait until rising_edge(aclk) and wready = "111";
      wvalid <= '0';
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    wait until rising_edge(aclk);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_slave))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_slave))), "axi4_slave", "name of its parent");
        check(get_parent(get_parent(get_id(default_slave))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_bus(default_slave) = default_axi4_bus, "its bus");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_slave) = get_logger(get_id(default_slave)), "logger of the id");
        check(get_actor(default_slave) = find(get_id(default_slave), enable_deferred_creation => false), "actor");
        check(as_sync(default_slave) = get_actor(default_slave), "as_sync");
        check(get_logger(get_checker(default_slave)) = get_logger(default_slave), "checker on the logger");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_slave) = custom_logger, "logger");
        check(get_actor(custom_slave) = custom_actor, "actor");
        check(get_checker(custom_slave) = custom_checker, "checker");
        -- A failure of the slave is logged on its checker: the three slaves on
        -- these pins write a byte that expects another value
        set_expected_byte(memory, 16#40#, 16#55#);
        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(default_slave), error);
        disable_stop(get_logger(ignoring_slave), error);
        write(16#40#, x"00000000");
        for idx in slaves'range loop

          wait_until_idle(net, as_sync(slaves(idx)));
        end loop;

        check_equal(get_log_count(get_logger(custom_checker), error), 1, "a failure on the custom checker");
        check_equal(get_log_count(custom_logger, error), 0, "errors on the custom logger");
        reset_log_count(get_logger(custom_checker), error);
        reset_log_count(get_logger(default_slave), error);
        reset_log_count(get_logger(ignoring_slave), error);
        clear_expected_byte(memory, 16#40#);

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
        -- A burst keeps the slave busy until its write response
        set_response_latency(net, default_slave, 100 ns);
        write(16#10#, x"12345678");
        start := now;
        wait_until_idle(net, as_sync(default_slave));
        check(now - start >= 90 ns, "idle after the write response");
        check_equal(read_word(memory, 16#10#, 4), std_ulogic_vector'(x"12345678"));
        wait_until_idle(net, as_sync(custom_slave));
        wait_until_idle(net, as_sync(ignoring_slave));

      elsif run("test_reset_returns_with_a_stopped_clock") then
        set_response_latency(net, default_slave, 100 ns);
        write(16#20#, x"11111111");
        clock_enabled <= false;
        wait for 20 ns;
        start := now;
        reset(net, default_slave);
        check_equal(now, start, "reset returns without clock edges");
        wait_until_idle(net, as_sync(default_slave));
        clock_enabled <= true;
        for idx in 0 to 20 loop

          wait until rising_edge(aclk);
          check_equal(bvalid(0), '0', "no write response after the reset");
        end loop;

      elsif run("test_aresetn_drops_the_bursts") then
        set_response_latency(net, default_slave, 50 ns);
        write(16#30#, x"22222222");
        aresetn <= '0';
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait_until_idle(net, as_sync(default_slave));
        for idx in 0 to 20 loop

          wait until rising_edge(aclk);
          check_equal(bvalid(0), '0', "no write response after ARESETn");
        end loop;

      elsif run("test_narrow_axi3_and_wide_buses") then
        narrow_awaddr <= x"010";
        narrow_awvalid <= '1';
        wait until (narrow_awvalid and narrow_awready) = '1' and rising_edge(aclk);
        narrow_awvalid <= '0';
        for beat in 0 to 1 loop

          narrow_wdata <= std_ulogic_vector(to_unsigned(16#AB# + beat, 8));
          narrow_wlast <= '1' when beat = 1 else
                          '0';
          narrow_wvalid <= '1';
          wait until (narrow_wvalid and narrow_wready) = '1' and rising_edge(aclk);
          narrow_wvalid <= '0';
        end loop;

        wait until narrow_bvalid = '1' and rising_edge(aclk);
        check_equal(read_word(memory, 16#10#, 2), std_ulogic_vector'(x"ACAB"));
        wide_awaddr <= x"FFFF_0000_0000_0000";
        wide_awvalid <= '1';
        wait until (wide_awvalid and wide_awready) = '1' and rising_edge(aclk);
        wide_awvalid <= '0';
        wide_wdata(39 downto 0) <= x"0123456789";
        wide_wdata(1023 downto 1016) <= x"EE";
        wide_wvalid <= '1';
        wait until (wide_wvalid and wide_wready) = '1' and rising_edge(aclk);
        wide_wvalid <= '0';
        wait until wide_bvalid = '1' and rising_edge(aclk);
        check_equal(read_word(memory, x"FFFF_0000_0000_0000", 5), std_ulogic_vector'(x"0123456789"));
        check_equal(read_byte(memory, x"FFFF_0000_0000_007F"), 16#EE#);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);

end architecture;
