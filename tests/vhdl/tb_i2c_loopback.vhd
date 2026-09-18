-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- An I2C master and two targets on one bus, observed by a monitor with a
-- protocol checker, in the speed mode of the configuration. Every test ends
-- with no protocol violation.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c_loopback is
  generic (
    runner_cfg : string;
    -- i2c_speed_t'pos of the speed mode
    speed_mode : natural := 0);
end entity;

architecture tb of tb_i2c_loopback is

  constant speed_value : i2c_speed_t := i2c_speed_t'val(speed_mode);
  constant master : i2c_master_t := new_i2c_master(speed => speed_value);
  constant registers : i2c_target_t := new_i2c_target(address => 16#50#, model_args => kwarg("size_bytes", 64));
  constant ten_bit_registers : i2c_target_t := new_i2c_target(address => 16#2A5#, ten_bit => true);
  constant monitor : i2c_monitor_t :=
    new_i2c_monitor(protocol_checker => new_i2c_protocol_checker(speed => speed_value));

  signal scl : std_logic := 'H';
  signal sda : std_logic := 'H';

begin

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

  registers_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => registers
    )
    port map (
      scl => scl,
      sda => sda
    );

  ten_bit_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => ten_bit_registers
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

  main : process

    variable data : std_ulogic_vector(23 downto 0);
    variable status : i2c_status_t;
    variable reference : i2c_master_reference_t;
    variable transfer : i2c_transfer_t;
    variable statistics : i2c_statistics_t;
    variable count : natural;

    procedure check_no_violations is
    begin

      wait_until_idle(net, as_sync(monitor));
      for item in i2c_check_t'low to i2c_metavalue loop

        get_check_count(net, protocol_checker(monitor), item, count);
        check_equal(count, 0, "violations of " & i2c_check_t'image(item));
      end loop;

    end;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_write_and_read_back") then
        i2c_write(net, master, 16#50#, x"10A1B2C3");
        i2c_write_read(net, master, 16#50#, x"10", data);
        check_equal(data, std_ulogic_vector'(x"A1B2C3"), "read back");
        i2c_target_check_memory(net, registers, 16#10#, x"A1B2C3");
        i2c_read(net, master, 16#50#, data(23 downto 16));
        check_equal(data(23 downto 16), std_ulogic_vector'(x"00"), "the register after the last one read");
        check_no_violations;

      elsif run("test_monitor_sees_the_transfers") then
        check_i2c_transfer(net, monitor, 16#50#, false, x"2055");
        check_i2c_transfer(net, monitor, 16#50#, false, x"20");
        check_i2c_transfer(net, monitor, 16#50#, true, x"55");
        i2c_write(net, master, 16#50#, x"2055");
        i2c_write_read(net, master, 16#50#, x"20", data(7 downto 0));
        pop_i2c_transfer(net, monitor, transfer);
        check_equal(transfer.address, 16#50#, "address");
        check_false(transfer.is_read or transfer.repeated_start, "a write after a START");
        check(transfer.stopped and transfer.address_ack, "stopped and acknowledged");
        check_equal(length(transfer.data), 2, "bytes");
        check_equal(get(transfer.data, 1), 16#55#, "data");
        deallocate(transfer.data);
        pop_i2c_transfer(net, monitor, transfer);
        check_false(transfer.stopped, "the write ends with a repeated START");
        deallocate(transfer.data);
        pop_i2c_transfer(net, monitor, transfer);
        check(transfer.is_read and transfer.repeated_start, "a read after a repeated START");
        check_equal(transfer.nack_index, 0, "the master does not acknowledge the last byte");
        deallocate(transfer.data);
        check_no_violations;

      elsif run("test_non_blocking_read") then
        i2c_target_preload(net, registers, 0, x"0102");
        i2c_write(net, master, 16#50#, x"00");
        i2c_read(net, master, 16#50#, 2, reference);
        await_i2c_read_reply(net, reference, data(15 downto 0), status);
        check(status = i2c_ok, "status");
        check_equal(data(15 downto 0), std_ulogic_vector'(x"0102"), "data");
        i2c_write_read(net, master, 16#50#, x"01", 1, reference);
        await_i2c_read_reply(net, reference, data(7 downto 0), status);
        check_equal(data(7 downto 0), std_ulogic_vector'(x"02"), "write-read data");

      elsif run("test_ten_bit_addressing") then
        i2c_write(net, master, 16#2A5#, x"0377", ten_bit => true);
        i2c_write_read(net, master, 16#2A5#, x"03", data(7 downto 0), ten_bit => true);
        check_equal(data(7 downto 0), std_ulogic_vector'(x"77"), "10-bit write-read");
        i2c_write(net, master, 16#2A5#, x"03", ten_bit => true);
        i2c_read(net, master, 16#2A5#, data(7 downto 0), ten_bit => true);
        check_equal(data(7 downto 0), std_ulogic_vector'(x"77"), "10-bit read");
        i2c_target_check_memory(net, registers, 3, x"00", "the 7-bit target at 0x50 saw nothing");
        pop_i2c_transfer(net, monitor, transfer);
        check(transfer.ten_bit and transfer.address = 16#2A5#, "the monitor decodes the 10-bit address");
        deallocate(transfer.data);
        check_no_violations;

      elsif run("test_clock_stretching") then
        set_i2c_target_stretch(net, registers, 30 us);
        i2c_write(net, master, 16#50#, x"08CAFE");
        i2c_write_read(net, master, 16#50#, x"08", data(15 downto 0));
        check_equal(data(15 downto 0), std_ulogic_vector'(x"CAFE"), "read back while stretching");
        get_i2c_statistics(net, monitor, statistics);
        -- Stretched before every acknowledge bit of the target: 3 + 2 bytes
        check(statistics.stretch_time >= 5 * 29 us, "stretch time " & to_string(statistics.stretch_time));
        check_no_violations;

      elsif run("test_address_not_acknowledged") then
        i2c_write(net, master, 16#51#, x"00", status);
        check(status = i2c_address_nack, "status " & i2c_status_t'image(status));
        i2c_read(net, master, 16#51#, data(7 downto 0), status);
        check(status = i2c_address_nack, "read status " & i2c_status_t'image(status));
        get_i2c_statistics(net, monitor, statistics);
        check_equal(statistics.address_nacks, 2, "address NACKs");
        check_no_violations;

      elsif run("test_statistics") then
        i2c_write(net, master, 16#50#, x"000102");
        i2c_write_read(net, master, 16#50#, x"00", data);
        get_i2c_statistics(net, monitor, statistics);
        check_equal(statistics.transactions, 2, "transactions");
        check_equal(statistics.transfers, 3, "transfers");
        check_equal(statistics.writes, 2, "writes");
        check_equal(statistics.reads, 1, "reads");
        check_equal(statistics.repeated_starts, 1, "repeated STARTs");
        check_equal(statistics.data_bytes, 7, "data bytes");
        check_equal(statistics.nacks, 1, "the last byte read");

        case speed_value is
          when i2c_standard_mode =>

            check_equal(statistics.scl_frequency_hz, 100_000, "SCL frequency");
          when i2c_fast_mode =>

            check_equal(statistics.scl_frequency_hz, 400_000, "SCL frequency");
          when i2c_fast_mode_plus =>

            check_equal(statistics.scl_frequency_hz, 1_000_000, "SCL frequency");
        end case;

        check(statistics.utilization_ppm > 0 and statistics.utilization_ppm < 1_000_000, "utilization");
        check_no_violations;
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 50 ms);
end architecture;
