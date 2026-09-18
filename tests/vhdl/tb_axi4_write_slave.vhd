-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI4 write slave: the scenarios of VUnit's tb_axi_write_slave on the
-- new slave, and what it adds (WRAP bursts, error responses, metavalues,
-- statistics, reset). The failures VUnit's slave logs as failures are check
-- failures on the checker of the slave here.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library osvvm;
  use osvvm.randompkg.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_write_slave is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_write_slave is

  constant log_data_size : integer := 4;
  constant data_size : integer := 2 ** log_data_size;
  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 8 * data_size, id_length => 4);

  signal clk : std_ulogic := '1';

  signal awvalid : std_ulogic := '0';
  signal awready : std_ulogic;
  signal awid : std_ulogic_vector(3 downto 0);
  signal awaddr : std_ulogic_vector(31 downto 0);
  signal awlen : std_ulogic_vector(7 downto 0);
  signal awsize : std_ulogic_vector(2 downto 0);
  signal awburst : std_ulogic_vector(1 downto 0);

  signal wvalid : std_ulogic := '0';
  signal wready : std_ulogic := '0';
  signal wdata : std_ulogic_vector(8 * data_size - 1 downto 0);
  signal wstrb : std_ulogic_vector(data_size - 1 downto 0);
  signal wlast : std_ulogic;

  signal bvalid : std_ulogic := '0';
  signal bready : std_ulogic;
  signal bid : std_ulogic_vector(awid'range);
  signal bresp : std_ulogic_vector(1 downto 0);

  constant memory : axi4_memory_t := new_axi4_memory(default_permissions => no_access);
  constant axi_slave : axi4_slave_t := new_axi4_slave(memory, axi4_bus);

begin

  main : process

    constant logger : logger_t := get_logger(axi_slave);
    variable rnd : randomptype;

    procedure read_response (id : std_ulogic_vector; resp : std_ulogic_vector(1 downto 0) := axi_resp_okay) is
    begin

      bready <= '1';
      wait until (bvalid and bready) = '1' and rising_edge(clk);
      check_equal(bresp, resp, "bresp");
      check_equal(bid, id, "bid");
      bready <= '0';
    end;

    procedure write_addr (
      id : std_ulogic_vector;
      addr : natural;
      len : natural;
      log_size : natural;
      burst : std_ulogic_vector(1 downto 0)
    ) is
    begin

      awvalid <= '1';
      awid <= id;
      awaddr <= std_ulogic_vector(to_unsigned(addr, awaddr'length));
      awlen <= std_ulogic_vector(to_unsigned(len - 1, awlen'length));
      awsize <= std_ulogic_vector(to_unsigned(log_size, awsize'length));
      awburst <= burst;
      wait until (awvalid and awready) = '1' and rising_edge(clk);
      awvalid <= '0';
    end;

    -- An INCR burst of ``num_bytes`` random bytes from the base of buf, which
    -- the bytes must be written to
    procedure transfer_data (id : std_ulogic_vector; buf : axi4_buffer_t; log_size : natural; num_bytes : natural) is

      variable size : natural;
      variable len : natural;
      variable address : natural;
      variable idx : natural;
      variable byte : natural;
    begin

      size := 2 ** log_size;
      len := (num_bytes + (base_address(buf) mod size)) / data_size;
      write_addr(id, base_address(buf), len, log_size, axi_burst_type_incr);
      address := base_address(buf);
      for j in 0 to len - 1 loop

        wstrb <= (others => '0');
        for i in 0 to size - 1 - (address mod data_size) loop

          idx := address mod data_size;
          byte := rnd.RandInt(0, 255);
          wstrb(idx) <= '1';
          wdata(8 * idx + 7 downto 8 * idx) <= std_ulogic_vector(to_unsigned(byte, 8));
          set_permissions(memory, address, write_only);
          set_expected_byte(memory, address, byte);
          address := address + 1;
        end loop;

        wlast <= '1' when j = len - 1 else
                 '0';
        wvalid <= '1';
        wait until (wvalid and wready) = '1' and rising_edge(clk);
        wvalid <= '0';
        wstrb <= (others => '0');
        wdata <= (others => '0');
      end loop;

    end;

    procedure transfer (id : std_ulogic_vector; buf : axi4_buffer_t; log_size : natural; num_bytes : natural) is
    begin

      transfer_data(id, buf, log_size, num_bytes);
      read_response(id, axi_resp_okay);
      check_expected_was_written(buf);
    end;

    variable buf : axi4_buffer_t;
    variable size, log_size : natural;
    variable id : std_ulogic_vector(awid'range);
    variable len : natural;
    variable burst : std_ulogic_vector(1 downto 0);
    variable idx : integer;
    variable num_ops : integer;
    variable start_time, diff_time : time;
    variable stat : axi_statistics_t;
    variable byte : natural;
    variable strobe : boolean;

    constant dummy_byte : natural := 13;
    constant large_latency : time := 1 us;

  begin

    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(rnd'instance_name);

    if run("test_random_writes") then
      num_ops := 0;
      for test_idx in 0 to 32 - 1 loop

        id := rnd.RandSlv(awid'length);
        if rnd.RandInt(1) = 0 then
          burst := axi_burst_type_fixed;
          len := 1;
        else
          burst := axi_burst_type_incr;
          len := rnd.RandInt(1, 2 ** awlen'length);
        end if;
        log_size := rnd.RandInt(0, 3);
        size := 2 ** log_size;
        buf := allocate(memory, 8 * len, alignment => 4096);
        write_addr(id, base_address(buf), len, log_size, burst);
        for j in 0 to len - 1 loop

          for i in 0 to size - 1 loop

            idx := (base_address(buf) + j * size + i) mod data_size;
            byte := rnd.RandInt(0, 255);
            strobe := rnd.RandInt(1) = 1;
            wdata(8 * idx + 7 downto 8 * idx) <= std_ulogic_vector(to_unsigned(byte, 8));
            wstrb(idx) <= '1' when strobe else
                          '0';
            if strobe then
              set_expected_byte(memory, base_address(buf) + j * size + i, byte);
              num_ops := num_ops + 1;
            else
              set_permissions(memory, base_address(buf) + j * size + i, no_access);
            end if;
          end loop;

          wlast <= '1' when j = len - 1 else
                   '0';
          wvalid <= '1';
          wait until (wvalid and wready) = '1' and rising_edge(clk);
          wvalid <= '0';
          wstrb <= (others => '0');
          wdata <= (others => '0');
        end loop;

        read_response(id, axi_resp_okay);
        check_expected_was_written(buf);
      end loop;

      check(num_ops > 1000, "operations " & to_string(num_ops));

    elsif run("test_that_permissions_are_checked") then
      buf := allocate(memory, data_size, permissions => no_access);
      write_addr(x"0", base_address(buf), 1, log_data_size, axi_burst_type_fixed);
      wvalid <= '1';
      wlast <= '1';
      wstrb <= (0 => '1', others => '0');
      wdata <= (others => '0');
      mock(logger, error);
      wait until (wvalid and wready) = '1' and rising_edge(clk);
      wvalid <= '0';
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(
        logger,
        "Writing to address 0 at offset 0 within anonymous buffer at range (0 to 15) without permission (no_access)",
        error
      );
      unmock(logger);
      -- The strobed byte without permission makes the response an error
      read_response(x"0", axi_resp_slverr);

    elsif run("test_expected_data_is_checked") then
      buf := allocate(memory, data_size);
      set_expected_byte(memory, 1, 77);
      write_addr(x"0", base_address(buf), 1, log_data_size, axi_burst_type_incr);
      wvalid <= '1';
      wlast <= '1';
      wstrb <= (others => '1');
      wdata <= (others => '0');
      mock(logger, error);
      wait until (wvalid and wready) = '1' and rising_edge(clk);
      wvalid <= '0';
      read_response(x"0", axi_resp_okay);
      check_only_log(logger, "Writing to " & describe_address(memory, 1) & ". Got 0 expected 77", error);
      unmock(logger);
      -- A slave writes the byte anyway, as VUnit's does
      check_equal(read_byte(memory, 1), 0);

    elsif run("test_data_stall_probability") then
      for i in 0 to 4 loop

        if i = 2 then
          set_data_stall_probability(net, axi_slave, 0.9);
        else
          set_data_stall_probability(net, axi_slave, 0.0);
        end if;
        buf := allocate(memory, data_size * 128, permissions => no_access);
        start_time := now;
        transfer(x"2", buf, log_data_size, data_size * 128);
        if i = 1 or i = 4 then
          check_equal(diff_time, now - start_time);
        elsif i = 2 then
          check(5 * diff_time < now - start_time);
        end if;
        diff_time := now - start_time;
      end loop;

    elsif run("test_response_latency") then
      for i in 0 to 1 loop

        if i = 1 then
          set_response_latency(net, axi_slave, large_latency);
        end if;
        buf := allocate(memory, data_size * 128, permissions => no_access);
        -- A known value, to check that the data is not written too early
        fill(memory, base_address(buf), num_bytes(buf), dummy_byte);
        start_time := now;
        transfer_data(x"2", buf, log_data_size, num_bytes(buf));
        if i = 1 then
          wait for large_latency - 10 ns;
          check_equal(read_byte(memory, base_address(buf)), dummy_byte, "Data should not be set yet");
          check_equal(read_byte(memory, last_address(buf)), dummy_byte, "Data should not be set yet");
        end if;
        read_response(x"2", axi_resp_okay);
        check_expected_was_written(buf);
        if i = 1 then
          check_equal(diff_time + large_latency, now - start_time);
        end if;
        diff_time := now - start_time;
      end loop;

    elsif run("test_write_response_stall_probability") then
      for i in 0 to 4 loop

        if i = 2 then
          set_write_response_stall_probability(net, axi_slave, 0.95);
        else
          set_write_response_stall_probability(net, axi_slave, 0.0);
        end if;
        buf := allocate(memory, data_size, permissions => no_access);
        start_time := now;
        for j in 0 to 128 loop

          transfer(x"2", buf, log_data_size, data_size);
        end loop;

        if i = 1 or i = 4 then
          check_equal(diff_time, now - start_time);
        elsif i = 2 then
          check(5 * diff_time < now - start_time);
        end if;
        diff_time := now - start_time;
      end loop;

    elsif run("test_write_response_fifo_depth") then
      set_write_response_fifo_depth(net, axi_slave, 4);
      set_address_fifo_depth(net, axi_slave, 4);
      bready <= '0';
      -- Four bursts are accepted while their responses wait for BREADY
      for j in 0 to 3 loop

        buf := allocate(memory, data_size);
        transfer_data(x"1", buf, log_data_size, data_size);
      end loop;

      mock(logger, error);
      set_write_response_fifo_depth(net, axi_slave, 2);
      check_only_log(logger, "New write response fifo depth 2 is smaller than current content size 3", error);
      unmock(logger);
      for j in 0 to 3 loop

        read_response(x"1");
      end loop;

    elsif run("test_narrow_write") then
      buf := allocate(memory, data_size, permissions => no_access);
      transfer(x"2", buf, log_data_size - 1, data_size);

    elsif run("test_unaligned_narrow_write") then
      -- An unaligned address
      buf := allocate(memory, 1);
      buf := allocate(memory, data_size, permissions => no_access);
      transfer(x"2", buf, log_data_size - 1, data_size);

    elsif run("test_unaligned_write") then
      buf := allocate(memory, 1);
      buf := allocate(memory, 2 * data_size, permissions => no_access);
      transfer(x"2", buf, log_data_size, 2 * data_size);

    elsif run("test_unaligned_write_around_4kbyte_boundary") then
      buf := allocate(memory, 4096 - data_size + 1, permissions => no_access);
      buf := allocate(memory, data_size, permissions => no_access);
      transfer(x"2", buf, log_data_size, data_size);

    elsif run("test_wrap_write") then
      -- VUnit's slave does not support WRAP bursts; this one does
      buf := allocate(memory, 16, alignment => 16);
      write_addr(x"3", 8, 4, 2, axi_burst_type_wrap);
      for j in 0 to 3 loop

        wstrb <= (others => '0');
        wdata <= (others => '0');
        idx := (8 + 4 * j) mod 16;
        wstrb(idx + 3 downto idx) <= "1111";
        wdata(8 * idx + 31 downto 8 * idx) <= std_ulogic_vector(to_unsigned(16#11# * (j + 1), 32));
        wlast <= '1' when j = 3 else
                 '0';
        wvalid <= '1';
        wait until (wvalid and wready) = '1' and rising_edge(clk);
        wvalid <= '0';
      end loop;

      read_response(x"3");
      check_equal(read_word(memory, 8, 4), std_ulogic_vector'(x"00000011"));
      check_equal(read_word(memory, 12, 4), std_ulogic_vector'(x"00000022"));
      check_equal(read_word(memory, 0, 4), std_ulogic_vector'(x"00000033"));
      check_equal(read_word(memory, 4, 4), std_ulogic_vector'(x"00000044"));

    elsif run("test_metavalue_in_written_data") then
      buf := allocate(memory, data_size);
      write_addr(x"0", base_address(buf), 1, log_data_size, axi_burst_type_incr);
      wvalid <= '1';
      wlast <= '1';
      wstrb <= (others => '1');
      wdata <= (others => '0');
      wdata(15 downto 8) <= "0000X000";
      mock(logger, error);
      wait until (wvalid and wready) = '1' and rising_edge(clk);
      wvalid <= '0';
      read_response(x"0");
      check_only_log(logger, "Metavalue in WDATA lane 1 of beat 0 of write burst #0 for id 0, written as 0", error);
      unmock(logger);

    elsif run("test_error_on_missing_wlast_fixed") then
      buf := allocate(memory, 8);
      write_addr(x"2", base_address(buf), 1, 0, axi_burst_type_fixed);
      mock(logger, error);
      wvalid <= '1';
      wlast <= '0';
      wstrb <= (others => '0');
      wait until (wvalid and wready) = '1' and rising_edge(clk);
      wvalid <= '0';
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(
        logger,
        "Expected wlast='1' on last beat of burst #0 for id 2 with length 1 starting at address 0",
        error
      );
      unmock(logger);
      read_response(x"2", axi_resp_okay);

    elsif run("test_error_on_missing_wlast_incr") then
      buf := allocate(memory, 8);
      write_addr(x"3", base_address(buf), 2, 0, axi_burst_type_incr);
      wvalid <= '1';
      wlast <= '0';
      wstrb <= (others => '0');
      wait until (wvalid and wready) = '1' and rising_edge(clk);
      wvalid <= '0';
      wait until wvalid = '0' and rising_edge(clk);
      mock(logger, error);
      wvalid <= '1';
      wait until (wvalid and wready) = '1' and rising_edge(clk);
      wvalid <= '0';
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(
        logger,
        "Expected wlast='1' on last beat of burst #0 for id 3 with length 2 starting at address 0",
        error
      );
      unmock(logger);
      read_response(x"3", axi_resp_okay);

    elsif run("test_error_on_reserved_burst_type") then
      buf := allocate(memory, 8);
      mock(logger, error);
      write_addr(x"2", base_address(buf), 1, 0, "11");
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(logger, "Unsupported burst type 0b11 (reserved) of write burst #0 for id 2", error);
      unmock(logger);
      wvalid <= '1';
      wlast <= '1';
      wstrb <= (others => '1');
      wait until (wvalid and wready) = '1' and rising_edge(clk);
      wvalid <= '0';
      read_response(x"2", axi_resp_slverr);

    elsif run("test_error_4kbyte_boundary_crossing") then
      buf := allocate(memory, 4096 + 32, alignment => 4096);
      mock(logger, error);
      write_addr(x"2", base_address(buf) + 4000, 256, 0, axi_burst_type_incr);
      wait until mock_queue_length > 0 and rising_edge(clk);
      check_only_log(logger, "Crossing 4KByte boundary. First page = 0 (4000/4096), last page = 1 (4255/4096)", error);
      unmock(logger);

    elsif run("test_no_error_on_4kbyte_boundary_crossing_with_disabled_check") then
      buf := allocate(memory, 4096 + 32, alignment => 4096);
      disable_4kbyte_boundary_check(net, axi_slave);
      write_addr(x"2", base_address(buf) + 4000, 256, 0, axi_burst_type_incr);
      wait until awvalid = '0' and rising_edge(clk);

    elsif run("test_default_address_depth_is_1") then
      write_addr(x"2", 0, 1, 0, axi_burst_type_incr);
      write_addr(x"2", 0, 1, 0, axi_burst_type_incr);
      for i in 0 to 127 loop

        wait until rising_edge(clk);
        check_equal(awready, '0', "Can only have one address in the queue");
      end loop;

    elsif run("test_set_address_fifo_depth") then
      set_address_fifo_depth(net, axi_slave, 16);
      for i in 0 to 16 loop

        write_addr(x"2", 0, 1, 0, axi_burst_type_incr);
      end loop;

      for i in 0 to 127 loop

        wait until rising_edge(clk);
        check_equal(awready, '0', "Address queue should be full");
      end loop;

    elsif run("test_changing_address_depth_to_smaller_than_content_gives_error") then
      set_address_fifo_depth(net, axi_slave, 16);
      for i in 0 to 16 loop

        write_addr(x"2", 0, 1, 0, axi_burst_type_incr);
      end loop;

      set_address_fifo_depth(net, axi_slave, 17);
      set_address_fifo_depth(net, axi_slave, 16);
      mock(logger, error);
      set_address_fifo_depth(net, axi_slave, 1);
      check_only_log(logger, "New address fifo depth 1 is smaller than current content size 16", error);
      unmock(logger);

    elsif run("test_address_stall_probability") then
      set_address_fifo_depth(net, axi_slave, 128);
      start_time := now;
      for i in 1 to 16 loop

        write_addr(x"2", 0, 1, 0, axi_burst_type_incr);
      end loop;

      diff_time := now - start_time;
      set_address_stall_probability(net, axi_slave, 0.9);
      start_time := now;
      for i in 1 to 16 loop

        write_addr(x"2", 0, 1, 0, axi_burst_type_incr);
      end loop;

      check(now - start_time > 5 * diff_time, "Should take longer with stall probability");

    elsif run("test_statistics_and_reset") then
      set_address_fifo_depth(net, axi_slave, 4);
      for i in 1 to 3 loop

        write_addr(x"2", 0, i, 0, axi_burst_type_incr);
      end loop;

      get_statistics(net, axi_slave, stat, clear => true);
      check_equal(num_bursts(stat), 3);
      check_equal(get_num_burst_with_length(stat, 2), 1);
      -- A reset drops the bursts waiting for data
      reset(net, axi_slave);
      wait_until_idle(net, as_sync(axi_slave));
      wait until rising_edge(clk);
      check_equal(wready, '0');
      get_statistics(net, axi_slave, stat);
      check_equal(num_bursts(stat), 0);
      deallocate(stat);

    elsif run("test_well_behaved_check_does_not_fail_for_well_behaved_bursts") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      set_address_fifo_depth(net, axi_slave, 3);
      set_write_response_fifo_depth(net, axi_slave, 3);
      bready <= '1';
      wstrb <= (others => '0');
      wait until rising_edge(clk);
      wvalid <= '1';
      wlast <= '1';
      check_equal(wready, '0');
      write_addr(x"0", base_address(buf), len => 1, log_size => log_data_size, burst => axi_burst_type_incr);
      wvalid <= '1';
      wlast <= '1';
      check_equal(wready, '0');
      write_addr(x"0", base_address(buf), len => 2, log_size => log_data_size, burst => axi_burst_type_incr);
      wvalid <= '1';
      wlast <= '0';
      check_equal(wready, '1');
      write_addr(x"0", base_address(buf), len => 1, log_size => 0, burst => axi_burst_type_incr);
      wvalid <= '1';
      wlast <= '1';
      check_equal(wready, '1');
      wait until rising_edge(clk);
      wvalid <= '1';
      wlast <= '1';
      check_equal(wready, '1');
      wait until rising_edge(clk);
      wvalid <= '0';
      wlast <= '0';
      check_equal(wready, '1');
      wait until rising_edge(clk);
      check_equal(wready, '0');
      for i in 0 to 2 loop

        wait until rising_edge(clk);
        check_equal(wready, '0');
      end loop;

    elsif run("test_well_behaved_check_does_not_fail_after_well_behaved_burst_finished") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      bready <= '1';
      wstrb <= (others => '0');
      wait until rising_edge(clk);
      wvalid <= '1';
      wlast <= '0';
      check_equal(wready, '0');
      write_addr(x"0", base_address(buf), len => 3, log_size => log_data_size, burst => axi_burst_type_incr);
      wvalid <= '1';
      wlast <= '0';
      check_equal(wready, '0');
      wait until rising_edge(clk);
      wvalid <= '1';
      wlast <= '0';
      check_equal(wready, '1');
      wait until rising_edge(clk);
      wvalid <= '1';
      wlast <= '1';
      check_equal(wready, '1');
      wait until rising_edge(clk);
      wvalid <= '0';
      wlast <= '0';
      check_equal(wready, '1');
      wait until rising_edge(clk);
      check_equal(wready, '0');
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      check_equal(wready, '0');

    elsif run("test_well_behaved_check_fails_for_ill_behaved_awsize") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      mock(logger, error);
      bready <= '1';
      wait until rising_edge(clk);
      wvalid <= '1';
      wlast <= '0';
      write_addr(x"0", base_address(buf), len => 2, log_size => 0, burst => axi_burst_type_incr);
      check_only_log(
        logger,
        "Burst not well behaved, axi size = 1 but bus data width allows " & to_string(data_size),
        error
      );
      unmock(logger);

    elsif run("test_well_behaved_check_fails_when_wvalid_not_high_during_active_burst") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      mock(logger, error);
      bready <= '1';
      wait until rising_edge(clk);
      write_addr(x"0", base_address(buf), len => 2, log_size => log_data_size, burst => axi_burst_type_incr);
      check_only_log(logger, "Burst not well behaved, wvalid was not high during active burst", error);
      unmock(logger);

    elsif run("test_well_behaved_check_fails_when_bready_not_high_during_active_burst") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      mock(logger, error);
      wvalid <= '1';
      wait until rising_edge(clk);
      write_addr(x"0", base_address(buf), len => 2, log_size => log_data_size, burst => axi_burst_type_incr);
      check_only_log(logger, "Burst not well behaved, bready was not high during active burst", error);
      unmock(logger);

    elsif run("test_well_behaved_check_fails_when_wvalid_not_high_and_awready_is_low") then
      buf := allocate(memory, 8);
      enable_well_behaved_check(net, axi_slave);
      mock(logger, error);
      set_address_stall_probability(net, axi_slave, 1.0);
      bready <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      check_equal(awready, '0');
      awvalid <= '1';
      awid <= x"0";
      awaddr <= std_ulogic_vector(to_unsigned(base_address(buf), awaddr'length));
      awlen <= x"00";
      awsize <= "000";
      awburst <= axi_burst_type_incr;
      wait until rising_edge(clk);
      check_equal(awready, '0');
      wait until mock_queue_length > 0 for 0 ns;
      check_only_log(logger, "Burst not well behaved, wvalid was not high during active burst", error);
      unmock(logger);
    end if;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);

  -- The payload of B is X while BVALID is 0
  check_not_valid : process
  begin

    wait until rising_edge(clk);
    if bvalid = '0' then
      check_equal(bid, std_ulogic_vector'("XXXX"), "BID not X when BVALID low");
      check_equal(bresp, std_ulogic_vector'("XX"), "BRESP not X when BVALID low");
    end if;
  end process;

  axi4_write_slave_inst : entity awesome_vunit_vcs.axi4_write_slave
    generic map (
      axi_slave => axi_slave
    )
    port map (
      aclk => clk,
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

  clk <= not clk after 5 ns;

end architecture;
