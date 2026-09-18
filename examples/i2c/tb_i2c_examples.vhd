-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The I2C examples of the documentation. A master talks to three targets on
-- one bus: a temperature sensor modelled in Python (python/sensor.py), a
-- 24C02 EEPROM and an SMBus device with PEC. A monitor with a protocol
-- checker watches the bus. In a real test your design takes the place of the
-- master or of a target.

-- docs-start: context
library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

-- docs-end: context

entity tb_i2c_examples is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_i2c_examples is

  -- docs-start: handles
  constant master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode);
  constant sensor : i2c_target_t :=
    new_i2c_target(address => 16#48#, model => "sensor:TemperatureSensor", model_args => kwarg("celsius", 25.0));
  constant eeprom : i2c_target_t := new_i2c_target(
    address => 16#50#,
    model => "eeprom",
    model_args => kwarg("size_bytes", 256) & kwarg("page_bytes", 8) & kwarg_time("t_wr_fs", 200 us)
  );
  constant monitor : i2c_monitor_t :=
    new_i2c_monitor(protocol_checker => new_i2c_protocol_checker(speed => i2c_fast_mode));
  -- docs-end: handles

  -- docs-start: smbus-handle
  constant smbus_device : i2c_target_t := new_i2c_target(address => 16#60#, pec => true);
  -- docs-end: smbus-handle

  -- docs-start: fast-master
  -- A master that keeps SCL high for 400 ns only, short of the 600 ns of Fast-mode
  constant fast_master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode, t_low => 2100 ns, t_high => 400 ns);
  -- docs-end: fast-master

  -- docs-start: bus
  signal scl : std_logic := 'H';
  signal sda : std_logic := 'H';

-- docs-end: bus

begin

  -- docs-start: instances
  -- The pull-up resistors of the bus
  scl <= 'H';
  sda <= 'H';

  master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => master
    )
    port map (
      scl => scl,
      sda => sda
    );

  sensor_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => sensor
    )
    port map (
      scl => scl,
      sda => sda
    );

  eeprom_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => eeprom
    )
    port map (
      scl => scl,
      sda => sda
    );

  monitor_inst : entity awesome_vunit_vcs.i2c_monitor
    generic map (
      monitor => monitor
    )
    port map (
      scl => scl,
      sda => sda
    );

  -- docs-end: instances

  smbus_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => smbus_device
    )
    port map (
      scl => scl,
      sda => sda
    );

  fast_master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => fast_master
    )
    port map (
      scl => scl,
      sda => sda
    );

  main : process

    variable temperature : std_ulogic_vector(15 downto 0);
    variable data : std_ulogic_vector(15 downto 0);
    variable status : i2c_status_t;
    variable polls : natural;
    variable transfer : i2c_transfer_t;
    variable statistics : i2c_statistics_t;
    variable result : i2c_result_t;
    variable count : natural;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_read_a_register") then
        -- docs-start: read-register
        -- Select register 0, then read two bytes after a repeated START
        i2c_write_read(net, master, 16#48#, x"00", temperature);
        check_equal(temperature, std_ulogic_vector'(x"1900"), "25.0 degrees Celsius");
      -- docs-end: read-register

      elsif run("test_eeprom_write_and_acknowledge_polling") then
        -- docs-start: eeprom
        -- Write 4 bytes from address 0x10; the EEPROM starts its write cycle at the STOP
        i2c_write(net, master, 16#50#, x"10CAFEF00D");
        -- Poll with the address alone until the EEPROM acknowledges it again
        polls := 0;
        loop

          i2c_write(net, master, 16#50#, "", status);
          exit when status = i2c_ok;
          polls := polls + 1;
        end loop;

        info("The EEPROM was busy for " & to_string(polls) & " polls");
        -- Read back over the bus, and compare the memory of the model directly
        i2c_write_read(net, master, 16#50#, x"10", data);
        check_equal(data, std_ulogic_vector'(x"CAFE"));
        i2c_target_check_memory(net, eeprom, 16#10#, x"CAFEF00D");
      -- docs-end: eeprom

      elsif run("test_monitor") then
        -- docs-start: monitor
        -- The transfers the monitor must see next, in order
        check_i2c_transfer(net, monitor, 16#48#, false, x"01", "select the configuration register");
        check_i2c_transfer(net, monitor, 16#48#, true, x"00", "read it");
        i2c_write_read(net, master, 16#48#, x"01", data(7 downto 0));

        -- Or take the transfers one by one
        i2c_write(net, master, 16#50#, x"2001");
        pop_i2c_transfer(net, monitor, transfer);
        pop_i2c_transfer(net, monitor, transfer);
        pop_i2c_transfer(net, monitor, transfer);
        check_equal(transfer.address, 16#50#);
        check_equal(length(transfer.data), 2);
        check(transfer.stopped and transfer.nack_index = -1);
        deallocate(transfer.data);

        get_i2c_statistics(net, monitor, statistics);
        info(
          "SCL at "
          & to_string(statistics.scl_frequency_hz)
          & " Hz, "
          & to_string(statistics.data_bytes)
          & " data bytes in "
          & to_string(statistics.transactions)
          & " transactions"
        );
      -- docs-end: monitor

      elsif run("test_python_device_model") then
        -- docs-start: python-model
        -- Start a conversion; the sensor does not acknowledge its address for 100 us
        i2c_write(net, master, 16#48#, x"0101");
        i2c_write_read(net, master, 16#48#, x"00", temperature, status);
        check(status = i2c_address_nack, "busy converting");
        wait for 100 us;
        i2c_write_read(net, master, 16#48#, x"00", temperature, status);
        check(status = i2c_ok, "conversion done");
      -- docs-end: python-model

      elsif run("test_pec") then
        -- docs-start: pec
        -- The master appends the PEC to the write and checks the PEC of the read
        i2c_write(net, master, 16#60#, x"0742", pec => true);
        i2c_write_read(net, master, 16#60#, x"07", data(7 downto 0), pec => true);
        check_equal(data(7 downto 0), std_ulogic_vector'(x"42"));
      -- docs-end: pec

      elsif run("test_clock_stretching_and_nack_injection") then
        -- docs-start: stretch-nack
        -- The sensor holds SCL low for 20 us before every acknowledge bit
        set_i2c_target_stretch(net, sensor, 20 us);
        i2c_write_read(net, master, 16#48#, x"00", temperature);
        -- It does not acknowledge byte 1 of the next transfer, the register
        inject_i2c_target_nack(net, sensor, 1);
        i2c_write(net, master, 16#48#, x"00", status);
        check(status = i2c_data_nack);
      -- docs-end: stretch-nack

      elsif run("test_a_timing_violation") then
        -- docs-start: negative
        -- The violations are check failures on the checker of the protocol checker
        disable_stop(get_logger(get_checker(protocol_checker(monitor))), error);
        i2c_write(net, fast_master, 16#50#, x"00");
        wait_until_idle(net, as_sync(fast_master));
        wait_until_idle(net, as_sync(monitor));

        get_check_count(net, protocol_checker(monitor), i2c_t_high, count);
        check(count > 0, "SCL high too short");
        check_equal(
          get_log_count(get_logger(get_checker(protocol_checker(monitor))), error),
          count,
          "one check failure per violation"
        );
        reset_log_count(get_logger(get_checker(protocol_checker(monitor))), error);
      -- docs-end: negative

      elsif run("test_malformed_traffic") then
        -- docs-start: operations
        disable_stop(get_logger(get_checker(protocol_checker(monitor))), error);
        -- An address, a register and 4 bits of a data byte, then a STOP
        i2c_transfer(net, master, "S 0xA0 0x00 B1010 P", result);
        check(result.status = i2c_ok);
        check_equal(length(result.acks), 2, "two bytes were acknowledged");
        deallocate(result.data);
        deallocate(result.acks);
        wait_until_idle(net, as_sync(monitor));
        get_check_count(net, protocol_checker(monitor), i2c_sda_stable, count);
        check_equal(count, 1, "a STOP inside a byte");
        reset_log_count(get_logger(get_checker(protocol_checker(monitor))), error);
      -- docs-end: operations
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
