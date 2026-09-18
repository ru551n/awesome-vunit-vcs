-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Cost of the AXI4 monitor and protocol checker per recorded beat: the
-- testbench drives num_bursts writes and as many reads of 16 beats each at
-- full throughput, both sides of the interface, observed by nothing, a
-- monitor, or a monitor with its protocol checker. The cost per beat is
-- (with - without) / beats of wall clock time.

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_benchmark is
  generic (
    runner_cfg : string;
    config_name : string;
    data_length : positive := 32;
    num_bursts : positive := 5000;
    with_monitor : boolean := true;
    with_protocol_checker : boolean := false);
end entity;

architecture tb of tb_axi4_benchmark is

  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => data_length, address_length => 32, id_length => 4);

  impure function checker return axi4_protocol_checker_t is
  begin

    if with_protocol_checker then
      return new_axi4_protocol_checker;
    end if;
    return null_axi4_protocol_checker;
  end;

  constant monitor : axi4_monitor_t := new_axi4_monitor(axi4_bus, protocol_checker => checker);

  constant beats : positive := 16;

  signal aclk : std_ulogic := '0';
  signal awvalid : std_ulogic := '0';
  signal wvalid : std_ulogic := '0';
  signal wlast : std_ulogic := '0';
  signal bvalid : std_ulogic := '0';
  signal arvalid : std_ulogic := '0';
  signal rvalid : std_ulogic := '0';
  signal rlast : std_ulogic := '0';
  signal awaddr, araddr : std_ulogic_vector(31 downto 0) := (others => '0');
  signal wdata, rdata : std_ulogic_vector(data_length - 1 downto 0) := (others => '0');

begin

  aclk <= not aclk after 5 ns;

  monitor_gen : if with_monitor generate
    monitor_inst : entity awesome_vunit_vcs.axi4_monitor
      generic map (
        monitor => monitor
      )
      port map (
        aclk => aclk,
        awvalid => awvalid,
        awready => '1',
        awaddr => awaddr,
        awlen => std_ulogic_vector(to_unsigned(beats - 1, 8)),
        wvalid => wvalid,
        wready => '1',
        wdata => wdata,
        wlast => wlast,
        bvalid => bvalid,
        bready => '1',
        arvalid => arvalid,
        arready => '1',
        araddr => araddr,
        arlen => std_ulogic_vector(to_unsigned(beats - 1, 8)),
        rvalid => rvalid,
        rready => '1',
        rdata => rdata,
        rlast => rlast
      );

  end generate monitor_gen;

  main : process

    variable statistics : axi4_statistics_t;

  begin

    test_runner_setup(runner, runner_cfg);
    wait until rising_edge(aclk);
    for burst in 0 to num_bursts - 1 loop

      -- A write: the address with the first beat, then the response
      awaddr <= std_ulogic_vector(to_unsigned(256 * (burst mod 1024), 32));
      awvalid <= '1';
      wvalid <= '1';
      for beat in 0 to beats - 1 loop

        wdata <= std_ulogic_vector(to_unsigned(beat, data_length));
        wlast <= '1' when beat = beats - 1 else
                 '0';
        wait until rising_edge(aclk);
        awvalid <= '0';
      end loop;

      wvalid <= '0';
      bvalid <= '1';
      wait until rising_edge(aclk);
      bvalid <= '0';
      -- A read: the address, then its beats
      araddr <= awaddr;
      arvalid <= '1';
      wait until rising_edge(aclk);
      arvalid <= '0';
      rvalid <= '1';
      for beat in 0 to beats - 1 loop

        rdata <= std_ulogic_vector(to_unsigned(beat, data_length));
        rlast <= '1' when beat = beats - 1 else
                 '0';
        wait until rising_edge(aclk);
      end loop;

      rvalid <= '0';
    end loop;

    if with_monitor then
      get_axi4_statistics(net, monitor, statistics);
      check_equal(statistics.write_transactions, num_bursts, "writes");
      check_equal(statistics.read_transactions, num_bursts, "reads");
    end if;
    info("BENCHMARK " & config_name & " beats=" & to_string(2 * num_bursts * beats) & " sim=" & to_string(now));
    test_runner_cleanup(runner);
  end process;

end architecture;
