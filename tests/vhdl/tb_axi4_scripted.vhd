-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI4 monitor and protocol checker on an interface whose both sides the
-- test drives cycle by cycle: WRAP bursts, responses out of order between
-- IDs, interleaved read data, statistics of known traffic, the scoreboards,
-- and one test per protocol violation, counted instead of failing.

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_scripted is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_scripted is

  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 32, address_length => 32, id_length => 4);
  constant monitor : axi4_monitor_t := new_axi4_monitor(
    axi4_bus,
    protocol_checker => new_axi4_protocol_checker(timeout_cycles => 20),
    shadow_memory => true,
    per_id_statistics => true,
    id => get_id("tb_axi4_scripted:monitor")
  );
  constant checker_handle : axi4_protocol_checker_t := protocol_checker(monitor);
  constant subscriber : actor_t := new_actor("tb_axi4_scripted:subscriber");

  signal aclk : std_ulogic := '0';
  signal aresetn : std_ulogic := '1';
  signal awvalid, awready : std_ulogic := '0';
  signal awid : std_ulogic_vector(3 downto 0) := (others => '0');
  signal awaddr : std_ulogic_vector(31 downto 0) := (others => '0');
  signal awlen : std_ulogic_vector(7 downto 0) := (others => '0');
  signal awsize : std_ulogic_vector(2 downto 0) := "010";
  signal awburst : std_ulogic_vector(1 downto 0) := "01";
  signal awlock : std_ulogic := '0';
  signal awcache : std_ulogic_vector(3 downto 0) := "0000";
  signal wvalid, wready : std_ulogic := '0';
  signal wdata : std_ulogic_vector(31 downto 0) := (others => '0');
  signal wstrb : std_ulogic_vector(3 downto 0) := "1111";
  signal wlast : std_ulogic := '1';
  signal bvalid, bready : std_ulogic := '0';
  signal bid : std_ulogic_vector(3 downto 0) := (others => '0');
  signal bresp : std_ulogic_vector(1 downto 0) := "00";
  signal arvalid, arready : std_ulogic := '0';
  signal arid : std_ulogic_vector(3 downto 0) := (others => '0');
  signal araddr : std_ulogic_vector(31 downto 0) := (others => '0');
  signal arlen : std_ulogic_vector(7 downto 0) := (others => '0');
  signal arsize : std_ulogic_vector(2 downto 0) := "010";
  signal arburst : std_ulogic_vector(1 downto 0) := "01";
  signal arlock : std_ulogic := '0';
  signal rvalid, rready : std_ulogic := '0';
  signal rid : std_ulogic_vector(3 downto 0) := (others => '0');
  signal rdata : std_ulogic_vector(31 downto 0) := (others => '0');
  signal rresp : std_ulogic_vector(1 downto 0) := "00";
  signal rlast : std_ulogic := '1';

begin

  aclk <= not aclk after 5 ns;

  monitor_inst : entity awesome_vunit_vcs.axi4_monitor
    generic map (
      monitor => monitor
    )
    port map (
      aclk => aclk,
      aresetn => aresetn,
      awvalid => awvalid,
      awready => awready,
      awid => awid,
      awaddr => awaddr,
      awlen => awlen,
      awsize => awsize,
      awburst => awburst,
      awlock => awlock,
      awcache => awcache,
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
      arlock => arlock,
      rvalid => rvalid,
      rready => rready,
      rid => rid,
      rdata => rdata,
      rresp => rresp,
      rlast => rlast
    );

  main : process

    variable transaction : axi4_transaction_t;
    variable statistics : axi4_statistics_t;
    variable msg : msg_t;

    procedure cycles (count : positive := 1) is
    begin

      for idx in 1 to count loop

        wait until rising_edge(aclk);
      end loop;

    end;

    -- One handshake on each channel, after stall cycles with VALID and not READY
    procedure aw (
      id : natural;
      addr : natural;
      len : natural := 0;
      size : natural := 2;
      burst : std_ulogic_vector(1 downto 0) := "01";
      lock : std_ulogic := '0';
      cache : std_ulogic_vector(3 downto 0) := "0000";
      stall : natural := 0
    ) is
    begin

      awvalid <= '1';
      awready <= '0';
      awid <= std_ulogic_vector(to_unsigned(id, 4));
      awaddr <= std_ulogic_vector(to_unsigned(addr, 32));
      awlen <= std_ulogic_vector(to_unsigned(len, 8));
      awsize <= std_ulogic_vector(to_unsigned(size, 3));
      awburst <= burst;
      awlock <= lock;
      awcache <= cache;
      if stall > 0 then
        cycles(stall);
      end if;
      awready <= '1';
      cycles;
      awvalid <= '0';
      awready <= '0';
    end;

    procedure w (
      data : std_ulogic_vector(31 downto 0);
      strb : std_ulogic_vector(3 downto 0) := "1111";
      last : std_ulogic := '1';
      stall : natural := 0
    ) is
    begin

      wvalid <= '1';
      wready <= '0';
      wdata <= data;
      wstrb <= strb;
      wlast <= last;
      if stall > 0 then
        cycles(stall);
      end if;
      wready <= '1';
      cycles;
      wvalid <= '0';
      wready <= '0';
    end;

    procedure b (id : natural; resp : std_ulogic_vector(1 downto 0) := "00"; stall : natural := 0) is
    begin

      bvalid <= '1';
      bready <= '0';
      bid <= std_ulogic_vector(to_unsigned(id, 4));
      bresp <= resp;
      if stall > 0 then
        cycles(stall);
      end if;
      bready <= '1';
      cycles;
      bvalid <= '0';
      bready <= '0';
    end;

    procedure ar (
      id : natural;
      addr : natural;
      len : natural := 0;
      size : natural := 2;
      burst : std_ulogic_vector(1 downto 0) := "01";
      lock : std_ulogic := '0';
      stall : natural := 0
    ) is
    begin

      arvalid <= '1';
      arready <= '0';
      arid <= std_ulogic_vector(to_unsigned(id, 4));
      araddr <= std_ulogic_vector(to_unsigned(addr, 32));
      arlen <= std_ulogic_vector(to_unsigned(len, 8));
      arsize <= std_ulogic_vector(to_unsigned(size, 3));
      arburst <= burst;
      arlock <= lock;
      if stall > 0 then
        cycles(stall);
      end if;
      arready <= '1';
      cycles;
      arvalid <= '0';
      arready <= '0';
    end;

    procedure r (
      id : natural;
      data : std_ulogic_vector(31 downto 0);
      resp : std_ulogic_vector(1 downto 0) := "00";
      last : std_ulogic := '1';
      stall : natural := 0
    ) is
    begin

      rvalid <= '1';
      rready <= '0';
      rid <= std_ulogic_vector(to_unsigned(id, 4));
      rdata <= data;
      rresp <= resp;
      rlast <= last;
      if stall > 0 then
        cycles(stall);
      end if;
      rready <= '1';
      cycles;
      rvalid <= '0';
      rready <= '0';
    end;

    -- The violations of check since the last call, as counts of the
    -- protocol checker and errors on its logger
    procedure expect_violations (check : axi4_check_t; expected : natural := 1) is

      constant logger : logger_t := get_logger(get_checker(checker_handle));
      variable count : natural;
    begin

      wait_until_idle(net, as_sync(checker_handle));
      get_check_count(net, checker_handle, check, count);
      check_equal(count, expected, "violations of " & axi4_check_t'image(check));
      check_equal(get_log_count(logger, error), expected, "errors logged for " & axi4_check_t'image(check));
      reset_log_count(logger, error);
    end;

    procedure check_byte (data : integer_array_t; idx : natural; expected : natural; what : string) is
    begin

      check_equal(get(data, idx), expected, what & " byte " & integer'image(idx));
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    disable_stop(get_logger(get_checker(checker_handle)), error);
    cycles(2);

    while test_suite loop

      if run("test_wrap_bursts_are_reconstructed") then
        -- 4 x 4 bytes from 0x38 wrap at 0x30 + 16
        aw(id => 1, addr => 16#38#, len => 3, burst => axi_burst_type_wrap);
        w(x"03020100", last => '0');
        w(x"07060504", last => '0');
        w(x"0B0A0908", last => '0');
        w(x"0F0E0D0C");
        b(id => 1);
        ar(id => 2, addr => 16#38#, len => 3, burst => axi_burst_type_wrap);
        r(2, x"03020100", last => '0');
        r(2, x"07060504", last => '0');
        r(2, x"0B0A0908", last => '0');
        r(2, x"0F0E0D0C");
        pop_axi4_transaction(net, monitor, transaction);
        check(transaction.is_write, "the write first");
        check_equal(transaction.id, 1, "AWID");
        check_equal(unsigned(transaction.address), 16#38#, "AWADDR");
        check_equal(transaction.len, 3, "AWLEN");
        check_equal(transaction.burst, axi_burst_type_wrap, "AWBURST");
        check_equal(length(transaction.data), 16, "bytes");
        check_byte(transaction.data, 0, 16#00#, "write");
        check_byte(transaction.data, 15, 16#0F#, "write");
        check_equal(get(transaction.strobe, 7), 1, "strobe");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        pop_axi4_transaction(net, monitor, transaction);
        check(not transaction.is_write, "then the read");
        check_equal(transaction.resp, axi_resp_okay, "RRESP");
        check(transaction.last_data_time - transaction.address_time = 40 ns, "four beats after the address");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        -- The read returned what the write wrote: no scoreboard error
        wait_until_idle(net, as_sync(monitor));
        check_equal(get_log_count(get_logger(monitor), error), 0, "shadow memory");

      elsif run("test_responses_out_of_order_between_ids") then
        ar(id => 1, addr => 16#100#, len => 1);
        ar(id => 2, addr => 16#200#, len => 1);
        r(2, x"22222222", last => '0');
        r(1, x"11111111", last => '0');
        r(2, x"22222223");
        r(1, x"11111112");
        aw(id => 3, addr => 16#300#);
        w(x"33333333");
        aw(id => 4, addr => 16#400#);
        w(x"44444444");
        b(id => 4);
        b(id => 3);
        pop_axi4_transaction(net, monitor, transaction);
        check_equal(transaction.id, 2, "ID 2 completes first");
        check_byte(transaction.data, 4, 16#23#, "ID 2");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        pop_axi4_transaction(net, monitor, transaction);
        check_equal(transaction.id, 1, "then ID 1");
        check_byte(transaction.data, 4, 16#12#, "ID 1");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        pop_axi4_transaction(net, monitor, transaction);
        check_equal(transaction.id, 4, "BID 4 before BID 3");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        pop_axi4_transaction(net, monitor, transaction);
        check_equal(transaction.id, 3, "then 3");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        get_axi4_statistics(net, monitor, statistics);
        check_equal(statistics.max_outstanding_reads, 2, "two reads outstanding");
        check_equal(statistics.max_outstanding_writes, 2, "two writes outstanding");
        expect_violations(axi4_unexpected_resp, 0);

      elsif run("test_statistics_of_known_traffic") then
        -- AW waits 2 cycles, W 1, B 3: AW handshake at cycle 2, B at cycle 8
        aw(id => 5, addr => 16#10#, stall => 2);
        w(x"01020304", stall => 1);
        b(id => 5, resp => axi_resp_slverr, stall => 3);
        -- AR at once, R after 1 cycle: 2 cycles
        ar(id => 5, addr => 16#20#);
        r(5, x"05060708", stall => 1);
        get_axi4_statistics(net, monitor, statistics);
        check_equal(statistics.write_transactions, 1, "writes");
        check_equal(statistics.read_transactions, 1, "reads");
        check_equal(statistics.write_bytes, 4, "write bytes");
        check_equal(statistics.read_bytes, 4, "read bytes");
        check_equal(statistics.aw_stall_cycles, 2, "AW stalls");
        check_equal(statistics.w_stall_cycles, 1, "W stalls");
        check_equal(statistics.b_stall_cycles, 3, "B stalls");
        check_equal(statistics.ar_stall_cycles, 0, "AR stalls");
        check_equal(statistics.r_stall_cycles, 1, "R stalls");
        check_equal(statistics.min_write_latency, 6, "write latency");
        check_equal(statistics.max_write_latency, 6, "write latency");
        check_equal(statistics.mean_write_latency, 6, "write latency");
        check_equal(statistics.min_read_latency, 2, "read latency");
        check_equal(statistics.max_outstanding_writes, 1, "outstanding writes");
        check_equal(statistics.error_responses, 1, "SLVERR");
        log_axi4_statistics(net, monitor);
        wait_until_idle(net, as_sync(monitor));
        check(get_log_count(get_logger(monitor), info) >= 1, "the summary is logged");

      elsif run("test_shadow_memory_reports_a_mismatch") then
        disable_stop(get_logger(monitor), error);
        aw(id => 0, addr => 16#100#);
        w(x"11223344");
        b(id => 0);
        ar(id => 0, addr => 16#100#);
        r(0, x"11223355");
        wait_until_idle(net, as_sync(monitor));
        check_equal(get_log_count(get_logger(monitor), error), 1, "one scoreboard error");
        reset_log_count(get_logger(monitor), error);

      elsif run("test_check_axi4_transaction") then
        disable_stop(get_logger(monitor), error);
        check_axi4_transaction(net, monitor, true, x"00000040", x"01020304", id => 6, resp => axi_resp_okay);
        check_axi4_transaction(net, monitor, false, x"00000040", x"010203FF", msg => "wrong data");
        aw(id => 6, addr => 16#40#);
        w(x"04030201");
        b(id => 6);
        ar(id => 6, addr => 16#40#);
        r(6, x"04030201");
        wait_until_idle(net, as_sync(monitor));
        check_equal(get_log_count(get_logger(monitor), error), 1, "the read differs");
        reset_log_count(get_logger(monitor), error);

      elsif run("test_subscribers_get_every_transaction") then
        subscribe(subscriber, get_actor(monitor));
        wait_until_idle(net, as_sync(monitor));
        ar(id => 7, addr => 16#80#);
        r(7, x"CAFEF00D");
        receive(net, subscriber, msg);
        check(message_type(msg) = axi4_transaction_msg, "an axi4_transaction_msg");
        pop_axi4_transaction(msg, transaction);
        check_equal(transaction.id, 7, "published ID");
        check_byte(transaction.data, 0, 16#0D#, "published");
        deallocate(transaction.data);
        deallocate(transaction.strobe);
        delete(msg);
        unsubscribe(subscriber, get_actor(monitor));

      -- One test per violation of the protocol checker
      elsif run("test_axi4_burst_4k") then
        ar(id => 0, addr => 16#FF0#, len => 4);
        for idx in 0 to 3 loop

          r(0, x"00000000", last => '0');
        end loop;

        r(0, x"00000000");

        expect_violations(axi4_burst_4k);

      elsif run("test_axi4_wrap_len_and_wrap_align") then
        ar(id => 0, addr => 16#40#, len => 2, burst => axi_burst_type_wrap);
        expect_violations(axi4_wrap_len);
        ar(id => 1, addr => 16#42#, len => 3, burst => axi_burst_type_wrap);
        expect_violations(axi4_wrap_align);

      elsif run("test_axi4_len_fixed_size_burst_type_and_cache") then
        ar(id => 0, addr => 16#40#, len => 16, burst => axi_burst_type_fixed);
        expect_violations(axi4_len_fixed);
        ar(id => 1, addr => 16#40#, size => 3);
        expect_violations(axi4_size);
        ar(id => 2, addr => 16#40#, burst => "11");
        expect_violations(axi4_burst_type);
        aw(id => 3, addr => 16#40#, cache => "0100");
        expect_violations(axi4_cache);

      elsif run("test_axi4_excl") then
        -- Not aligned to its 8 bytes, then an EXOKAY to a normal read
        ar(id => 0, addr => 16#44#, len => 1, lock => '1');
        ar(id => 1, addr => 16#80#);
        r(1, x"00000000", resp => axi_resp_exokay);
        expect_violations(axi4_excl, 2);

      elsif run("test_axi4_wlast_and_rlast") then
        aw(id => 0, addr => 16#10#, len => 1);
        w(x"00000000", last => '1');
        w(x"00000000", last => '1');
        expect_violations(axi4_wlast);
        ar(id => 0, addr => 16#10#, len => 1);
        r(0, x"00000000", last => '0');
        r(0, x"00000000", last => '0');
        expect_violations(axi4_rlast);

      elsif run("test_axi4_wstrb") then
        -- A 2-byte write at 0x2 may only strobe lanes 2 and 3
        aw(id => 0, addr => 16#2#, size => 1);
        w(x"00000000", strb => "0111");
        expect_violations(axi4_wstrb);

      elsif run("test_axi4_unexpected_resp") then
        b(id => 3);
        r(2, x"00000000");
        expect_violations(axi4_unexpected_resp, 2);

      elsif run("test_axi4_stable_and_valid_drop") then
        araddr <= x"00000010";
        arvalid <= '1';
        cycles;
        araddr <= x"00000014";
        cycles;
        expect_violations(axi4_stable);
        arvalid <= '0';
        cycles;
        expect_violations(axi4_valid_drop);

      elsif run("test_axi4_reset_valid") then
        aresetn <= '0';
        awvalid <= '1';
        cycles;
        awvalid <= '0';
        cycles;
        aresetn <= '1';
        wvalid <= '1';
        wready <= '1';
        cycles;
        wvalid <= '0';
        wready <= '0';
        cycles;
        expect_violations(axi4_reset_valid, 2);

      elsif run("test_axi4_metavalue") then
        arvalid <= 'X';
        cycles;
        arvalid <= '0';
        rready <= 'U';
        cycles;
        rready <= '0';
        -- A metavalue on an unstrobed lane is not a violation, on a strobed one it is
        w(x"XXXX0000", strb => "0011");
        w(x"0000X000", strb => "0011");
        expect_violations(axi4_metavalue, 3);

      elsif run("test_axi4_timeout") then
        -- The checker of the monitor waits 20 cycles
        ar(id => 1, addr => 16#10#);
        cycles(45);
        expect_violations(axi4_timeout);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);
end architecture;
