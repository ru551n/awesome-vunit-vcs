-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The I2C family in Fast-mode: an EEPROM with acknowledge polling, SMBus PEC,
-- NACK injection, arbitration between two masters, the general call, a
-- device model from Python and transfers written as operations.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_i2c is

  constant master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode, id => get_id("tb_i2c:master"));
  constant other_master : i2c_master_t := new_i2c_master(speed => i2c_fast_mode, id => get_id("tb_i2c:other_master"));
  constant registers : i2c_target_t := new_i2c_target(address => 16#50#, id => get_id("tb_i2c:registers"));
  -- A 24C04: 512 bytes in two blocks at 0x54 and 0x55, 16-byte pages
  constant eeprom : i2c_target_t := new_i2c_target(
    address => 16#54#,
    model => "eeprom",
    model_args => kwarg("size_bytes", 512) & kwarg("page_bytes", 16) & kwarg_time("t_wr_fs", 100 us),
    id => get_id("tb_i2c:eeprom")
  );
  constant smbus : i2c_target_t := new_i2c_target(address => 16#60#, pec => true, id => get_id("tb_i2c:smbus"));
  constant broadcast : i2c_target_t :=
    new_i2c_target(address => 16#20#, general_call => true, id => get_id("tb_i2c:broadcast"));
  constant doubler : i2c_target_t := new_i2c_target(
    address => 16#30#,
    model => "i2c_models:Doubler",
    model_args => kwarg("offset", 3),
    id => get_id("tb_i2c:doubler")
  );
  constant monitor : i2c_monitor_t := new_i2c_monitor(
    protocol_checker => new_i2c_protocol_checker(speed => i2c_fast_mode),
    id => get_id("tb_i2c:monitor")
  );

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

  other_master_inst : entity awesome_vunit_vcs.i2c_master
    generic map (
      master => other_master
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

  eeprom_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => eeprom
    )
    port map (
      scl => scl,
      sda => sda
    );

  smbus_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => smbus
    )
    port map (
      scl => scl,
      sda => sda
    );

  broadcast_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => broadcast
    )
    port map (
      scl => scl,
      sda => sda
    );

  doubler_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => doubler
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

    variable data : std_ulogic_vector(15 downto 0);
    variable status : i2c_status_t;
    variable other_status : i2c_status_t;
    variable reference : i2c_master_reference_t;
    variable other_reference : i2c_master_reference_t;
    variable result : i2c_result_t;
    variable other_result : i2c_result_t;
    variable transfer : i2c_transfer_t;
    variable polls : natural;
    variable start : time;
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

      if run("test_eeprom_page_write_and_acknowledge_polling") then
        -- Four bytes from 0x0E: the address wraps to the start of the 16-byte page
        i2c_write(net, master, 16#54#, x"0E01020304");
        wait_until_idle(net, as_sync(master));
        start := now;
        polls := 0;
        loop

          i2c_write(net, master, 16#54#, "", status);
          exit when status = i2c_ok;
          check(status = i2c_address_nack, "a busy EEPROM does not acknowledge its address");
          polls := polls + 1;
        end loop;

        check(polls > 0, "the EEPROM was busy after the write");
        check(now - start >= 100 us, "the write cycle lasts t_wr");
        i2c_target_check_memory(net, eeprom, 16#0E#, x"0102");
        i2c_target_check_memory(net, eeprom, 16#00#, x"0304");
        i2c_target_check_memory(net, eeprom, 16#10#, x"FF", "nothing written beyond the page");
        -- A random read: a write of the address, then a read after a repeated START
        i2c_write_read(net, master, 16#54#, x"0F", data);
        check_equal(data, std_ulogic_vector'(x"02FF"), "a sequential read crosses the page boundary");
        -- The second block answers at 0x55
        i2c_write(net, master, 16#55#, x"0077");
        wait_until_idle(net, as_sync(master));
        i2c_target_check_memory(net, eeprom, 16#100#, x"77");
        check_no_violations;

      elsif run("test_pec") then
        i2c_write(net, master, 16#60#, x"05AB", pec => true);
        wait_until_idle(net, as_sync(master));
        i2c_target_check_memory(net, smbus, 5, x"AB", "a write with the right PEC");
        i2c_write_read(net, master, 16#60#, x"05", data(7 downto 0), status, pec => true);
        check(status = i2c_ok, "the PEC of the read is right");
        check_equal(data(7 downto 0), std_ulogic_vector'(x"AB"), "read with PEC");
        -- The PEC of C0 05 11 is 0xBB
        disable_stop(get_logger(get_checker(smbus)), error);
        i2c_transfer(net, master, "S 0xC0 0x05 0x11 0x00 P", result);
        wait_until_idle(net, as_sync(smbus));
        check_equal(get_log_count(get_logger(get_checker(smbus)), error), 1, "a wrong PEC is a check failure");
        reset_log_count(get_logger(get_checker(smbus)), error);
        i2c_target_check_memory(net, smbus, 5, x"AB", "the write with the wrong PEC is dropped");
        i2c_transfer(net, master, "S 0xC0 0x05 0x11 0xBB P", result);
        i2c_target_check_memory(net, smbus, 5, x"11", "the write with the right PEC");
        deallocate(result.data);
        deallocate(result.acks);
        check_no_violations;

      elsif run("test_nack_injection") then
        inject_i2c_target_nack(net, registers, 2);
        i2c_write(net, master, 16#50#, x"004142", status);
        check(status = i2c_data_nack, "status " & i2c_status_t'image(status));
        i2c_transfer(net, master, "S 0xA0 0x00 0x41 0x42 P", result);
        check(result.status = i2c_ok, "the injected NACK is used once");
        check_equal(length(result.acks), 4, "acknowledge bits");
        check_equal(get(result.acks, 3), 1, "the last byte is acknowledged");
        deallocate(result.data);
        deallocate(result.acks);
        inject_i2c_target_nack(net, registers, 0);
        i2c_write(net, master, 16#50#, x"00", status);
        check(status = i2c_address_nack, "an injected address NACK");
        check_no_violations;

      elsif run("test_arbitration") then
        -- Both masters start together, after the same wait; 0xA0 wins over 0xC0 at the second bit
        wait_for_time(net, as_sync(master), 1 us);
        wait_for_time(net, as_sync(other_master), 1 us);
        i2c_transfer(net, master, "S 0xA0 0x00 0x42 P", reference);
        i2c_transfer(net, other_master, "S 0xC0 0x05 0x99 P", other_reference);
        await_i2c_transfer_reply(net, reference, result);
        await_i2c_transfer_reply(net, other_reference, other_result);
        check(result.status = i2c_ok, "the winner");
        check(other_result.status = i2c_arbitration_lost, "the loser " & i2c_status_t'image(other_result.status));
        i2c_target_check_memory(net, registers, 0, x"42");
        i2c_target_check_memory(net, smbus, 5, x"00", "the loser wrote nothing");
        pop_i2c_transfer(net, monitor, transfer);
        check_equal(transfer.address, 16#50#, "the monitor sees the winner only");
        check_equal(length(transfer.data), 2, "bytes of the winner");
        deallocate(transfer.data);
        -- The loser can use the bus afterwards
        i2c_write(net, other_master, 16#50#, x"0199", other_status);
        check(other_status = i2c_ok, "the loser after the arbitration");
        deallocate(result.data);
        deallocate(result.acks);
        deallocate(other_result.data);
        deallocate(other_result.acks);
        check_no_violations;

      elsif run("test_general_call") then
        i2c_write(net, master, 0, x"0612");
        wait_until_idle(net, as_sync(master));
        i2c_target_check_memory(net, broadcast, 6, x"12", "the general call reaches the target that answers it");
        i2c_target_check_memory(net, registers, 6, x"00", "a target without general call ignores it");
        check_no_violations;

      elsif run("test_python_device_model") then
        i2c_read(net, master, 16#30#, data(7 downto 0));
        check_equal(data(7 downto 0), std_ulogic_vector'(x"06"), "twice the offset");
        i2c_write(net, master, 16#30#, x"21");
        i2c_read(net, master, 16#30#, data(7 downto 0));
        check_equal(data(7 downto 0), std_ulogic_vector'(x"42"), "twice the byte written");

      elsif run("test_transfers_without_stop") then
        -- A write left without a STOP; the next START is a repeated START on the bus
        i2c_write(net, master, 16#50#, x"0711", stop => false);
        i2c_write(net, master, 16#50#, x"0822");
        wait_until_idle(net, as_sync(master));
        i2c_target_check_memory(net, registers, 7, x"1122");
        pop_i2c_transfer(net, monitor, transfer);
        check_false(transfer.stopped, "the first transfer has no STOP");
        deallocate(transfer.data);
        pop_i2c_transfer(net, monitor, transfer);
        check(transfer.repeated_start and transfer.stopped, "the second starts with a repeated START");
        deallocate(transfer.data);
        check_no_violations;

      elsif run("test_read_nack_at_a_chosen_byte") then
        i2c_target_preload(net, registers, 0, x"C1C2C3");
        i2c_transfer(net, master, "S 0xA0 0x00 S 0xA1 R RN P", result);
        check_equal(length(result.data), 2, "bytes read");
        check_equal(get(result.data, 0), 16#C1#, "first byte");
        check_equal(get(result.data, 1), 16#C2#, "second byte");
        deallocate(result.data);
        deallocate(result.acks);
        pop_i2c_transfer(net, monitor, transfer);
        deallocate(transfer.data);
        pop_i2c_transfer(net, monitor, transfer);
        check_equal(transfer.nack_index, 1, "the monitor sees the NACK of the second byte");
        deallocate(transfer.data);
        check_no_violations;
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 50 ms);
end architecture;
