-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The flash examples of the cookbook. Three buses, each with a QSPI master in
-- front of a flash: the design under test boots from boot_flash, the
-- testbench's own master talks to data_flash, and hasty_master keeps CS high
-- too briefly for the protocol checker of checked_flash.

-- docs-start: context
library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;
-- docs-end: context

entity tb_flash_examples is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_flash_examples is
  -- docs-start: boot-handles
  -- The flash the design boots from, with a protocol checker for the design's pin timing
  constant boot_flash : flash_t := new_flash(protocol_checker => new_qspi_protocol_checker);
  constant image_bytes : positive := 64;
  signal m2s : qspi_m2s_t := qspi_m2s_init;
  signal s2m : qspi_s2m_t := qspi_s2m_init;
  signal rst_n, boot_done : std_ulogic := '0';
  signal ram : std_ulogic_vector(0 to 8 * 256 - 1);
  -- docs-end: boot-handles

  -- docs-start: master-handles
  -- The testbench's own QSPI master, on a bus with a second flash
  constant master : qspi_master_t := new_qspi_master;
  constant data_flash : flash_t := new_flash;
  signal master_m2s : qspi_m2s_t := qspi_m2s_init;
  signal master_s2m : qspi_s2m_t := qspi_s2m_init;
  -- docs-end: master-handles

  -- docs-start: timing-handles
  -- A master that keeps CS high for one 20 ns clock period between commands, and
  -- a flash whose protocol checker requires 30 ns (t_shsl)
  constant hasty_master : qspi_master_t := new_qspi_master(sck_period => 20 ns, cs_deselect_time => 5 ns);
  constant checked_flash : flash_t := new_flash(protocol_checker => new_qspi_protocol_checker(t_shsl => 30 ns));
  signal hasty_m2s : qspi_m2s_t := qspi_m2s_init;
  signal hasty_s2m : qspi_s2m_t := qspi_s2m_init;
  -- docs-end: timing-handles

  -- docs-start: keep-wel-handles
  -- A part that keeps write enable when it refuses a program to a locked region
  constant keep_wel_flash : flash_t := new_flash(clear_wel_on_protection_reject => false);
  constant keep_wel_master : qspi_master_t := new_qspi_master;
  signal keep_wel_m2s : qspi_m2s_t := qspi_m2s_init;
  signal keep_wel_s2m : qspi_s2m_t := qspi_s2m_init;
  -- docs-end: keep-wel-handles
begin
  main : process
    -- docs-start: variables
    variable regions, got : integer_array_t := null_integer_array;
    variable cmd, addr, wr_data : integer_array_t := null_integer_array;
    variable count : natural;
    variable reference : qspi_transfer_reference_t;
    -- docs-end: variables
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_boot_from_an_image") then
        -- docs-start: boot-test
        flash_load_image(net, boot_flash, tb_path(runner_cfg) & "flash_boot_image.hex");
        rst_n <= '1';
        wait until boot_done = '1';
        -- What the design copied into its RAM is the image
        flash_check_content(net, boot_flash, 0, ram(0 to 8 * image_bytes - 1));
        -- docs-end: boot-test
        -- docs-start: boot-writes-nothing
        -- A boot reads; it programs and erases nothing
        flash_get_written_regions(net, boot_flash, regions);
        check_equal(length(regions), 0, "written regions");
        deallocate(regions);
        -- docs-end: boot-writes-nothing

      elsif run("test_check_what_was_written") then
        -- docs-start: program
        -- The testbench's master programs four octets, as a design would
        qspi_flash_write_enable(net, master);
        qspi_flash_page_program(net, master, 16#001000#, x"DEADBEEF");
        flash_wait_until_ready(net, data_flash);
        -- docs-end: program
        -- docs-start: written-regions
        flash_get_written_regions(net, data_flash, regions);
        check_equal(length(regions), 2, "one [address, length] pair");
        check_equal(get(regions, 0), 16#001000#, "address");
        check_equal(get(regions, 1), 4, "length");
        deallocate(regions);
        flash_check_content(net, data_flash, 16#001000#, x"DEADBEEF");
        wait_until_idle(net, as_sync(data_flash));
        -- docs-end: written-regions

      elsif run("test_count_a_content_mismatch") then
        -- docs-start: content-mismatch
        -- Erased flash reads 0xFF, so expecting 0x00 is one mismatch
        disable_stop(get_logger(data_flash), error);
        flash_check_content(net, data_flash, 16#000100#, x"00");
        wait_until_idle(net, as_sync(data_flash));
        check_equal(get_log_count(get_logger(data_flash), error), 1);
        reset_log_count(get_logger(data_flash), error);
        -- docs-end: content-mismatch

      elsif run("test_check_the_pin_timing") then
        -- docs-start: timing-violation
        -- The gap between two commands is too short: one violation
        disable_stop(get_logger(protocol_checker(checked_flash)), error);
        qspi_flash_read_id(net, hasty_master, got);
        deallocate(got);
        qspi_flash_read_id(net, hasty_master, got);
        deallocate(got);
        get_check_count(net, checked_flash, qspi_cs_deselect, count);
        check_equal(count, 1);
        reset_log_count(get_logger(protocol_checker(checked_flash)), error);
        -- docs-end: timing-violation
        -- docs-start: protocol-checker-reset
        reset(net, protocol_checker(checked_flash));  -- clears its counts
        get_check_count(net, checked_flash, qspi_cs_deselect, count);
        check_equal(count, 0);
        -- docs-end: protocol-checker-reset

      elsif run("test_switch_a_timing_rule_off") then
        -- docs-start: switch-rule
        -- Switched off, the rule neither reports nor counts the short gap
        set_check_enabled(net, checked_flash, qspi_cs_deselect, false);
        qspi_flash_read_id(net, hasty_master, got);
        deallocate(got);
        qspi_flash_read_id(net, hasty_master, got);
        deallocate(got);
        get_check_count(net, checked_flash, qspi_cs_deselect, count);
        check_equal(count, 0);
        set_check_enabled(net, checked_flash, qspi_cs_deselect);  -- and on again
        -- docs-end: switch-rule

      elsif run("test_write_protection") then
        -- docs-start: write-protection
        -- Lock the first 4 KiB: a program there is refused, as by a real part
        flash_set_protection(net, data_flash, 16#000000#, 16#001000#);
        qspi_flash_write_enable(net, master);
        qspi_flash_page_program(net, master, 16#000010#, x"00");
        flash_wait_until_ready(net, data_flash);
        flash_get_stat(net, data_flash, "protect_reject_count", count);
        check_equal(count, 1, "refused programs");
        flash_get_stat(net, data_flash, "wel", count);
        check_equal(count, 0, "the refusal cleared write enable");
        -- The content is still erased
        flash_check_content(net, data_flash, 16#000010#, x"FF");
        wait_until_idle(net, as_sync(data_flash));
        -- docs-end: write-protection
        -- docs-start: keep-wel-test
        flash_set_protection(net, keep_wel_flash, 16#000000#, 16#001000#);
        qspi_flash_write_enable(net, keep_wel_master);
        qspi_flash_page_program(net, keep_wel_master, 16#000010#, x"00");
        flash_wait_until_ready(net, keep_wel_flash);
        flash_get_stat(net, keep_wel_flash, "wel", count);
        check_equal(count, 1, "this part keeps write enable");
        -- docs-end: keep-wel-test

      elsif run("test_count_a_failed_request") then
        -- docs-start: failed-request
        -- A request the flash cannot carry out is a failure on its logger
        disable_stop(get_logger(data_flash), failure);
        flash_get_stat(net, data_flash, "no_such_statistic", count);
        check_equal(get_log_count(get_logger(data_flash), failure), 1);
        reset_log_count(get_logger(data_flash), failure);
        -- docs-end: failed-request

      elsif run("test_reset_between_scenarios") then
        -- docs-start: reset
        qspi_flash_write_enable(net, master);
        qspi_flash_page_program(net, master, 16#002000#, x"5A");
        flash_wait_until_ready(net, data_flash);
        -- Back to the power-on state; the content and the statistics stay
        reset(net, master);
        reset(net, data_flash);
        flash_get_stat(net, data_flash, "program_count", count);
        check_equal(count, 1);
        -- Also clear the statistics, such as the written regions
        reset(net, data_flash, clear_statistics => true);
        flash_get_stat(net, data_flash, "program_count", count);
        check_equal(count, 0);
        -- A reset is not an erase
        flash_check_content(net, data_flash, 16#002000#, x"5A");
        wait_until_idle(net, as_sync(data_flash));
        -- docs-end: reset

      elsif run("test_read_the_id_with_a_transfer") then
        -- docs-start: read-transfer
        -- A read built by hand: the 0x9F command, then three bytes read back
        cmd := new_byte_array((0 => qspi_flash_op_read_id));
        qspi_transfer(net, master, cmd, got, num_read_bytes => 3);
        deallocate(cmd);
        -- The command layer reads the same ID
        qspi_flash_read_id(net, master, wr_data);
        check_equal(length(got), 3);
        for idx in 0 to 2 loop
          check_equal(get(got, idx), get(wr_data, idx), "ID byte " & to_string(idx));
        end loop;
        deallocate(got);
        deallocate(wr_data);
        -- docs-end: read-transfer

      elsif run("test_send_your_own_commands") then
        -- docs-start: commands
        qspi_flash_write_enable(net, master);
        qspi_flash_page_program(net, master, 16#003000#, x"0102");
        flash_wait_until_ready(net, data_flash);
        qspi_flash_read(net, master, 16#003000#, 2, got);
        check_equal(get(got, 0), 16#01#);
        check_equal(get(got, 1), 16#02#);
        deallocate(got);
        -- docs-end: commands

        -- docs-start: transfer
        -- A page program built by hand: command, address and data are byte arrays
        cmd := new_byte_array((0 => qspi_flash_op_page_program));
        addr := qspi_flash_address_bytes(16#004000#, 3);
        wr_data := new_byte_array((16#A5#, 16#5A#));
        qspi_flash_write_enable(net, master);
        qspi_transfer(net, master, cmd, reference, addr => addr, wr_data => wr_data);
        -- qspi_transfer has copied the arrays and returned; the test may do other work here
        deallocate(cmd);
        deallocate(addr);
        deallocate(wr_data);
        await_qspi_transfer_reply(net, reference);
        flash_wait_until_ready(net, data_flash);
        flash_check_content(net, data_flash, 16#004000#, x"A55A");
        wait_until_idle(net, as_sync(data_flash));
        -- docs-end: transfer
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 1 sec);

  -- docs-start: boot-instances
  boot_flash_inst : entity awesome_vunit_vcs.flash
    generic map (flash => boot_flash)
    port map (m2s => m2s, s2m => s2m);

  -- The design under test
  boot_reader_inst : entity work.boot_reader
    port map (rst_n => rst_n, m2s => m2s, s2m => s2m, ram => ram, boot_done => boot_done);
  -- docs-end: boot-instances

  -- docs-start: master-instances
  master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (qspi_master => master)
    port map (m2s => master_m2s, s2m => master_s2m);

  data_flash_inst : entity awesome_vunit_vcs.flash
    generic map (flash => data_flash)
    port map (m2s => master_m2s, s2m => master_s2m);
  -- docs-end: master-instances

  hasty_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (qspi_master => hasty_master)
    port map (m2s => hasty_m2s, s2m => hasty_s2m);

  checked_flash_inst : entity awesome_vunit_vcs.flash
    generic map (flash => checked_flash)
    port map (m2s => hasty_m2s, s2m => hasty_s2m);

  -- docs-start: keep-wel-instances
  keep_wel_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (qspi_master => keep_wel_master)
    port map (m2s => keep_wel_m2s, s2m => keep_wel_s2m);

  keep_wel_flash_inst : entity awesome_vunit_vcs.flash
    generic map (flash => keep_wel_flash)
    port map (m2s => keep_wel_m2s, s2m => keep_wel_s2m);
  -- docs-end: keep-wel-instances
end architecture;
