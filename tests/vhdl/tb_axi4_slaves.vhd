-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A read slave and a write slave sharing one memory on a 64-bit address bus,
-- with random stalls and latencies, watched by an AXI4 monitor with a protocol
-- checker and a shadow memory: every read returns what was written before it,
-- and the slaves break no rule of the protocol.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library osvvm;
  use osvvm.randompkg.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_slaves is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_axi4_slaves is

  constant data_bytes : natural := 4;
  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 8 * data_bytes, address_length => 64, id_length => 4);
  -- Where the bursts go: a window near the top of the 64-bit address space
  constant base : u_unsigned(63 downto 0) := x"FFFF_FFF0_0000_0000";

  constant memory : axi4_memory_t := new_axi4_memory;
  constant read_slave : axi4_slave_t := new_axi4_slave(
    memory,
    axi4_bus,
    address_fifo_depth => 4,
    address_stall_probability => 0.3,
    data_stall_probability => 0.3,
    min_response_latency => 0 ns,
    max_response_latency => 50 ns,
    seed => 1,
    id => get_id("tb_axi4_slaves:read_slave")
  );
  constant write_slave : axi4_slave_t := new_axi4_slave(
    memory,
    axi4_bus,
    address_fifo_depth => 4,
    write_response_fifo_depth => 2,
    address_stall_probability => 0.3,
    data_stall_probability => 0.3,
    write_response_stall_probability => 0.3,
    min_response_latency => 0 ns,
    max_response_latency => 50 ns,
    seed => 2,
    id => get_id("tb_axi4_slaves:write_slave")
  );
  constant monitor : axi4_monitor_t := new_axi4_monitor(
    axi4_bus,
    protocol_checker => new_axi4_protocol_checker(axi4_bus),
    shadow_memory => true,
    id => get_id("tb_axi4_slaves:monitor")
  );

  signal aclk : std_ulogic := '0';
  signal awvalid, awready : std_ulogic := '0';
  signal awid : std_ulogic_vector(3 downto 0) := (others => '0');
  signal awaddr : std_ulogic_vector(63 downto 0) := (others => '0');
  signal awlen : std_ulogic_vector(7 downto 0) := (others => '0');
  signal awsize : std_ulogic_vector(2 downto 0) := (others => '0');
  signal awburst : std_ulogic_vector(1 downto 0) := "01";
  signal wvalid, wready : std_ulogic := '0';
  signal wdata : std_ulogic_vector(8 * data_bytes - 1 downto 0) := (others => '0');
  signal wstrb : std_ulogic_vector(data_bytes - 1 downto 0) := (others => '0');
  signal wlast : std_ulogic := '0';
  signal bvalid, bready : std_ulogic := '0';
  signal bid : std_ulogic_vector(3 downto 0);
  signal bresp : std_ulogic_vector(1 downto 0);
  signal arvalid, arready : std_ulogic := '0';
  signal arid : std_ulogic_vector(3 downto 0) := (others => '0');
  signal araddr : std_ulogic_vector(63 downto 0) := (others => '0');
  signal arlen : std_ulogic_vector(7 downto 0) := (others => '0');
  signal arsize : std_ulogic_vector(2 downto 0) := (others => '0');
  signal arburst : std_ulogic_vector(1 downto 0) := "01";
  signal rvalid, rready : std_ulogic := '0';
  signal rid : std_ulogic_vector(3 downto 0);
  signal rdata : std_ulogic_vector(8 * data_bytes - 1 downto 0);
  signal rresp : std_ulogic_vector(1 downto 0);
  signal rlast : std_ulogic;

begin

  main : process

    variable rnd : randomptype;

    type burst_t is record
      id     : natural;
      offset : natural;
      len    : natural;
      size   : natural;
      burst  : std_ulogic_vector(1 downto 0);
    end record;

    type burst_vector_t is array (natural range <>) of burst_t;

    variable bursts : burst_vector_t(0 to 63);

    impure function random_burst return burst_t is

      variable result : burst_t;
    begin

      result.id := rnd.RandInt(0, 15);
      result.size := rnd.RandInt(0, 2);

      case rnd.RandInt(0, 2) is
        when 0 =>

          result.burst := axi_burst_type_fixed;
          result.len := rnd.RandInt(0, 15);
          result.offset := rnd.RandInt(0, 4095);
        when 1 =>

          -- An INCR burst of up to 64 bytes that does not cross 4 KB, often unaligned
          result.burst := axi_burst_type_incr;
          result.len := rnd.RandInt(0, 15);
          result.offset := 4096 * rnd.RandInt(0, 15) + rnd.RandInt(0, 4096 - 64 - 4);
        when others =>

          result.burst := axi_burst_type_wrap;
          result.len := 2 ** rnd.RandInt(1, 4) - 1;
          result.offset := rnd.RandInt(0, 4095) / 2 ** result.size * 2 ** result.size;
      end case;

      return result;
    end;

    -- The address of each beat, following the AXI specification
    function beat_address (burst : burst_t; beat : natural) return natural is

      constant number_bytes : natural := 2 ** burst.size;
      constant aligned : natural := burst.offset / number_bytes * number_bytes;
      constant total : natural := number_bytes * (burst.len + 1);
      constant boundary : natural := burst.offset / total * total;
    begin

      if beat = 0 or burst.burst = axi_burst_type_fixed then
        return burst.offset;
      elsif burst.burst = axi_burst_type_incr then
        return aligned + beat * number_bytes;
      end if;
      return boundary + (burst.offset - boundary + beat * number_bytes) mod total;
    end;

    -- A burst of random data; each byte is strobed with a probability of 3/4, or always when ``full``
    procedure write_burst (burst : burst_t; full : boolean := false) is

      variable address, lane : natural;
    begin

      awvalid <= '1';
      awid <= std_ulogic_vector(to_unsigned(burst.id, 4));
      awaddr <= std_ulogic_vector(base + burst.offset);
      awlen <= std_ulogic_vector(to_unsigned(burst.len, 8));
      awsize <= std_ulogic_vector(to_unsigned(burst.size, 3));
      awburst <= burst.burst;
      wait until (awvalid and awready) = '1' and rising_edge(aclk);
      awvalid <= '0';
      for beat in 0 to burst.len loop

        address := beat_address(burst, beat);
        wstrb <= (others => '0');
        wdata <= rnd.RandSlv(8 * data_bytes);
        -- The lanes of the beat, from its address to the end of its aligned size
        lane := address mod data_bytes;
        while lane < data_bytes loop

          wstrb(lane) <= '1' when full or rnd.RandInt(0, 3) /= 0 else
                         '0';
          lane := lane + 1;
          exit when lane mod 2 ** burst.size = 0;
        end loop;

        wlast <= '1' when beat = burst.len else
                 '0';
        wvalid <= '1';
        wait until (wvalid and wready) = '1' and rising_edge(aclk);
        wvalid <= '0';
      end loop;

      bready <= '1';
      wait until (bvalid and bready) = '1' and rising_edge(aclk);
      check_equal(bresp, axi_resp_okay, "bresp");
      check_equal(bid, std_ulogic_vector(to_unsigned(burst.id, 4)), "bid");
      bready <= '0';
    end;

    procedure read_burst (burst : burst_t) is
    begin

      arvalid <= '1';
      arid <= std_ulogic_vector(to_unsigned(burst.id, 4));
      araddr <= std_ulogic_vector(base + burst.offset);
      arlen <= std_ulogic_vector(to_unsigned(burst.len, 8));
      arsize <= std_ulogic_vector(to_unsigned(burst.size, 3));
      arburst <= burst.burst;
      wait until (arvalid and arready) = '1' and rising_edge(aclk);
      arvalid <= '0';
      for beat in 0 to burst.len loop

        rready <= '1' when rnd.RandInt(0, 3) /= 0 else
                  '0';
        wait until rising_edge(aclk);
        while (rvalid and rready) /= '1' loop

          rready <= '1' when rnd.RandInt(0, 3) /= 0 else
                    '0';
          wait until rising_edge(aclk);
        end loop;

        check_equal(rresp, axi_resp_okay, "rresp");
        check_equal(rlast, beat = burst.len, "rlast");
      end loop;

      rready <= '0';
    end;

    variable count : natural;
    variable statistics : axi4_statistics_t;

  begin

    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));

    if run("test_read_after_write_on_shared_memory") then
      for idx in bursts'range loop

        bursts(idx) := random_burst;
        write_burst(bursts(idx));
      end loop;

      for idx in bursts'range loop

        read_burst(bursts(idx));
      end loop;

      wait_until_idle(net, as_sync(write_slave));
      wait_until_idle(net, as_sync(read_slave));
      wait_until_idle(net, as_sync(monitor));
      for check in axi4_metavalue to axi4_timeout loop

        get_check_count(net, protocol_checker(monitor), check, count);
        check_equal(count, 0, "violations of " & axi4_check_t'image(check));
      end loop;

      get_axi4_statistics(net, monitor, statistics);
      check_equal(statistics.write_transactions, 64);
      check_equal(statistics.read_transactions, 64);
      check_equal(statistics.error_responses, 0);

    elsif run("test_backdoor_and_slaves_share_the_memory") then
      -- What the testbench writes, the read slave reads
      write_word(memory, base + 16#200#, x"CAFEF00D");
      read_burst((id => 2, offset => 16#200#, len => 0, size => 2, burst => axi_burst_type_incr));
      check_equal(rdata, std_ulogic_vector'(x"CAFEF00D"));
      -- What the write slave writes, the testbench checks: random data is not
      -- the expected word, a check failure on the checker of the write slave
      set_expected_word(memory, base + 16#100#, x"00000000");
      disable_stop(get_logger(write_slave), error);
      write_burst((id => 1, offset => 16#100#, len => 0, size => 2, burst => axi_burst_type_incr), full => true);
      check_equal(get_log_count(get_logger(write_slave), error), 1);
      reset_log_count(get_logger(write_slave), error);
      check_false(expected_was_written(memory));
      set_expected_word(memory, base + 16#100#, read_word(memory, base + 16#100#, 4));
      check_true(expected_was_written(memory));
    end if;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 ms);

  aclk <= not aclk after 5 ns;

  axi4_write_slave_inst : entity awesome_vunit_vcs.axi4_write_slave
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

  axi4_read_slave_inst : entity awesome_vunit_vcs.axi4_read_slave
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

  axi4_monitor_inst : entity awesome_vunit_vcs.axi4_monitor
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

end architecture;
