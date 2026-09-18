-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Verification component interface (VCI) conformance of the AXI4 monitor VC:
-- ids, loggers, actors and checkers, its protocol checker, unexpected
-- messages, sync_pkg, publishing, the blocking and non-blocking pops and
-- statistics, metavalues and reset.
--
-- Expected values that involve a default id are taken from the handle, never
-- written as enumerated literals.

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_monitor_vci is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_monitor_vci is

  -- The first monitor with a default id of this architecture
  constant default_monitor : axi4_monitor_t := new_axi4_monitor(default_axi4_bus);
  constant checked_monitor : axi4_monitor_t :=
    new_axi4_monitor(default_axi4_bus, protocol_checker => new_axi4_protocol_checker);

  constant explicit_monitor : axi4_monitor_t :=
    new_axi4_monitor(default_axi4_bus, id => get_id("tb_axi4_monitor_vci:explicit_monitor"));

  constant custom_logger : logger_t := get_logger("tb_axi4_monitor_vci:custom_logger");
  constant custom_actor : actor_t := new_actor("tb_axi4_monitor_vci:custom_actor");
  constant custom_checker : checker_t := new_checker(get_logger("tb_axi4_monitor_vci:custom_checker"));
  constant custom_monitor : axi4_monitor_t := new_axi4_monitor(
    default_axi4_bus,
    id => get_id("tb_axi4_monitor_vci:custom_monitor"),
    logger => custom_logger,
    actor => custom_actor,
    checker => custom_checker
  );

  constant ignoring_monitor : axi4_monitor_t := new_axi4_monitor(
    default_axi4_bus,
    id => get_id("tb_axi4_monitor_vci:ignoring_monitor"),
    unexpected_msg_type_policy => ignore
  );

  -- The narrowest and the widest data bus, with 64-bit addresses and USER signals
  constant narrow_monitor : axi4_monitor_t := new_axi4_monitor(
    new_axi4_bus(data_length => 8, address_length => 12, id_length => 1),
    protocol_checker => new_axi4_protocol_checker,
    id => get_id("tb_axi4_monitor_vci:narrow_monitor")
  );
  constant wide_monitor : axi4_monitor_t := new_axi4_monitor(
    new_axi4_bus(
      data_length => 1024,
      address_length => 64,
      id_length => 8,
      awuser_length => 5,
      wuser_length => 3,
      buser_length => 2
    ),
    protocol_checker => new_axi4_protocol_checker,
    id => get_id("tb_axi4_monitor_vci:wide_monitor")
  );

  constant subscriber : actor_t := new_actor("tb_axi4_monitor_vci:subscriber");
  constant unknown_msg_type : msg_type_t := new_msg_type("unknown axi4_monitor message");

  type monitor_array_t is array (natural range <>) of axi4_monitor_t;

  constant monitors : monitor_array_t(0 to 3) := (default_monitor, checked_monitor, custom_monitor, ignoring_monitor);

  signal aclk : std_ulogic := '0';
  signal awvalid : std_ulogic := '0';
  signal awready : std_ulogic := '0';
  signal wvalid : std_ulogic := '0';
  signal wready : std_ulogic := '0';
  signal bvalid : std_ulogic := '0';
  signal bready : std_ulogic := '0';
  signal awaddr : std_ulogic_vector(31 downto 0) := (others => '0');
  signal wdata : std_ulogic_vector(31 downto 0) := (others => '0');
  signal narrow_awaddr : std_ulogic_vector(11 downto 0) := (others => '0');
  signal narrow_wdata : std_ulogic_vector(7 downto 0) := (others => '0');
  signal wide_awid : std_ulogic_vector(7 downto 0) := (others => '0');
  signal wide_awaddr : std_ulogic_vector(63 downto 0) := (others => '0');
  signal wide_wdata : std_ulogic_vector(1023 downto 0) := (others => '0');

begin

  aclk <= not aclk after 5 ns;

  monitors_gen : for idx in monitors'range generate
    monitor_inst : entity awesome_vunit_vcs.axi4_monitor
      generic map (
        monitor => monitors(idx)
      )
      port map (
        aclk => aclk,
        awvalid => awvalid,
        awready => awready,
        awaddr => awaddr,
        wvalid => wvalid,
        wready => wready,
        wdata => wdata,
        bvalid => bvalid,
        bready => bready
      );

  end generate monitors_gen;

  narrow_monitor_inst : entity awesome_vunit_vcs.axi4_monitor
    generic map (
      monitor => narrow_monitor
    )
    port map (
      aclk => aclk,
      awvalid => awvalid,
      awready => awready,
      awaddr => narrow_awaddr,
      wvalid => wvalid,
      wready => wready,
      wdata => narrow_wdata,
      bvalid => bvalid,
      bready => bready
    );

  wide_monitor_inst : entity awesome_vunit_vcs.axi4_monitor
    generic map (
      monitor => wide_monitor
    )
    port map (
      aclk => aclk,
      awvalid => awvalid,
      awready => awready,
      awid => wide_awid,
      awaddr => wide_awaddr,
      awuser => "10101",
      wvalid => wvalid,
      wready => wready,
      wdata => wide_wdata,
      wuser => "111",
      bvalid => bvalid,
      bready => bready,
      bid => wide_awid,
      buser => "01"
    );

  main : process

    variable transaction : axi4_transaction_t;
    variable reference_transaction : axi4_transaction_t;
    variable reference : axi4_monitor_reference_t;
    variable statistics : axi4_statistics_t;
    variable reference_statistics : axi4_statistics_t;
    variable msg : msg_t;
    variable start : time;
    variable start_count : natural;

    procedure check_unexpected_message (actor : actor_t; logger : logger_t; expect_failure : boolean) is

      variable request_msg : msg_t;
    begin

      mock(logger, error);
      request_msg := new_msg(unknown_msg_type);
      send(net, actor, request_msg);
      wait_until_idle(net, actor);
      if expect_failure then
        check_only_log(logger, "Got unexpected message unknown axi4_monitor message", error);
      else
        check_no_log;
      end if;
      unmock(logger);
    end;

    -- A single beat write: AW and W in one cycle, B in the next
    procedure write (address : natural; data : std_ulogic_vector(31 downto 0)) is
    begin

      awvalid <= '1';
      awready <= '1';
      awaddr <= std_ulogic_vector(to_unsigned(address, 32));
      wvalid <= '1';
      wready <= '1';
      wdata <= data;
      wait until rising_edge(aclk);
      awvalid <= '0';
      wvalid <= '0';
      bvalid <= '1';
      bready <= '1';
      wait until rising_edge(aclk);
      bvalid <= '0';
      bready <= '0';
      wait until rising_edge(aclk);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    wait until rising_edge(aclk);

    while test_suite loop

      if run("test_default_id_is_enumerated") then
        check(integer'value(name(get_id(default_monitor))) >= 1, "the default id is enumerated");
        check_equal(name(get_parent(get_id(default_monitor))), "axi4_monitor", "name of its parent");
        check(get_parent(get_parent(get_id(default_monitor))) = get_id("awesome_vunit_vcs"), "grandparent");
        check(get_id(checked_monitor) /= get_id(default_monitor), "a second default id differs");
        check(protocol_checker(default_monitor) = null_axi4_protocol_checker, "no protocol checker");
        check(get_bus(default_monitor) = default_axi4_bus, "its bus");

      elsif run("test_default_logger_actor_and_checker_are_used") then
        check(get_logger(default_monitor) = get_logger(get_id(default_monitor)), "logger of the id");
        check(get_actor(default_monitor) = find(get_id(default_monitor), enable_deferred_creation => false), "actor");
        check(as_sync(default_monitor) = get_actor(default_monitor), "as_sync");
        check(get_logger(get_checker(default_monitor)) = get_logger(default_monitor), "checker on the logger");

      elsif run("test_explicit_id_is_used") then
        check(get_id(explicit_monitor) = get_id("tb_axi4_monitor_vci:explicit_monitor"), "id");
        check_equal(get_full_name(get_logger(explicit_monitor)), full_name(get_id(explicit_monitor)), "logger name");

      elsif run("test_custom_logger_actor_and_checker_are_used") then
        check(get_logger(custom_monitor) = custom_logger, "logger");
        check(get_actor(custom_monitor) = custom_actor, "actor");
        check(get_checker(custom_monitor) = custom_checker, "checker");
        disable_stop(get_logger(custom_checker), error);
        check_axi4_transaction(net, custom_monitor, true, x"00000010", x"99999999", msg => "custom");
        write(16#10#, x"00000000");
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
        wait_for_time(net, as_sync(default_monitor), 1 us);
        check_equal(now, start, "wait_for_time returns at once");
        wait_until_idle(net, as_sync(default_monitor));
        check_equal(now - start, 1 us, "wait_until_idle waits for the requested time");

      elsif run("test_monitor_publishes_transactions") then
        subscribe(subscriber, get_actor(default_monitor));
        -- The monitor sees the subscriber when it next looks
        wait_until_idle(net, as_sync(default_monitor));
        write(16#20#, x"00000077");
        receive(net, subscriber, msg);
        check(message_type(msg) = axi4_transaction_msg, "an axi4_transaction_msg");
        pop_axi4_transaction(msg, transaction);
        check_equal(unsigned(transaction.address), 16#20#, "published address");
        check_equal(get(transaction.data, 0), 16#77#, "published data");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        delete(msg);
        unsubscribe(subscriber, get_actor(default_monitor));

      elsif run("test_blocking_and_reference_variants_agree") then
        write(16#30#, x"00000001");
        write(16#34#, x"00000002");
        pop_axi4_transaction(net, default_monitor, transaction);
        pop_axi4_transaction(net, default_monitor, reference);
        await_pop_axi4_transaction_reply(net, reference, reference_transaction);
        check_equal(unsigned(reference_transaction.address), 16#34#, "the second transaction");
        check_equal(length(reference_transaction.data), length(transaction.data), "bytes");
        check(reference_transaction.address_time > transaction.address_time, "later");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        deallocate(reference_transaction.data);
        deallocate(reference_transaction.strobe);
        get_axi4_statistics(net, default_monitor, statistics);
        get_axi4_statistics(net, default_monitor, reference);
        await_get_axi4_statistics_reply(net, reference, reference_statistics);
        check_equal(statistics.write_transactions, 2, "writes");
        check_equal(reference_statistics.write_transactions, statistics.write_transactions, "reference writes");
        check_equal(reference_statistics.write_bytes, 8, "reference bytes");

      elsif run("test_metavalues_without_a_protocol_checker") then
        disable_stop(get_logger(default_monitor), error);
        disable_stop(get_logger(custom_checker), error);
        disable_stop(get_logger(ignoring_monitor), error);
        disable_stop(get_logger(get_checker(protocol_checker(checked_monitor))), error);
        disable_stop(get_logger(get_checker(protocol_checker(narrow_monitor))), error);
        disable_stop(get_logger(get_checker(protocol_checker(wide_monitor))), error);
        awvalid <= 'X';
        wait until rising_edge(aclk);
        awvalid <= '0';
        wait until rising_edge(aclk);
        wait_until_idle(net, as_sync(default_monitor));
        wait_until_idle(net, as_sync(checked_monitor));
        wait_until_idle(net, as_sync(custom_monitor));
        wait_until_idle(net, as_sync(ignoring_monitor));
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
        -- The monitors of the other widths see the same AWVALID
        wait_until_idle(net, as_sync(protocol_checker(narrow_monitor)));
        wait_until_idle(net, as_sync(protocol_checker(wide_monitor)));
        reset_log_count(get_logger(get_checker(protocol_checker(narrow_monitor))), error);
        reset_log_count(get_logger(get_checker(protocol_checker(wide_monitor))), error);

      elsif run("test_data_widths_from_8_to_1024_bits") then
        narrow_awaddr <= x"123";
        narrow_wdata <= x"A5";
        wide_awid <= x"C3";
        wide_awaddr <= x"FEDCBA9876543200";
        for idx in 0 to 127 loop

          wide_wdata(8 * idx + 7 downto 8 * idx) <= std_ulogic_vector(to_unsigned(idx, 8));
        end loop;

        write(16#0#, x"00000000");
        pop_axi4_transaction(net, narrow_monitor, transaction);
        check_equal(unsigned(transaction.address), 16#123#, "narrow address");
        check_equal(transaction.size, 0, "a 1-byte beat");
        check_equal(length(transaction.data), 1, "one byte");
        check_equal(get(transaction.data, 0), 16#A5#, "the byte");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        pop_axi4_transaction(net, wide_monitor, transaction);
        check_equal(transaction.address, std_ulogic_vector'(x"FEDCBA9876543200"), "64-bit address");
        check_equal(transaction.id, 16#C3#, "8-bit ID");
        check_equal(transaction.size, 7, "a 128-byte beat");
        check_equal(length(transaction.data), 128, "128 bytes");
        for idx in 0 to 127 loop

          check_equal(get(transaction.data, idx), idx, "byte " & integer'image(idx));
        end loop;

        deallocate(transaction.data);
        deallocate(transaction.strobe);
        get_check_count(net, protocol_checker(wide_monitor), axi4_unexpected_resp, start_count);
        check_equal(start_count, 0, "the checker of the wide monitor saw the write");

      elsif run("test_reset_forgets_kept_and_expected_transactions") then
        check_axi4_transaction(net, default_monitor, true, x"00000044", x"00000000");
        -- A write without its response when the reset comes
        awvalid <= '1';
        awready <= '1';
        wvalid <= '1';
        wready <= '1';
        wait until rising_edge(aclk);
        awvalid <= '0';
        wvalid <= '0';
        wait until rising_edge(aclk);
        start := now;
        reset(net, default_monitor, clear_statistics => true);
        check_equal(now, start, "reset returns at once");
        write(16#48#, x"00000003");
        pop_axi4_transaction(net, default_monitor, transaction);
        check_equal(get(transaction.data, 0), 3, "the transaction after the reset");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        get_axi4_statistics(net, default_monitor, statistics);
        check_equal(statistics.write_transactions, 1, "statistics cleared");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);
end architecture;
