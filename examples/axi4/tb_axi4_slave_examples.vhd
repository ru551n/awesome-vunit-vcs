-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI4 slave examples of the documentation: an axi4_read_slave and an
-- axi4_write_slave sharing one sparse axi4_memory_t, driven by VUnit's
-- axi_lite_master and watched by an AXI4 monitor with its protocol checker.
-- In a real test your design is the master.

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_slave_examples is
  generic (
    runner_cfg : string;
    tb_path : string);
end entity;

architecture tb of tb_axi4_slave_examples is

  -- docs-start: memory
  -- A sparse memory: the whole 64-bit address space costs nothing until it is
  -- touched. Addresses no buffer covers are no_access, as in VUnit's memory.
  constant memory : axi4_memory_t := new_axi4_memory(default_permissions => no_access);
  -- docs-end: memory

  -- docs-start: slaves
  -- A read and a write slave on the memory, each with a handle of its own
  constant axi4_bus : axi4_bus_t := new_axi4_bus(data_length => 32, address_length => 32);
  constant read_slave : axi4_slave_t :=
    new_axi4_slave(memory, axi4_bus, min_response_latency => 20 ns, max_response_latency => 60 ns);
  constant write_slave : axi4_slave_t := new_axi4_slave(memory, axi4_bus, data_stall_probability => 0.3);
  -- docs-end: slaves

  constant master : bus_master_t := new_bus(data_length => 32, address_length => 32);
  constant monitor : axi4_monitor_t := new_axi4_monitor(
    new_axi4_bus(data_length => 32, address_length => 32, lite => true),
    protocol_checker => new_axi4_protocol_checker
  );

  signal aclk : std_ulogic := '0';
  signal awvalid : std_ulogic;
  signal awready : std_ulogic;
  signal awaddr : std_ulogic_vector(31 downto 0);
  signal wvalid : std_ulogic;
  signal wready : std_ulogic;
  signal wdata : std_ulogic_vector(31 downto 0);
  signal wstrb : std_ulogic_vector(3 downto 0);
  signal bvalid : std_ulogic;
  signal bready : std_ulogic;
  signal bresp : std_ulogic_vector(1 downto 0);
  signal arvalid : std_ulogic;
  signal arready : std_ulogic;
  signal araddr : std_ulogic_vector(31 downto 0);
  signal rvalid : std_ulogic;
  signal rready : std_ulogic;
  signal rdata : std_ulogic_vector(31 downto 0);
  signal rresp : std_ulogic_vector(1 downto 0);

begin

  aclk <= not aclk after 5 ns;

  -- docs-start: instances
  -- An AXI4-Lite master has no ARLEN or AWLEN: every burst is one beat. The
  -- ports left open take the AXI defaults: ID 0, full width, INCR.
  read_slave_inst : entity awesome_vunit_vcs.axi4_read_slave
    generic map (
      axi_slave => read_slave
    )
    port map (
      aclk => aclk,
      arvalid => arvalid,
      arready => arready,
      araddr => araddr,
      arlen => x"00",
      rvalid => rvalid,
      rready => rready,
      rdata => rdata,
      rresp => rresp
    );

  write_slave_inst : entity awesome_vunit_vcs.axi4_write_slave
    generic map (
      axi_slave => write_slave
    )
    port map (
      aclk => aclk,
      awvalid => awvalid,
      awready => awready,
      awaddr => awaddr,
      awlen => x"00",
      wvalid => wvalid,
      wready => wready,
      wdata => wdata,
      wstrb => wstrb,
      bvalid => bvalid,
      bready => bready,
      bresp => bresp
    );

  -- docs-end: instances

  master_inst : entity vunit_lib.axi_lite_master
    generic map (
      bus_handle => master
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

    variable buf : axi4_buffer_t;
    variable stat : axi_statistics_t;
    variable count : natural;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_read_a_preloaded_image") then
        -- docs-start: preload
        -- A buffer for the image, then the image itself: Intel HEX, S-record,
        -- raw binary or JSON, the formats of the flash family
        buf := allocate(memory, x"0000_1000", 64, name => "boot image", permissions => read_only);
        load_image(memory, tb_path & "boot_image.hex", base => 16#1000#);
        check_bus(net, master, x"00001000", x"100D0A07");
      -- docs-end: preload

      elsif run("test_write_expected_data") then
        -- docs-start: expected
        -- The design must write these bytes; the write slave checks each byte
        -- as it writes it, and the test checks that all were written
        buf := allocate(memory, 16, name => "result", permissions => write_only);
        set_expected_word(memory, base_address(buf), x"12345678");
        write_bus(net, master, std_ulogic_vector(to_unsigned(base_address(buf), 32)), x"12345678");
        -- The master is idle after the write response, the slave wrote the bytes before it
        wait_until_idle(net, master);
        check_expected_was_written(buf);
      -- docs-end: expected

      elsif run("test_a_wrong_write_is_a_check_failure") then
        -- docs-start: failure
        -- A byte written with another value than it expects is a check failure
        -- on the checker of the write slave
        buf := allocate(memory, 4, name => "result");
        set_expected_word(memory, base_address(buf), x"00000001");
        disable_stop(get_logger(write_slave), error);
        write_bus(net, master, std_ulogic_vector(to_unsigned(base_address(buf), 32)), x"00000002");
        wait_until_idle(net, master);
        check_equal(get_log_count(get_logger(write_slave), error), 1);
        reset_log_count(get_logger(write_slave), error);
      -- docs-end: failure

      elsif run("test_statistics_and_protocol") then
        buf := allocate(memory, 64, name => "scratch");
        for idx in 0 to 7 loop

          write_bus(net, master, std_ulogic_vector(to_unsigned(4 * idx, 32)), x"0000_0000");
        end loop;

        wait_until_idle(net, master);
        -- docs-start: statistics
        -- VUnit's axi_statistics_t: the bursts of each length
        get_statistics(net, write_slave, stat);
        check_equal(num_bursts(stat), 8);
        check_equal(max_burst_length(stat), 1);
        deallocate(stat);
        -- docs-end: statistics
        for check in axi4_metavalue to axi4_timeout loop

          get_check_count(net, protocol_checker(monitor), check, count);
          check_equal(count, 0, "violations of " & axi4_check_t'image(check));
        end loop;

      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 100 us);

end architecture;
