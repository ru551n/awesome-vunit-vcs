-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI4 examples of the documentation. Two interfaces, each between a
-- master and VUnit's axi_write_slave and axi_read_slave, each with an AXI4
-- monitor and its protocol checker: an AXI4-Lite interface driven by VUnit's
-- axi_lite_master, and an AXI4 interface with IDs and bursts driven by a
-- small burst master of this testbench. In a real test your design takes the
-- place of a master or of the slaves, and the monitor watches its pins.

-- docs-start: context
library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

-- docs-end: context

entity tb_axi4_examples is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_examples is

  -- docs-start: lite-handles
  -- A monitor of a 32-bit AXI4-Lite interface, with a protocol checker and a
  -- shadow memory that checks every read against the writes before it
  constant lite_monitor : axi4_monitor_t := new_axi4_monitor(
    new_axi4_bus(data_length => 32, address_length => 32, lite => true),
    protocol_checker => new_axi4_protocol_checker,
    shadow_memory => true
  );
  -- docs-end: lite-handles

  -- docs-start: handles
  -- A 64-bit AXI4 interface with 4-bit IDs, statistics per ID and a protocol
  -- checker that reports a transaction waiting 100 cycles for its response
  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 64, address_length => 32, id_length => 4);
  constant monitor : axi4_monitor_t := new_axi4_monitor(
    axi4_bus,
    protocol_checker => new_axi4_protocol_checker(timeout_cycles => 100),
    shadow_memory => true,
    per_id_statistics => true
  );
  -- docs-end: handles

  -- VUnit's bus master and slaves
  constant lite_master : bus_master_t := new_bus(data_length => 32, address_length => 32);
  constant memory : memory_t := new_memory;
  constant lite_slave : axi_slave_t := new_axi_slave(memory => memory);
  constant axi4_slave : axi_slave_t := new_axi_slave(
    memory => memory,
    address_fifo_depth => 4,
    check_4kbyte_boundary => false,
    min_response_latency => 20 ns,
    max_response_latency => 60 ns
  );

  signal aclk : std_logic := '0';

  -- The AXI4-Lite interface
  signal lite_awvalid : std_logic;
  signal lite_awready : std_logic;
  signal lite_wvalid : std_logic;
  signal lite_wready : std_logic;
  signal lite_bvalid : std_logic;
  signal lite_bready : std_logic;
  signal lite_arvalid : std_logic;
  signal lite_arready : std_logic;
  signal lite_rvalid : std_logic;
  signal lite_rready : std_logic;
  signal lite_rlast : std_logic;
  signal lite_awaddr : std_logic_vector(31 downto 0);
  signal lite_araddr : std_logic_vector(31 downto 0);
  signal lite_wdata : std_logic_vector(31 downto 0);
  signal lite_rdata : std_logic_vector(31 downto 0);
  signal lite_wstrb : std_logic_vector(3 downto 0);
  signal lite_bresp, lite_rresp : axi_resp_t;
  signal lite_bid, lite_rid : std_logic_vector(0 downto 0);

  -- docs-start: signals
  -- The AXI4 interface
  signal awvalid : std_logic := '0';
  signal awready : std_logic := '0';
  signal wvalid : std_logic := '0';
  signal wready : std_logic := '0';
  signal wlast : std_logic := '0';
  signal bvalid : std_logic := '0';
  signal bready : std_logic := '0';
  signal arvalid : std_logic := '0';
  signal arready : std_logic := '0';
  signal rvalid : std_logic := '0';
  signal rready : std_logic := '0';
  signal rlast : std_logic := '0';
  signal awid : std_logic_vector(3 downto 0) := (others => '0');
  signal bid : std_logic_vector(3 downto 0) := (others => '0');
  signal arid : std_logic_vector(3 downto 0) := (others => '0');
  signal rid : std_logic_vector(3 downto 0) := (others => '0');
  signal awaddr, araddr : std_logic_vector(31 downto 0) := (others => '0');
  signal awlen, arlen : std_logic_vector(7 downto 0) := (others => '0');
  signal awsize, arsize : std_logic_vector(2 downto 0) := "011";
  signal awburst, arburst : axi_burst_type_t := axi_burst_type_incr;
  signal wdata, rdata : std_logic_vector(63 downto 0) := (others => '0');
  signal wstrb : std_logic_vector(7 downto 0) := (others => '1');
  signal bresp, rresp : axi_resp_t := axi_resp_okay;

-- docs-end: signals

begin

  aclk <= not aclk after 5 ns;

  -- docs-start: lite-instances
  lite_master_inst : entity vunit_lib.axi_lite_master
    generic map (
      bus_handle => lite_master
    )
    port map (
      aclk => aclk,
      arready => lite_arready,
      arvalid => lite_arvalid,
      araddr => lite_araddr,
      rready => lite_rready,
      rvalid => lite_rvalid,
      rdata => lite_rdata,
      rresp => lite_rresp,
      awready => lite_awready,
      awvalid => lite_awvalid,
      awaddr => lite_awaddr,
      wready => lite_wready,
      wvalid => lite_wvalid,
      wdata => lite_wdata,
      wstrb => lite_wstrb,
      bvalid => lite_bvalid,
      bready => lite_bready,
      bresp => lite_bresp
    );

  -- The signals AXI4-Lite does not have are left open: the monitor ignores them
  lite_monitor_inst : entity awesome_vunit_vcs.axi4_monitor
    generic map (
      monitor => lite_monitor
    )
    port map (
      aclk => aclk,
      awvalid => lite_awvalid,
      awready => lite_awready,
      awaddr => lite_awaddr,
      wvalid => lite_wvalid,
      wready => lite_wready,
      wdata => lite_wdata,
      wstrb => lite_wstrb,
      bvalid => lite_bvalid,
      bready => lite_bready,
      bresp => lite_bresp,
      arvalid => lite_arvalid,
      arready => lite_arready,
      araddr => lite_araddr,
      rvalid => lite_rvalid,
      rready => lite_rready,
      rdata => lite_rdata,
      rresp => lite_rresp
    );

  -- docs-end: lite-instances

  lite_write_slave_inst : entity vunit_lib.axi_write_slave
    generic map (
      axi_slave => lite_slave
    )
    port map (
      aclk => aclk,
      awvalid => lite_awvalid,
      awready => lite_awready,
      awid => "0",
      awaddr => lite_awaddr,
      awlen => x"00",
      awsize => "010",
      awburst => axi_burst_type_incr,
      wvalid => lite_wvalid,
      wready => lite_wready,
      wdata => lite_wdata,
      wstrb => lite_wstrb,
      wlast => '1',
      bvalid => lite_bvalid,
      bready => lite_bready,
      bid => lite_bid,
      bresp => lite_bresp
    );

  lite_read_slave_inst : entity vunit_lib.axi_read_slave
    generic map (
      axi_slave => lite_slave
    )
    port map (
      aclk => aclk,
      arvalid => lite_arvalid,
      arready => lite_arready,
      arid => "0",
      araddr => lite_araddr,
      arlen => x"00",
      arsize => "010",
      arburst => axi_burst_type_incr,
      rvalid => lite_rvalid,
      rready => lite_rready,
      rid => lite_rid,
      rdata => lite_rdata,
      rresp => lite_rresp,
      rlast => lite_rlast
    );

  -- docs-start: instances
  monitor_inst : entity awesome_vunit_vcs.axi4_monitor
    generic map (
      monitor => monitor
    )
    port map (
      aclk => aclk,
      awvalid => awvalid,
      awready => awready,
      awid => awid,
      awaddr => awaddr,
      awlen => awlen,
      awsize => awsize,
      awburst => awburst,
      wvalid => wvalid,
      wready => wready,
      wdata => wdata,
      wstrb => wstrb,
      wlast => wlast,
      bvalid => bvalid,
      bready => bready,
      bid => bid,
      bresp => bresp,
      arvalid => arvalid,
      arready => arready,
      arid => arid,
      araddr => araddr,
      arlen => arlen,
      arsize => arsize,
      arburst => arburst,
      rvalid => rvalid,
      rready => rready,
      rid => rid,
      rdata => rdata,
      rresp => rresp,
      rlast => rlast
    );

  -- docs-end: instances

  write_slave_inst : entity vunit_lib.axi_write_slave
    generic map (
      axi_slave => axi4_slave
    )
    port map (
      aclk => aclk,
      awvalid => awvalid,
      awready => awready,
      awid => awid,
      awaddr => awaddr,
      awlen => awlen,
      awsize => awsize,
      awburst => awburst,
      wvalid => wvalid,
      wready => wready,
      wdata => wdata,
      wstrb => wstrb,
      wlast => wlast,
      bvalid => bvalid,
      bready => bready,
      bid => bid,
      bresp => bresp
    );

  read_slave_inst : entity vunit_lib.axi_read_slave
    generic map (
      axi_slave => axi4_slave
    )
    port map (
      aclk => aclk,
      arvalid => arvalid,
      arready => arready,
      arid => arid,
      araddr => araddr,
      arlen => arlen,
      arsize => arsize,
      arburst => arburst,
      rvalid => rvalid,
      rready => rready,
      rid => rid,
      rdata => rdata,
      rresp => rresp,
      rlast => rlast
    );

  main : process

    variable buffer_ref : buffer_t;
    variable transaction : axi4_transaction_t;
    variable statistics : axi4_statistics_t;
    variable count : natural;

    -- The burst master of this testbench: a write of beats 64-bit beats of
    -- first, first + 1, ... from address, then its response
    procedure write_burst (id : natural; address : natural; beats : positive; first : natural := 0) is
    begin

      awvalid <= '1';
      awid <= std_logic_vector(to_unsigned(id, 4));
      awaddr <= std_logic_vector(to_unsigned(address, 32));
      awlen <= std_logic_vector(to_unsigned(beats - 1, 8));
      wait until rising_edge(aclk) and awready = '1';
      awvalid <= '0';
      for beat in 0 to beats - 1 loop

        wvalid <= '1';
        wdata <= std_logic_vector(to_unsigned(first + beat, 64));
        wlast <= '1' when beat = beats - 1 else
                 '0';
        wait until rising_edge(aclk) and wready = '1';
      end loop;

      wvalid <= '0';
      bready <= '1';
      wait until rising_edge(aclk) and bvalid = '1';
      bready <= '0';
    end;

    -- Read addresses without waiting for the data
    procedure read_address (id : natural; address : natural; beats : positive) is
    begin

      arvalid <= '1';
      arid <= std_logic_vector(to_unsigned(id, 4));
      araddr <= std_logic_vector(to_unsigned(address, 32));
      arlen <= std_logic_vector(to_unsigned(beats - 1, 8));
      wait until rising_edge(aclk) and arready = '1';
      arvalid <= '0';
    end;

    -- Take read data beats until the last beat of beats bursts
    procedure read_data (bursts : positive) is
    begin

      rready <= '1';
      for burst in 1 to bursts loop

        wait until rising_edge(aclk) and rvalid = '1' and rlast = '1';
      end loop;

      rready <= '0';
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    buffer_ref := allocate(memory, 16#4000#, permissions => read_and_write);

    while test_suite loop

      if run("test_monitor_an_axi4_lite_interface") then
        -- docs-start: check-transaction
        -- The next write must be to 0x10 with these bytes, lowest address first
        check_axi4_transaction(net, lite_monitor, true, x"00000010", x"78563412");
        write_bus(net, lite_master, x"00000010", x"12345678");
        -- docs-end: check-transaction
        check_bus(net, lite_master, x"00000010", x"12345678");
        wait_until_idle(net, lite_master);

        -- docs-start: pop
        pop_axi4_transaction(net, lite_monitor, transaction);
        check(transaction.is_write, "the write comes first");
        check_equal(unsigned(transaction.address), 16#10#, "its address");
        check_equal(get(transaction.data, 0), 16#78#, "the byte at 0x10");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        -- docs-end: pop

        -- docs-start: statistics
        get_axi4_statistics(net, lite_monitor, statistics);
        check_equal(statistics.write_transactions, 1, "writes");
        check_equal(statistics.read_transactions, 1, "reads");
        check(statistics.max_read_latency < 10, "reads answered within 10 cycles");
      -- docs-end: statistics

      elsif run("test_bursts_with_ids") then
        -- docs-start: bursts
        write_burst(id => 1, address => 16#1000#, beats => 8);
        write_burst(id => 2, address => 16#2000#, beats => 4, first => 100);
        -- Two reads outstanding at once, then their data
        read_address(id => 3, address => 16#1000#, beats => 8);
        read_address(id => 4, address => 16#2000#, beats => 4);
        read_data(bursts => 2);
        get_axi4_statistics(net, monitor, statistics);
        check_equal(statistics.max_outstanding_reads, 2, "two reads outstanding");
        check_equal(statistics.read_bytes, 96, "12 beats of 8 bytes read");
        -- The summary: latencies, histograms, backpressure, each ID
        log_axi4_statistics(net, monitor);
      -- docs-end: bursts

      elsif run("test_shadow_memory") then
        -- docs-start: shadow-memory
        -- Expect the error the shadow memory reports, and count it
        disable_stop(get_logger(monitor), error);
        write_burst(id => 0, address => 16#3000#, beats => 1, first => 16#1234#);
        -- A write that bypasses the interface, as a bug in the design would
        write_word(memory, 16#3000#, x"0000000000005678");
        read_address(id => 0, address => 16#3000#, beats => 1);
        read_data(bursts => 1);
        wait_until_idle(net, as_sync(monitor));
        check_equal(get_log_count(get_logger(monitor), error), 1, "AXI4_SCOREBOARD");
        reset_log_count(get_logger(monitor), error);
      -- docs-end: shadow-memory

      elsif run("test_protocol_checker") then
        -- docs-start: violation
        -- A burst over a 4 KB boundary is an AXI4_BURST_4K violation on the
        -- checker of the protocol checker; count it instead of failing
        disable_stop(get_logger(get_checker(protocol_checker(monitor))), error);
        write_burst(id => 0, address => 16#0FF0#, beats => 4);
        get_check_count(net, protocol_checker(monitor), axi4_burst_4k, count);
        check_equal(count, 1, "one burst over 4 KB");
        reset_log_count(get_logger(get_checker(protocol_checker(monitor))), error);
        -- Switch the check off where a design breaks the rule on purpose
        set_check_enabled(net, protocol_checker(monitor), axi4_burst_4k, false);
        write_burst(id => 0, address => 16#1FF0#, beats => 4);
        get_check_count(net, protocol_checker(monitor), axi4_burst_4k, count);
        check_equal(count, 1, "not counted while switched off");
      -- docs-end: violation
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 100 us);
end architecture;
