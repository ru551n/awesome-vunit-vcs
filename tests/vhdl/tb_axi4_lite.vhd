-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI4 monitor and protocol checker on an AXI4-Lite interface between
-- VUnit's axi_lite_master, driven with the bus master procedures, and VUnit's
-- axi_write_slave and axi_read_slave.

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_lite is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_lite is

  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 32, address_length => 32, lite => true);
  constant monitor : axi4_monitor_t := new_axi4_monitor(
    axi4_bus,
    protocol_checker => new_axi4_protocol_checker,
    shadow_memory => true,
    id => get_id("tb_axi4_lite:monitor")
  );

  constant bus_handle : bus_master_t := new_bus(data_length => 32, address_length => 32);
  constant memory : memory_t := new_memory;
  constant axi_slave : axi_slave_t := new_axi_slave(memory => memory, address_stall_probability => 0.3);

  signal aclk : std_logic := '0';
  signal awvalid : std_logic;
  signal awready : std_logic;
  signal wvalid : std_logic;
  signal wready : std_logic;
  signal bvalid : std_logic;
  signal bready : std_logic;
  signal arvalid : std_logic;
  signal arready : std_logic;
  signal rvalid : std_logic;
  signal rready : std_logic;
  signal rlast : std_logic;
  signal awaddr : std_logic_vector(31 downto 0);
  signal araddr : std_logic_vector(31 downto 0);
  signal wdata : std_logic_vector(31 downto 0);
  signal rdata : std_logic_vector(31 downto 0);
  signal wstrb : std_logic_vector(3 downto 0);
  signal bresp, rresp : axi_resp_t;
  -- The signals AXI4-Lite does not have, for VUnit's AXI4 slaves
  signal id_zero : std_logic_vector(0 downto 0) := "0";
  signal bid, rid : std_logic_vector(0 downto 0);
  signal len_zero : std_logic_vector(7 downto 0) := x"00";
  signal size_word : std_logic_vector(2 downto 0) := "010";
  signal burst_incr : axi_burst_type_t := axi_burst_type_incr;

begin

  aclk <= not aclk after 5 ns;

  master_inst : entity vunit_lib.axi_lite_master
    generic map (
      bus_handle => bus_handle
    )
    port map (
      aclk => aclk,
      arready => arready,
      arvalid => arvalid,
      araddr => araddr,
      rready => rready,
      rvalid => rvalid,
      rdata => rdata,
      rresp => rresp,
      awready => awready,
      awvalid => awvalid,
      awaddr => awaddr,
      wready => wready,
      wvalid => wvalid,
      wdata => wdata,
      wstrb => wstrb,
      bvalid => bvalid,
      bready => bready,
      bresp => bresp
    );

  write_slave_inst : entity vunit_lib.axi_write_slave
    generic map (
      axi_slave => axi_slave
    )
    port map (
      aclk => aclk,
      awvalid => awvalid,
      awready => awready,
      awid => id_zero,
      awaddr => awaddr,
      awlen => len_zero,
      awsize => size_word,
      awburst => burst_incr,
      wvalid => wvalid,
      wready => wready,
      wdata => wdata,
      wstrb => wstrb,
      wlast => '1',
      bvalid => bvalid,
      bready => bready,
      bid => bid,
      bresp => bresp
    );

  read_slave_inst : entity vunit_lib.axi_read_slave
    generic map (
      axi_slave => axi_slave
    )
    port map (
      aclk => aclk,
      arvalid => arvalid,
      arready => arready,
      arid => id_zero,
      araddr => araddr,
      arlen => len_zero,
      arsize => size_word,
      arburst => burst_incr,
      rvalid => rvalid,
      rready => rready,
      rid => rid,
      rdata => rdata,
      rresp => rresp,
      rlast => rlast
    );

  monitor_inst : entity awesome_vunit_vcs.axi4_monitor
    generic map (
      monitor => monitor
    )
    port map (
      aclk => aclk,
      awvalid => awvalid,
      awready => awready,
      awaddr => awaddr,
      wvalid => wvalid,
      wready => wready,
      wdata => wdata,
      wstrb => wstrb,
      bvalid => bvalid,
      bready => bready,
      bresp => bresp,
      arvalid => arvalid,
      arready => arready,
      araddr => araddr,
      rvalid => rvalid,
      rready => rready,
      rdata => rdata,
      rresp => rresp
    );

  main : process

    variable buffer_ref : buffer_t;
    variable transaction : axi4_transaction_t;
    variable statistics : axi4_statistics_t;
    variable data : std_logic_vector(31 downto 0);

  begin

    test_runner_setup(runner, runner_cfg);
    buffer_ref := allocate(memory, 1024, permissions => read_and_write);

    while test_suite loop

      if run("test_writes_and_reads_of_the_vunit_bus_master") then
        check_axi4_transaction(net, monitor, true, x"00000010", x"78563412");
        write_bus(net, bus_handle, x"00000010", x"12345678");
        write_bus(net, bus_handle, x"00000014", x"AABBCCDD", byte_enable => "0110");
        check_bus(net, bus_handle, x"00000010", x"12345678");
        read_bus(net, bus_handle, x"00000014", data);
        check_equal(data(23 downto 8), std_logic_vector'(x"BBCC"), "the strobed bytes");
        wait_until_idle(net, bus_handle);
        pop_axi4_transaction(net, monitor, transaction);
        check(transaction.is_write, "a write");
        check_equal(transaction.id, 0, "AXI4-Lite has ID 0");
        check_equal(transaction.len, 0, "a single beat");
        check_equal(transaction.size, 2, "of the full width");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        pop_axi4_transaction(net, monitor, transaction);
        check_equal(unsigned(transaction.address), 16#14#, "the second write");
        check_equal(get(transaction.strobe, 0), 0, "lane 0 is not written");
        check_equal(get(transaction.strobe, 1), 1, "lane 1 is written");
        check_equal(get(transaction.data, 1), 16#CC#, "lane 1");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        get_axi4_statistics(net, monitor, statistics);
        check_equal(statistics.write_transactions, 2, "writes");
        check_equal(statistics.read_transactions, 2, "reads");
        check_equal(statistics.write_bytes, 6, "strobed bytes");
        check_equal(statistics.read_bytes, 8, "read bytes");
        check_equal(get_log_count(get_logger(monitor), error), 0, "no scoreboard errors");

      elsif run("test_many_transactions_with_backpressure") then
        for idx in 0 to 63 loop

          write_bus(
            net,
            bus_handle,
            std_logic_vector(to_unsigned(4 * idx, 32)),
            std_logic_vector(to_unsigned(idx, 32))
          );
        end loop;

        for idx in 0 to 63 loop

          check_bus(
            net,
            bus_handle,
            std_logic_vector(to_unsigned(4 * idx, 32)),
            std_logic_vector(to_unsigned(idx, 32))
          );
        end loop;

        wait_until_idle(net, bus_handle);
        get_axi4_statistics(net, monitor, statistics);
        check_equal(statistics.write_transactions, 64, "writes");
        check_equal(statistics.read_transactions, 64, "reads");
        check(statistics.aw_stall_cycles > 0, "the slave stalled AW");
        log_axi4_statistics(net, monitor);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);
end architecture;
