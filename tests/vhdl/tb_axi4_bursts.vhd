-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI4 monitor and protocol checker on an interface between a burst
-- master written in this testbench and VUnit's axi_write_slave and
-- axi_read_slave: INCR and FIXED bursts, narrow and unaligned transfers,
-- several outstanding IDs, backpressure and latencies the testbench measures
-- itself, and the shadow memory against a memory changed behind the bus.

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_bursts is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_bursts is

  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 32, address_length => 32, id_length => 4);
  constant monitor : axi4_monitor_t := new_axi4_monitor(
    axi4_bus,
    protocol_checker => new_axi4_protocol_checker,
    shadow_memory => true,
    per_id_statistics => true,
    id => get_id("tb_axi4_bursts:monitor")
  );

  constant memory : memory_t := new_memory;
  constant write_slave : axi_slave_t := new_axi_slave(
    memory => memory,
    address_fifo_depth => 4,
    write_response_fifo_depth => 4,
    min_response_latency => 30 ns,
    max_response_latency => 30 ns
  );
  constant read_slave : axi_slave_t := new_axi_slave(
    memory => memory,
    address_fifo_depth => 4,
    min_response_latency => 30 ns,
    max_response_latency => 30 ns
  );

  type word_array_t is array (natural range <>) of std_ulogic_vector(31 downto 0);

  type strb_array_t is array (natural range <>) of std_ulogic_vector(3 downto 0);

  signal aclk : std_logic := '0';
  signal awvalid, awready : std_logic := '0';
  signal awid : std_logic_vector(3 downto 0) := (others => '0');
  signal awaddr : std_logic_vector(31 downto 0) := (others => '0');
  signal awlen : std_logic_vector(7 downto 0) := (others => '0');
  signal awsize : std_logic_vector(2 downto 0) := "010";
  signal awburst : axi_burst_type_t := axi_burst_type_incr;
  signal wvalid, wready : std_logic := '0';
  signal wdata : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb : std_logic_vector(3 downto 0) := "1111";
  signal wlast : std_logic := '0';
  signal bvalid, bready : std_logic := '0';
  signal bid : std_logic_vector(3 downto 0);
  signal bresp : axi_resp_t;
  signal arvalid, arready : std_logic := '0';
  signal arid : std_logic_vector(3 downto 0) := (others => '0');
  signal araddr : std_logic_vector(31 downto 0) := (others => '0');
  signal arlen : std_logic_vector(7 downto 0) := (others => '0');
  signal arsize : std_logic_vector(2 downto 0) := "010";
  signal arburst : axi_burst_type_t := axi_burst_type_incr;
  signal rvalid, rready : std_logic := '0';
  signal rid : std_logic_vector(3 downto 0);
  signal rdata : std_logic_vector(31 downto 0);
  signal rresp : axi_resp_t;
  signal rlast : std_logic;

  -- VALID without READY per channel (AW, W, B, AR, R), counted by the testbench
  type counts_t is array (0 to 4) of natural;

  signal stalls : counts_t := (others => 0);

begin

  aclk <= not aclk after 5 ns;

  write_slave_inst : entity vunit_lib.axi_write_slave
    generic map (
      axi_slave => write_slave
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
      axi_slave => read_slave
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

  count_stalls : process
  begin

    wait until rising_edge(aclk);
    stalls(0) <= stalls(0) + 1 when awvalid = '1' and awready = '0' else
                 stalls(0);
    stalls(1) <= stalls(1) + 1 when wvalid = '1' and wready = '0' else
                 stalls(1);
    stalls(2) <= stalls(2) + 1 when bvalid = '1' and bready = '0' else
                 stalls(2);
    stalls(3) <= stalls(3) + 1 when arvalid = '1' and arready = '0' else
                 stalls(3);
    stalls(4) <= stalls(4) + 1 when rvalid = '1' and rready = '0' else
                 stalls(4);
  end process;

  main : process

    variable transaction : axi4_transaction_t;
    variable statistics : axi4_statistics_t;
    variable buffer_ref : buffer_t;
    variable read_words : word_array_t(0 to 15);
    variable start : time;
    variable latency : natural;
    variable min_latency, max_latency : natural;

    procedure aw (id : natural; addr : natural; len : natural; size : natural; burst : axi_burst_type_t) is
    begin

      awvalid <= '1';
      awid <= std_logic_vector(to_unsigned(id, 4));
      awaddr <= std_logic_vector(to_unsigned(addr, 32));
      awlen <= std_logic_vector(to_unsigned(len, 8));
      awsize <= std_logic_vector(to_unsigned(size, 3));
      awburst <= burst;
      wait until rising_edge(aclk) and awready = '1';
      awvalid <= '0';
    end;

    procedure w (data : word_array_t; strb : strb_array_t) is
    begin

      for idx in data'range loop

        wvalid <= '1';
        wdata <= data(idx);
        wstrb <= strb(idx);
        wlast <= '1' when idx = data'high else
                 '0';
        wait until rising_edge(aclk) and wready = '1';
      end loop;

      wvalid <= '0';
    end;

    procedure b is
    begin

      bready <= '1';
      wait until rising_edge(aclk) and bvalid = '1';
      bready <= '0';
    end;

    procedure ar (id : natural; addr : natural; len : natural; size : natural; burst : axi_burst_type_t) is
    begin

      arvalid <= '1';
      arid <= std_logic_vector(to_unsigned(id, 4));
      araddr <= std_logic_vector(to_unsigned(addr, 32));
      arlen <= std_logic_vector(to_unsigned(len, 8));
      arsize <= std_logic_vector(to_unsigned(size, 3));
      arburst <= burst;
      wait until rising_edge(aclk) and arready = '1';
      arvalid <= '0';
    end;

    -- Read beats until RLAST, into read_words
    procedure r is

      variable idx : natural := 0;
    begin

      rready <= '1';
      loop

        wait until rising_edge(aclk) and rvalid = '1';
        read_words(idx) := rdata;
        idx := idx + 1;
        exit when rlast = '1';
      end loop;

      rready <= '0';
    end;

    procedure pop_and_check (
      is_write : boolean;
      id : natural;
      address : natural;
      expected : std_ulogic_vector;
      what : string
    ) is

      alias bytes : std_ulogic_vector(0 to expected'length - 1) is expected;
    begin

      pop_axi4_transaction(net, monitor, transaction);
      check(transaction.is_write = is_write, what & ": direction");
      check_equal(transaction.id, id, what & ": ID");
      check_equal(unsigned(transaction.address), address, what & ": address");
      check_equal(length(transaction.data), expected'length / 8, what & ": bytes");
      for idx in 0 to expected'length / 8 - 1 loop

        if get(transaction.strobe, idx) = 1 then
          check_equal(
            get(transaction.data, idx),
            to_integer(unsigned(bytes(8 * idx to 8 * idx + 7))),
            what & ": byte " & integer'image(idx)
          );
        end if;
      end loop;

      deallocate(transaction.data);
      deallocate(transaction.strobe);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    buffer_ref := allocate(memory, 16#10000#, permissions => read_and_write);
    wait until rising_edge(aclk);

    while test_suite loop

      if run("test_incr_bursts_through_vunit_slaves") then
        aw(1, 16#1000#, 3, 2, axi_burst_type_incr);
        w((x"03020100", x"07060504", x"0B0A0908", x"0F0E0D0C"), (x"F", x"F", x"F", x"F"));
        b;
        ar(2, 16#1004#, 1, 2, axi_burst_type_incr);
        r;
        check_equal(read_words(0), std_ulogic_vector'(x"07060504"), "the slave returned the data");
        pop_and_check(true, 1, 16#1000#, x"000102030405060708090A0B0C0D0E0F", "INCR write");
        pop_and_check(false, 2, 16#1004#, x"0405060708090A0B", "INCR read");

      elsif run("test_narrow_unaligned_and_fixed_bursts") then
        -- 2-byte beats from 0x2002: lanes 2-3, 0-1, 2-3, 0-1
        aw(3, 16#2002#, 3, 1, axi_burst_type_incr);
        w((x"BBAA0000", x"0000DDCC", x"FFEE0000", x"00001100"), (x"C", x"3", x"C", x"3"));
        b;
        -- 4-byte beats from 0x3001: the first beat carries lanes 1 to 3
        aw(4, 16#3001#, 1, 2, axi_burst_type_incr);
        w((x"332211FF", x"77665544"), (x"E", x"F"));
        b;
        -- FIXED: three beats to the same word, the last one stays
        aw(5, 16#4000#, 2, 2, axi_burst_type_fixed);
        w((x"00000001", x"00000002", x"00000003"), (x"F", x"F", x"F"));
        b;
        ar(6, 16#2000#, 2, 2, axi_burst_type_incr);
        r;
        check_equal(read_words(0), std_ulogic_vector'(x"BBAA0000"), "narrow writes in memory");
        check_equal(read_words(1), std_ulogic_vector'(x"FFEEDDCC"), "narrow writes in memory");
        ar(7, 16#4000#, 1, 2, axi_burst_type_fixed);
        r;
        pop_and_check(true, 3, 16#2002#, x"AABBCCDDEEFF0011", "narrow write");
        pop_and_check(true, 4, 16#3001#, x"112233" & x"44556677", "unaligned write");
        pop_and_check(true, 5, 16#4000#, x"010000000200000003000000", "FIXED write");
        pop_and_check(false, 6, 16#2000#, x"0000AABBCCDDEEFF00110000", "read back");
        pop_and_check(false, 7, 16#4000#, x"0300000003000000", "FIXED read");
        wait_until_idle(net, as_sync(monitor));
        check_equal(get_log_count(get_logger(monitor), error), 0, "the reads match the shadow memory");

      elsif run("test_outstanding_ids_and_measured_latencies") then
        ar(1, 16#100#, 1, 2, axi_burst_type_incr);
        ar(2, 16#200#, 0, 2, axi_burst_type_incr);
        ar(3, 16#300#, 3, 2, axi_burst_type_incr);
        r;
        r;
        r;
        min_latency := natural'high;
        max_latency := 0;
        for idx in 0 to 3 loop

          aw(idx, 16#400# + 4 * idx, 0, 2, axi_burst_type_incr);
          start := now;
          w((0 => x"00000000"), (0 => x"F"));
          b;
          latency := (now - start) / 10 ns;
          min_latency := minimum(min_latency, latency);
          max_latency := maximum(max_latency, latency);
        end loop;

        get_axi4_statistics(net, monitor, statistics);
        check_equal(statistics.read_transactions, 3, "reads");
        check_equal(statistics.read_bytes, 28, "read bytes");
        check_equal(statistics.max_outstanding_reads, 3, "three reads outstanding");
        check_equal(statistics.write_transactions, 4, "writes");
        check_equal(statistics.min_write_latency, min_latency, "the latency the testbench measured");
        check_equal(statistics.max_write_latency, max_latency, "the latency the testbench measured");
        pop_axi4_transaction(net, monitor, transaction);
        check_equal(transaction.id, 1, "the first read");
        check_equal(transaction.len, 1, "its ARLEN");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        log_axi4_statistics(net, monitor);

      elsif run("test_backpressure_is_counted") then
        set_address_stall_probability(net, write_slave, 0.5);
        set_data_stall_probability(net, write_slave, 0.5);
        set_address_stall_probability(net, read_slave, 0.5);
        set_data_stall_probability(net, read_slave, 0.5);
        for idx in 0 to 7 loop

          aw(0, 16#800# + 16 * idx, 3, 2, axi_burst_type_incr);
          w((x"00000000", x"11111111", x"22222222", x"33333333"), (x"F", x"F", x"F", x"F"));
          b;
          ar(0, 16#800# + 16 * idx, 3, 2, axi_burst_type_incr);
          r;
        end loop;

        wait until rising_edge(aclk);
        get_axi4_statistics(net, monitor, statistics);
        check(stalls(0) + stalls(1) + stalls(3) > 0, "the slaves stalled");
        check_equal(statistics.aw_stall_cycles, stalls(0), "AW stalls");
        check_equal(statistics.w_stall_cycles, stalls(1), "W stalls");
        check_equal(statistics.b_stall_cycles, stalls(2), "B stalls");
        check_equal(statistics.ar_stall_cycles, stalls(3), "AR stalls");
        check_equal(statistics.r_stall_cycles, stalls(4), "R stalls");
        check_equal(statistics.write_bytes, 8 * 16, "write bytes");

      elsif run("test_shadow_memory_catches_a_memory_changed_behind_the_bus") then
        disable_stop(get_logger(monitor), error);
        aw(0, 16#500#, 0, 2, axi_burst_type_incr);
        w((0 => x"11223344"), (0 => x"F"));
        b;
        -- A write that does not go through the interface
        write_word(memory, 16#500#, x"55667788");
        ar(0, 16#500#, 0, 2, axi_burst_type_incr);
        r;
        wait_until_idle(net, as_sync(monitor));
        check_equal(get_log_count(get_logger(monitor), error), 1, "the read differs from the shadow memory");
        reset_log_count(get_logger(monitor), error);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);
end architecture;
