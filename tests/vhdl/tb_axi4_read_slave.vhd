-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI4 read slave: the scenarios of VUnit's tb_axi_read_slave on the new
-- slave, and what it adds (WRAP bursts, narrow and unaligned bursts, error
-- responses, statistics, reset). The failures VUnit's slave logs as failures
-- are check failures on the checker of the slave here.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library osvvm;
  use osvvm.randompkg.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_read_slave is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_read_slave is

  constant log_data_size : integer := 4;
  constant data_size : integer := 2 ** log_data_size;
  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 8 * data_size, id_length => 4);

  signal clk : std_ulogic := '1';

  signal arvalid : std_ulogic := '0';
  signal arready : std_ulogic;
  signal arid : std_ulogic_vector(3 downto 0);
  signal araddr : std_ulogic_vector(31 downto 0);
  signal arlen : std_ulogic_vector(7 downto 0);
  signal arsize : std_ulogic_vector(2 downto 0);
  signal arburst : std_ulogic_vector(1 downto 0);

  signal rvalid : std_ulogic;
  signal rready : std_ulogic := '0';
  signal rid : std_ulogic_vector(arid'range);
  signal rdata : std_ulogic_vector(8 * data_size - 1 downto 0);
  signal rresp : std_ulogic_vector(1 downto 0);
  signal rlast : std_ulogic;

  constant memory : axi4_memory_t := new_axi4_memory(default_permissions => no_access);
  constant axi_slave : axi4_slave_t := new_axi4_slave(memory, axi4_bus, address_fifo_depth => 1);

begin

  main : process

    constant logger : logger_t := get_logger(axi_slave);
    variable rnd : randomptype;

    procedure write_addr (
      id : std_ulogic_vector;
      addr : natural;
      len : natural;
      log_size : natural;
      burst : std_ulogic_vector(1 downto 0)
    ) is
    begin

      arvalid <= '1';
      arid <= id;
      araddr <= std_ulogic_vector(to_unsigned(addr, araddr'length));
      arlen <= std_ulogic_vector(to_unsigned(len - 1, arlen'length));
      arsize <= std_ulogic_vector(to_unsigned(log_size, arsize'length));
      arburst <= burst;
      wait until (arvalid and arready) = '1' and rising_edge(clk);
      arvalid <= '0';
    end;

    -- A beat with ``size`` bytes from ``address`` on, each on its own lane
    procedure read_data (
      id : std_ulogic_vector;
      address : natural;
      size : natural;
      resp : std_ulogic_vector(1 downto 0);
      last : boolean
    ) is

      variable idx : integer;
    begin

      rready <= '1';
      wait until (rvalid and rready) = '1' and rising_edge(clk);
      rready <= '0';
      for i in 0 to size - 1 loop

        idx := (address + i) mod data_size;
        check_equal(rdata(8 * idx + 7 downto 8 * idx), read_byte(memory, address + i));
      end loop;

      check_equal(rid, id, "rid");
      check_equal(rresp, resp, "rresp");
      check_equal(rlast, last, "rlast");
    end;

    procedure transfer (log_size, len : natural; id : std_ulogic_vector; burst : std_ulogic_vector) is

      variable buf : axi4_buffer_t;
      variable size : natural;
    begin

      size := 2 ** log_size;
      buf := allocate(memory, data_size * len, alignment => 4096);
      for i in 0 to size * len - 1 loop

        write_byte(memory, base_address(buf) + i, rnd.RandInt(0, 255));
      end loop;

      write_addr(id, base_address(buf), len, log_size, burst);
      for i in 0 to len - 1 loop

        if burst = axi_burst_type_fixed then
          read_data(id, base_address(buf), size, axi_resp_okay, i = len - 1);
        else
          read_data(id, base_address(buf) + size * i, size, axi_resp_okay, i = len - 1);
        end if;
      end loop;

    end;

    variable log_size : natural;
    variable buf : axi4_buffer_t;
    variable id : std_ulogic_vector(arid'range);
    variable len : natural;
    variable burst : std_ulogic_vector(1 downto 0);
    variable start_time, diff_time : time;
    variable stat : axi_statistics_t;

  begin

    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(rnd'instance_name);

    if run("test_random_read") then
      for test_idx in 0 to 32 - 1 loop

        id := rnd.RandSlv(arid'length);

        case rnd.RandInt(2) is
          when 0 =>

            burst := axi_burst_type_fixed;
            len := rnd.RandInt(1, 16);
          when 1 =>

            burst := axi_burst_type_incr;
            len := rnd.RandInt(1, 2 ** arlen'length);
          when others =>

            burst := axi_burst_type_wrap;
            len := 2 ** rnd.RandInt(1, 4);
        end case;

        log_size := rnd.RandInt(0, log_data_size);
        transfer(log_size, len, id, burst);
      end loop;

    elsif run("test_random_data_stall") then
      for i in 0 to 4 loop

        if i = 2 then
          set_data_stall_probability(net, axi_slave, 0.9);
        else
          set_data_stall_probability(net, axi_slave, 0.0);
        end if;
        start_time := now;
        transfer(3, 128, x"0", axi_burst_type_incr);
        if i = 1 or i = 4 then
          -- The runs without stalls take the same time
          check_equal(diff_time, now - start_time);
        elsif i = 2 then
          check(5 * diff_time < now - start_time);
        end if;
        diff_time := now - start_time;
      end loop;

    elsif run("test_response_latency") then
      for i in 0 to 1 loop

        if i = 1 then
          set_response_latency(net, axi_slave, 1 us);
        end if;
        start_time := now;
        transfer(3, 128, x"0", axi_burst_type_incr);
        if i = 1 then
          check_equal(diff_time + 1 us, now - start_time);
        end if;
        diff_time := now - start_time;
      end loop;

    elsif run("test_random_response_latency") then
      set_response_latency(net, axi_slave, 100 ns, 200 ns);
      for i in 0 to 7 loop

        start_time := now;
        transfer(log_data_size, 1, x"0", axi_burst_type_incr);
        check(now - start_time >= 100 ns and now - start_time <= 240 ns, "latency " & to_string(now - start_time));
      end loop;

    elsif run("test_that_permissions_are_checked") then
      buf := allocate(memory, data_size, permissions => no_access);
      mock(logger, error);
      write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_fixed);
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(
        logger,
        "Reading from address 0 at offset 0 within anonymous buffer at range (0 to 15) without permission (no_access)",
        error
      );
      unmock(logger);
      -- The beat without permission has an error response
      read_data(x"2", base_address(buf), 0, axi_resp_slverr, true);

    elsif run("test_wrap_burst") then
      -- VUnit's slave does not support WRAP bursts; this one does
      buf := allocate(memory, 64, alignment => 64);
      for i in 0 to 63 loop

        write_byte(memory, i, i);
      end loop;

      write_addr(x"2", 8, 4, 2, axi_burst_type_wrap);
      for i in 0 to 3 loop

        read_data(x"2", (8 + 4 * i) mod 16, 4, axi_resp_okay, i = 3);
      end loop;

    elsif run("test_error_on_unsupported_wrap_burst") then
      buf := allocate(memory, 8);
      mock(logger, error);
      write_addr(x"2", base_address(buf), 3, 0, axi_burst_type_wrap);
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(logger, "Unsupported wrapping read burst #0 for id 2: 3 beats of 1 bytes from 0", error);
      unmock(logger);
      for i in 0 to 2 loop

        read_data(x"2", 0, 0, axi_resp_slverr, i = 2);
      end loop;

    elsif run("test_narrow_and_unaligned_bursts") then
      buf := allocate(memory, 64);
      for i in 0 to 63 loop

        write_byte(memory, i, 255 - i);
      end loop;

      -- An unaligned INCR burst of 4-byte beats: the first beat is 1 byte
      write_addr(x"1", 3, 3, 2, axi_burst_type_incr);
      read_data(x"1", 3, 1, axi_resp_okay, false);
      read_data(x"1", 4, 4, axi_resp_okay, false);
      read_data(x"1", 8, 4, axi_resp_okay, true);
      -- An unaligned full width beat
      write_addr(x"1", 21, 2, log_data_size, axi_burst_type_incr);
      read_data(x"1", 21, 11, axi_resp_okay, false);
      read_data(x"1", 32, 16, axi_resp_okay, true);

    elsif run("test_error_4kbyte_boundary_crossing") then
      buf := allocate(memory, 4096 + 256, alignment => 4096);
      mock(logger, error);
      write_addr(x"2", base_address(buf) + 4000, 256, 0, axi_burst_type_incr);
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(logger, "Crossing 4KByte boundary. First page = 0 (4000/4096), last page = 1 (4255/4096)", error);
      unmock(logger);

    elsif run("test_no_error_on_4kbyte_boundary_crossing_with_disabled_check") then
      -- The whole burst is read at its AR handshake, so all of it is allocated
      buf := allocate(memory, 4096 + 256, alignment => 4096);
      disable_4kbyte_boundary_check(net, axi_slave);
      write_addr(x"2", base_address(buf) + 4000, 256, 0, axi_burst_type_incr);
      wait until arvalid = '0' and rising_edge(clk);
      enable_4kbyte_boundary_check(net, axi_slave);

    elsif run("test_default_address_fifo_depth_is_1") then
      buf := allocate(memory, 1024);
      -- Taken by the data process, then in the queue
      write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_incr);
      write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_incr);
      for i in 0 to 127 loop

        wait until rising_edge(clk);
        check_equal(arready, '0', "Can only have one address in the queue");
      end loop;

    elsif run("test_set_address_fifo_depth") then
      buf := allocate(memory, 1024);
      set_address_fifo_depth(net, axi_slave, 16);
      for i in 0 to 16 loop

        write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_incr);
      end loop;

      for i in 0 to 127 loop

        wait until rising_edge(clk);
        check_equal(arready, '0', "Address queue should be full");
      end loop;

    elsif run("test_changing_address_depth_to_smaller_than_content_gives_error") then
      buf := allocate(memory, 1024);
      set_address_fifo_depth(net, axi_slave, 16);
      for i in 0 to 16 loop

        write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_incr);
      end loop;

      set_address_fifo_depth(net, axi_slave, 17);
      set_address_fifo_depth(net, axi_slave, 16);
      mock(logger, error);
      set_address_fifo_depth(net, axi_slave, 1);
      check_only_log(logger, "New address fifo depth 1 is smaller than current content size 16", error);
      unmock(logger);

    elsif run("test_address_stall_probability") then
      buf := allocate(memory, 1024);
      set_address_fifo_depth(net, axi_slave, 128);
      start_time := now;
      for i in 1 to 16 loop

        write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_incr);
      end loop;

      diff_time := now - start_time;
      set_address_stall_probability(net, axi_slave, 0.9);
      start_time := now;
      for i in 1 to 16 loop

        write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_incr);
      end loop;

      check(now - start_time > 5 * diff_time, "Should take longer with stall probability");

    elsif run("test_statistics") then
      buf := allocate(memory, 4096);
      transfer(0, 1, x"0", axi_burst_type_incr);
      transfer(0, 3, x"0", axi_burst_type_incr);
      transfer(0, 3, x"0", axi_burst_type_incr);
      get_statistics(net, axi_slave, stat);
      check_equal(num_bursts(stat), 3);
      check_equal(min_burst_length(stat), 1);
      check_equal(max_burst_length(stat), 3);
      check_equal(get_num_burst_with_length(stat, 3), 2);
      get_statistics(net, axi_slave, stat, clear => true);
      get_statistics(net, axi_slave, stat);
      check_equal(num_bursts(stat), 0);
      deallocate(stat);

    elsif run("test_wait_until_idle_and_reset") then
      buf := allocate(memory, 1024);
      set_response_latency(net, axi_slave, 200 ns);
      write_addr(x"2", base_address(buf), 4, log_data_size, axi_burst_type_incr);
      start_time := now;
      rready <= '1';
      wait_until_idle(net, as_sync(axi_slave));
      check(now - start_time >= 200 ns, "idle after the burst");
      rready <= '0';
      -- A reset drops the burst in progress
      write_addr(x"2", base_address(buf), 4, log_data_size, axi_burst_type_incr);
      reset(net, axi_slave);
      wait_until_idle(net, as_sync(axi_slave));
      for i in 0 to 50 loop

        wait until rising_edge(clk);
        check_equal(rvalid, '0', "no data after reset");
      end loop;

    elsif run("test_well_behaved_check_does_not_fail_for_well_behaved_bursts") then
      buf := allocate(memory, 128);
      enable_well_behaved_check(net, axi_slave);
      set_address_fifo_depth(net, axi_slave, 3);
      wait until rising_edge(clk);
      rready <= '1';
      check_equal(rvalid, '0');
      -- Only single beat bursts may be narrower than the bus
      write_addr(x"0", base_address(buf), len => 1, log_size => log_data_size, burst => axi_burst_type_incr);
      rready <= '1';
      check_equal(rvalid, '0');
      write_addr(x"0", base_address(buf), len => 2, log_size => log_data_size, burst => axi_burst_type_incr);
      rready <= '1';
      check_equal(rvalid, '1');
      write_addr(x"0", base_address(buf), len => 1, log_size => 0, burst => axi_burst_type_incr);
      rready <= '1';
      check_equal(rvalid, '1');
      wait until rising_edge(clk);
      rready <= '1';
      check_equal(rvalid, '1');
      wait until rising_edge(clk);
      rready <= '0';
      check_equal(rvalid, '1');
      wait until rising_edge(clk);
      rready <= '0';
      check_equal(rvalid, '0');
      for i in 0 to 2 loop

        wait until rising_edge(clk);
        check_equal(rvalid, '0');
      end loop;

    elsif run("test_well_behaved_check_does_not_fail_after_well_behaved_burst_finished") then
      buf := allocate(memory, 128);
      enable_well_behaved_check(net, axi_slave);
      wait until rising_edge(clk);
      rready <= '1';
      check_equal(rvalid, '0');
      write_addr(x"0", base_address(buf), len => 3, log_size => log_data_size, burst => axi_burst_type_incr);
      rready <= '1';
      check_equal(rvalid, '0');
      wait until rising_edge(clk);
      rready <= '1';
      check_equal(rvalid, '1');
      wait until rising_edge(clk);
      rready <= '1';
      check_equal(rvalid, '1');
      wait until rising_edge(clk);
      rready <= '0';
      check_equal(rvalid, '1');
      wait until rising_edge(clk);
      rready <= '0';
      check_equal(rvalid, '0');
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      check_equal(rvalid, '0');

    elsif run("test_well_behaved_check_fails_for_ill_behaved_arsize") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      mock(logger, error);
      rready <= '1';
      wait until rising_edge(clk);
      write_addr(x"0", base_address(buf), len => 2, log_size => 0, burst => axi_burst_type_incr);
      check_only_log(
        logger,
        "Burst not well behaved, axi size = 1 but bus data width allows " & to_string(data_size),
        error
      );
      unmock(logger);

    elsif run("test_well_behaved_check_fails_when_rready_not_high_during_active_burst") then
      buf := allocate(memory, 128);
      enable_well_behaved_check(net, axi_slave);
      mock(logger, error);
      wait until rising_edge(clk);
      write_addr(x"0", base_address(buf), len => 2, log_size => log_data_size, burst => axi_burst_type_incr);
      check_only_log(logger, "Burst not well behaved, rready was not high during active burst", error);
      unmock(logger);

    elsif run("test_well_behaved_check_fails_when_rready_not_high_and_arready_is_low") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      mock(logger, error);
      set_address_stall_probability(net, axi_slave, 1.0);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      check_equal(arready, '0');
      arvalid <= '1';
      arid <= x"0";
      araddr <= std_ulogic_vector(to_unsigned(base_address(buf), araddr'length));
      arlen <= x"00";
      arsize <= "000";
      arburst <= axi_burst_type_incr;
      wait until rising_edge(clk);
      check_equal(arready, '0');
      wait until mock_queue_length > 0 for 0 ns;
      check_only_log(logger, "Burst not well behaved, rready was not high during active burst", error);
      unmock(logger);
    end if;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);

  -- The payload of R is X while RVALID is 0
  check_not_valid : process
  begin

    wait until rising_edge(clk);
    if rvalid = '0' then
      check_equal(rid, std_ulogic_vector'("XXXX"), "RID not X when RVALID low");
      check_equal(rresp, std_ulogic_vector'("XX"), "RRESP not X when RVALID low");
      check_equal(rlast, 'X', "RLAST not X when RVALID low");
      for idx in rdata'range loop

        check_equal(rdata(idx), 'X', "RDATA not X when RVALID low");
      end loop;

    end if;
  end process;

  axi4_read_slave_inst : entity awesome_vunit_vcs.axi4_read_slave
    generic map (
      axi_slave => axi_slave
    )
    port map (
      aclk => clk,
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

  clk <= not clk after 5 ns;

end architecture;
