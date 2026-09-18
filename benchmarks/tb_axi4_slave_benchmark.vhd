-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Cost of the AXI4 read and write slaves per burst and per beat: the
-- testbench writes num_bursts bursts of ``beats`` beats and reads them back,
-- at full throughput, from VUnit's axi_write_slave and axi_read_slave on a
-- memory_t, or from axi4_write_slave and axi4_read_slave on an axi4_memory_t.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_slave_benchmark is
  generic (
    runner_cfg : string;
    config_name : string;
    beats : positive := 16;
    num_bursts : positive := 20000;
    vunit_slaves : boolean := false);
end entity;

architecture tb of tb_axi4_slave_benchmark is

  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 32, address_length => 32, id_length => 4);
  constant memory : axi4_memory_t := new_axi4_memory;
  constant write_slave : axi4_slave_t := new_axi4_slave(memory, axi4_bus);
  constant read_slave : axi4_slave_t := new_axi4_slave(memory, axi4_bus);
  constant vunit_memory : memory_t := new_memory;
  constant vunit_slave : axi_slave_t := new_axi_slave(vunit_memory, check_4kbyte_boundary => false);

  signal aclk : std_ulogic := '0';
  signal awvalid : std_ulogic := '0';
  signal awready : std_ulogic := '0';
  signal wvalid : std_ulogic := '0';
  signal wready : std_ulogic := '0';
  signal wlast : std_ulogic := '0';
  signal bvalid : std_ulogic := '0';
  signal arvalid : std_ulogic := '0';
  signal arready : std_ulogic := '0';
  signal rvalid : std_ulogic := '0';
  signal rlast : std_ulogic := '0';
  signal awaddr, araddr : std_ulogic_vector(31 downto 0) := (others => '0');
  signal awlen, arlen : std_ulogic_vector(7 downto 0) := (others => '0');
  signal wdata, rdata : std_ulogic_vector(31 downto 0) := (others => '0');
  signal bid, rid : std_ulogic_vector(3 downto 0);
  signal bresp, rresp : std_ulogic_vector(1 downto 0);

begin

  aclk <= not aclk after 5 ns;

  main : process

    variable start : time;
    variable buf : buffer_t;

  begin

    test_runner_setup(runner, runner_cfg);
    if vunit_slaves then
      buf := allocate(vunit_memory, 4 * beats * num_bursts);
    end if;
    awlen <= std_ulogic_vector(to_unsigned(beats - 1, 8));
    arlen <= std_ulogic_vector(to_unsigned(beats - 1, 8));
    start := now;
    for burst in 0 to num_bursts - 1 loop

      awaddr <= std_ulogic_vector(to_unsigned(4 * beats * burst, 32));
      awvalid <= '1';
      wait until rising_edge(aclk) and awready = '1';
      awvalid <= '0';
      for beat in 0 to beats - 1 loop

        wvalid <= '1';
        wdata <= std_ulogic_vector(to_unsigned(beat, 32));
        wlast <= '1' when beat = beats - 1 else
                 '0';
        wait until rising_edge(aclk) and wready = '1';
      end loop;

      wvalid <= '0';
      wait until rising_edge(aclk) and bvalid = '1';
      araddr <= std_ulogic_vector(to_unsigned(4 * beats * burst, 32));
      arvalid <= '1';
      wait until rising_edge(aclk) and arready = '1';
      arvalid <= '0';
      wait until rising_edge(aclk) and rvalid = '1' and rlast = '1';
    end loop;

    info(
      "BENCHMARK "
      & config_name
      & ": "
      & to_string(num_bursts)
      & " writes and reads of "
      & to_string(beats)
      & " beats in "
      & to_string((now - start) / 10 ns)
      & " cycles"
    );
    test_runner_cleanup(runner);
  end process;

  awesome_gen : if not vunit_slaves generate
    write_slave_inst : entity awesome_vunit_vcs.axi4_write_slave
      generic map (
        axi_slave => write_slave
      )
      port map (
        aclk => aclk,
        awvalid => awvalid,
        awready => awready,
        awaddr => awaddr,
        awlen => awlen,
        wvalid => wvalid,
        wready => wready,
        wdata => wdata,
        wlast => wlast,
        bvalid => bvalid,
        bready => '1',
        bid => bid,
        bresp => bresp
      );

    read_slave_inst : entity awesome_vunit_vcs.axi4_read_slave
      generic map (
        axi_slave => read_slave
      )
      port map (
        aclk => aclk,
        arvalid => arvalid,
        arready => arready,
        araddr => araddr,
        arlen => arlen,
        rvalid => rvalid,
        rready => '1',
        rid => rid,
        rdata => rdata,
        rresp => rresp,
        rlast => rlast
      );

  end generate awesome_gen;

  vunit_gen : if vunit_slaves generate
    write_slave_inst : entity vunit_lib.axi_write_slave
      generic map (
        axi_slave => vunit_slave
      )
      port map (
        aclk => aclk,
        awvalid => awvalid,
        awready => awready,
        awid => x"0",
        awaddr => awaddr,
        awlen => awlen,
        awsize => "010",
        awburst => "01",
        wvalid => wvalid,
        wready => wready,
        wdata => wdata,
        wstrb => "1111",
        wlast => wlast,
        bvalid => bvalid,
        bready => '1',
        bid => bid,
        bresp => bresp
      );

    read_slave_inst : entity vunit_lib.axi_read_slave
      generic map (
        axi_slave => vunit_slave
      )
      port map (
        aclk => aclk,
        arvalid => arvalid,
        arready => arready,
        arid => x"0",
        araddr => araddr,
        arlen => arlen,
        arsize => "010",
        arburst => "01",
        rvalid => rvalid,
        rready => '1',
        rid => rid,
        rdata => rdata,
        rresp => rresp,
        rlast => rlast
      );

  end generate vunit_gen;

end architecture;
