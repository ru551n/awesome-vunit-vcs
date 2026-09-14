-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- QSPI NOR flash verification component: QSPI master VCs wired pin to pin to
-- flash VCs, exercising the devices through bus traffic.
--
-- The flash procedures only set a device up and inspect it afterwards; every
-- claim about what a device does is made about bytes that crossed the wires.
--
-- Eight buses: flash_a is the device most tests use, flash_b a second
-- independent device, checked_flash and unchecked_flash sit behind masters
-- that deselect CS too briefly (with and without a protocol checker),
-- custom_flash has a non-default configuration, raw_flash is bit-banged by the
-- testbench, and default_flash_1 and default_flash_2 have no explicit id.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.integer_array_pkg.all;
use vunit_lib.sync_pkg.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_flash is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_flash is
  constant page_bytes : positive := 256;
  constant sector_bytes : positive := 4096;
  constant block_bytes : positive := 65536;

  -- docs-start: flash_constructors
  constant master_a : qspi_master_t := new_qspi_master(sck_period => 20 ns, id => get_id("tb_flash:master_a"));
  constant flash_a : flash_t := new_flash(
    page_bytes => page_bytes,
    sector_bytes => sector_bytes,
    block_bytes => block_bytes,
    jedec_id => 16#EF4018#,
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_flash:flash_a")
  );
  signal m2s_a : qspi_m2s_t := qspi_m2s_init;
  signal s2m_a : qspi_s2m_t := qspi_s2m_init;
  -- docs-end: flash_constructors

  -- A second device on its own bus. Its state would leak into flash_a if the
  -- backends shared anything.
  constant master_b : qspi_master_t := new_qspi_master(sck_period => 20 ns, id => get_id("tb_flash:master_b"));
  constant flash_b : flash_t := new_flash(
    jedec_id => 16#C22018#,
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_flash:flash_b")
  );
  signal m2s_b : qspi_m2s_t := qspi_m2s_init;
  signal s2m_b : qspi_s2m_t := qspi_s2m_init;

  -- Two masters that violate the 30 ns tSHSL of a protocol checker, one
  -- against a device with a protocol checker and one against a device
  -- without. Without the unchecked one, an inert checker and a clean bus
  -- would look the same.
  constant cs_deselect_too_short : delay_length := 5 ns;

  constant bad_master : qspi_master_t := new_qspi_master(
    sck_period => 20 ns,
    cs_deselect_time => cs_deselect_too_short
  );
  constant checked_flash : flash_t := new_flash(
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_flash:checked_flash")
  );
  signal checked_m2s : qspi_m2s_t := qspi_m2s_init;
  signal checked_s2m : qspi_s2m_t := qspi_s2m_init;

  constant unchecked_master : qspi_master_t := new_qspi_master(
    sck_period => 20 ns,
    cs_deselect_time => cs_deselect_too_short
  );
  constant unchecked_flash : flash_t := new_flash(id => get_id("tb_flash:unchecked_flash"));
  signal unchecked_m2s : qspi_m2s_t := qspi_m2s_init;
  signal unchecked_s2m : qspi_s2m_t := qspi_s2m_init;

  -- 32 MiB, powering up in 4-byte addressing, another JEDEC ID and a
  -- protocol checker with a tSHSL longer than the 50 ns CS deselect time of a
  -- default master
  constant custom_master : qspi_master_t := new_qspi_master;
  constant custom_flash : flash_t := new_flash(
    size_bytes => 32 * 1024 * 1024,
    addr_bytes => 4,
    jedec_id => 16#20BA19#,
    timing_enabled => false,
    protocol_checker => new_qspi_protocol_checker(t_shsl => 60 ns),
    id => get_id("tb_flash:custom_flash")
  );
  signal custom_m2s : qspi_m2s_t := qspi_m2s_init;
  signal custom_s2m : qspi_s2m_t := qspi_s2m_init;

  -- Driven by the testbench, no master
  constant raw_flash : flash_t := new_flash(
    protocol_checker => new_qspi_protocol_checker,
    id => get_id("tb_flash:raw_flash")
  );
  signal raw_m2s : qspi_m2s_t := qspi_m2s_init;
  signal raw_s2m : qspi_s2m_t := qspi_s2m_init;

  -- Two devices with default ids, logger and actor, each on its own bus. Their
  -- Python sessions share nothing only if the default ids differ.
  constant default_master_1 : qspi_master_t := new_qspi_master;
  constant default_flash_1 : flash_t := new_flash;
  signal default_m2s_1 : qspi_m2s_t := qspi_m2s_init;
  signal default_s2m_1 : qspi_s2m_t := qspi_s2m_init;

  constant default_master_2 : qspi_master_t := new_qspi_master;
  constant default_flash_2 : flash_t := new_flash;
  signal default_m2s_2 : qspi_m2s_t := qspi_m2s_init;
  signal default_s2m_2 : qspi_s2m_t := qspi_s2m_init;

  type flash_vec_t is array (natural range <>) of flash_t;
  constant flashes : flash_vec_t := (
    flash_a,
    flash_b,
    checked_flash,
    unchecked_flash,
    custom_flash,
    raw_flash,
    default_flash_1,
    default_flash_2
  );

  -- first, first + 1, ...: a misordered or shifted transfer shows up as a
  -- wrong value
  impure function ramp(length : positive; first : natural := 0) return integer_array_t is
    variable result : integer_array_t := new_1d(length => length, bit_width => 8, is_signed => false);
  begin
    for idx in 0 to length - 1 loop
      set(result, idx, (first + idx) mod 256);
    end loop;
    return result;
  end;

  impure function bytes_of(bytes : integer_vector) return integer_array_t is
    variable result : integer_array_t := new_1d(length => bytes'length, bit_width => 8, is_signed => false);
  begin
    for idx in 0 to bytes'length - 1 loop
      set(result, idx, bytes(bytes'low + idx));
    end loop;
    return result;
  end;

  procedure check_bytes(got : integer_array_t; expected : integer_array_t; msg : string) is
  begin
    check_equal(length(got), length(expected), msg & ": length");
    for idx in 0 to length(expected) - 1 loop
      check_equal(get(got, idx), get(expected, idx), msg & ": byte " & to_string(idx));
    end loop;
  end;

  -- Poll the status register of flash_a until write-in-progress clears, over
  -- the bus, as a controller does. This also proves the VC answers the bus
  -- while it is busy.
  procedure poll_until_ready(signal net : inout network_t; timeout : delay_length := 10 ms) is
    constant deadline : time := now + timeout;
    variable status : natural;
  begin
    loop
      qspi_flash_read_status(net, master_a, status);
      -- Bit 0 is WIP
      exit when status mod 2 = 0;
      check(now < deadline, "poll_until_ready: timed out with WIP still set");
    end loop;
  end;
begin
  -- docs-start: flash_instances
  qspi_master_a_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => master_a
    )
    port map (
      m2s => m2s_a,
      s2m => s2m_a
    );

  flash_a_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => flash_a
    )
    port map (
      m2s => m2s_a,
      s2m => s2m_a
    );
  -- docs-end: flash_instances

  qspi_master_b_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => master_b
    )
    port map (
      m2s => m2s_b,
      s2m => s2m_b
    );

  flash_b_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => flash_b
    )
    port map (
      m2s => m2s_b,
      s2m => s2m_b
    );

  bad_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => bad_master
    )
    port map (
      m2s => checked_m2s,
      s2m => checked_s2m
    );

  checked_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => checked_flash
    )
    port map (
      m2s => checked_m2s,
      s2m => checked_s2m
    );

  unchecked_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => unchecked_master
    )
    port map (
      m2s => unchecked_m2s,
      s2m => unchecked_s2m
    );

  unchecked_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => unchecked_flash
    )
    port map (
      m2s => unchecked_m2s,
      s2m => unchecked_s2m
    );

  custom_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => custom_master
    )
    port map (
      m2s => custom_m2s,
      s2m => custom_s2m
    );

  custom_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => custom_flash
    )
    port map (
      m2s => custom_m2s,
      s2m => custom_s2m
    );

  raw_flash_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => raw_flash
    )
    port map (
      m2s => raw_m2s,
      s2m => raw_s2m
    );

  default_master_1_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => default_master_1
    )
    port map (
      m2s => default_m2s_1,
      s2m => default_s2m_1
    );

  default_flash_1_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => default_flash_1
    )
    port map (
      m2s => default_m2s_1,
      s2m => default_s2m_1
    );

  default_master_2_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => default_master_2
    )
    port map (
      m2s => default_m2s_2,
      s2m => default_s2m_2
    );

  default_flash_2_inst : entity awesome_vunit_vcs.flash
    generic map (
      flash => default_flash_2
    )
    port map (
      m2s => default_m2s_2,
      s2m => default_s2m_2
    );

  main : process
    variable got : integer_array_t;
    variable expected : integer_array_t;
    variable status : natural;
    variable regions : integer_array_t;
    variable address : integer_array_t;
    variable count : integer;
    variable start : time;

    -- One x1 byte of zeros bit-banged on the raw bus, in SPI mode 0 with
    -- 10 ns setup and hold, and io(0) = 'X' in beat metavalue_beat
    procedure send_raw_byte(metavalue_beat : natural) is
    begin
      raw_m2s.cs_n <= '0';
      for beat in 0 to 7 loop
        raw_m2s.io.enable <= "0001";
        if beat = metavalue_beat then
          raw_m2s.io.value <= "000X";
        else
          raw_m2s.io.value <= "0000";
        end if;
        wait for 10 ns;
        raw_m2s.sck <= '1';
        wait for 10 ns;
        raw_m2s.sck <= '0';
      end loop;
      raw_m2s.io.enable <= "0000";
      wait for 10 ns;
      raw_m2s.cs_n <= '1';
      wait for 50 ns;
    end;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      for idx in flashes'range loop
        flash_reset(net, flashes(idx));
      end loop;
      -- Most tests do not care how long an erase takes; the ones that do turn
      -- timing back on
      flash_set_timing_enable(net, flash_a, false);
      flash_set_timing_enable(net, flash_b, false);

      if run("test_read_jedec_id") then
        qspi_flash_read_id(net, master_a, got, 3);
        check_equal(get(got, 0), 16#EF#, "manufacturer id");
        check_equal(get(got, 1), 16#40#, "memory type");
        check_equal(get(got, 2), 16#18#, "capacity");
        deallocate(got);

      elsif run("test_erased_device_reads_all_ones") then
        -- Nothing was preloaded, so sparse storage must read erased
        qspi_flash_read(net, master_a, 16#123456#, 8, got);
        expected := bytes_of((16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#FF#));
        check_bytes(got, expected, "erased device");
        deallocate(got);
        deallocate(expected);

      elsif run("test_basic_read_returns_preloaded_data") then
        expected := ramp(16, 16#A0#);
        flash_preload(net, flash_a, 16#001000#, expected);
        qspi_flash_read(net, master_a, 16#001000#, 16, got);
        check_bytes(got, expected, "0x03 read");
        deallocate(got);
        deallocate(expected);

      elsif run("test_fast_read_matches_basic_read") then
        -- 0x0B differs from 0x03 only by its dummy cycles
        expected := ramp(32, 16#10#);
        flash_preload(net, flash_a, 16#002000#, expected);
        qspi_flash_fast_read(net, master_a, 16#002000#, 32, got);
        check_bytes(got, expected, "0x0B fast read");
        deallocate(got);
        deallocate(expected);

      elsif run("test_quad_output_read") then
        -- 0x6B changes the lane width at the dummy boundary: address at x1,
        -- dummy cycles, data at x4
        expected := ramp(64, 16#30#);
        flash_preload(net, flash_a, 16#003000#, expected);
        qspi_flash_quad_output_read(net, master_a, 16#003000#, 64, got);
        check_bytes(got, expected, "0x6B quad output read");
        deallocate(got);
        deallocate(expected);

      elsif run("test_quad_io_read") then
        -- 0xEB: opcode at x1, address and mode byte at x4, dummy cycles, data
        -- at x4
        expected := ramp(64, 16#50#);
        flash_preload(net, flash_a, 16#004000#, expected);
        qspi_flash_quad_io_read(net, master_a, 16#004000#, 64, got);
        check_bytes(got, expected, "0xEB quad I/O read");
        deallocate(got);
        deallocate(expected);

      elsif run("test_page_program_then_read_back") then
        expected := ramp(page_bytes, 16#00#);
        qspi_flash_write_enable(net, master_a);
        qspi_flash_page_program(net, master_a, 16#005000#, expected);
        poll_until_ready(net);
        qspi_flash_read(net, master_a, 16#005000#, page_bytes, got);
        check_bytes(got, expected, "page program");
        deallocate(got);
        deallocate(expected);

      elsif run("test_page_program_without_write_enable_is_ignored") then
        expected := ramp(8, 16#11#);
        -- No WREN: a real part latches nothing and the array stays erased
        qspi_flash_page_program(net, master_a, 16#006000#, expected);
        poll_until_ready(net);
        flash_check_content_fill(net, flash_a, 16#006000#, 8, 16#FF#);
        flash_get_stat(net, flash_a, "ignored_command_count", count);
        check(count > 0, "the ignored program should have been counted");
        deallocate(expected);

      elsif run("test_page_program_wraps_within_the_page") then
        -- 8 bytes starting 4 before the end of a page put the last 4 at the
        -- start of the same page, never in the next one
        expected := ramp(8, 16#80#);
        qspi_flash_write_enable(net, master_a);
        qspi_flash_page_program(net, master_a, 16#007000# + page_bytes - 4, expected);
        poll_until_ready(net);

        qspi_flash_read(net, master_a, 16#007000# + page_bytes - 4, 4, got);
        check_bytes(got, bytes_of((16#80#, 16#81#, 16#82#, 16#83#)), "tail of the page");
        deallocate(got);

        qspi_flash_read(net, master_a, 16#007000#, 4, got);
        check_bytes(got, bytes_of((16#84#, 16#85#, 16#86#, 16#87#)), "wrapped to page start");
        deallocate(got);

        flash_check_content_fill(net, flash_a, 16#007000# + page_bytes, 4, 16#FF#);
        deallocate(expected);

      elsif run("test_programming_is_and_only") then
        -- NOR cells only go from 1 to 0 outside an erase: 0xFF & 0xA5 & 0x0F = 0x05
        qspi_flash_write_enable(net, master_a);
        qspi_flash_page_program(net, master_a, 16#008000#, bytes_of((0 => 16#A5#)));
        poll_until_ready(net);
        qspi_flash_write_enable(net, master_a);
        qspi_flash_page_program(net, master_a, 16#008000#, bytes_of((0 => 16#0F#)));
        poll_until_ready(net);
        flash_check_content(net, flash_a, 16#008000#, bytes_of((0 => 16#05#)));

      elsif run("test_sector_erase") then
        -- docs-start: flash_sector_erase
        flash_preload_fill(net, flash_a, 16#009000#, sector_bytes, 16#00#);
        -- The byte just past the sector must survive
        flash_preload(net, flash_a, 16#009000# + sector_bytes, bytes_of((0 => 16#5A#)));
        qspi_flash_write_enable(net, master_a);
        qspi_flash_sector_erase(net, master_a, 16#009000#);
        poll_until_ready(net);
        flash_check_content_fill(net, flash_a, 16#009000#, sector_bytes, 16#FF#);
        flash_check_content(net, flash_a, 16#009000# + sector_bytes, bytes_of((0 => 16#5A#)));
        -- docs-end: flash_sector_erase

      elsif run("test_block_erase") then
        flash_preload_fill(net, flash_a, 16#010000#, block_bytes, 16#00#);
        flash_preload(net, flash_a, 16#010000# + block_bytes, bytes_of((0 => 16#5A#)));
        qspi_flash_write_enable(net, master_a);
        qspi_flash_block_erase(net, master_a, 16#010000#);
        poll_until_ready(net);
        flash_check_content_fill(net, flash_a, 16#010000#, block_bytes, 16#FF#);
        flash_check_content(net, flash_a, 16#010000# + block_bytes, bytes_of((0 => 16#5A#)));

      elsif run("test_chip_erase") then
        flash_preload_fill(net, flash_a, 0, 4 * sector_bytes, 16#00#);
        flash_preload_fill(net, flash_a, 16#800000#, sector_bytes, 16#00#);
        qspi_flash_write_enable(net, master_a);
        qspi_flash_chip_erase(net, master_a);
        poll_until_ready(net);
        flash_check_content_fill(net, flash_a, 0, 4 * sector_bytes, 16#FF#);
        flash_check_content_fill(net, flash_a, 16#800000#, sector_bytes, 16#FF#);

      elsif run("test_write_enable_latch_is_visible_and_self_clearing") then
        qspi_flash_read_status(net, master_a, status);
        check_equal((status / 2) mod 2, 0, "WEL starts clear");

        qspi_flash_write_enable(net, master_a);
        qspi_flash_read_status(net, master_a, status);
        check_equal((status / 2) mod 2, 1, "WREN sets WEL");

        qspi_flash_page_program(net, master_a, 16#00A000#, bytes_of((0 => 16#77#)));
        poll_until_ready(net);
        qspi_flash_read_status(net, master_a, status);
        check_equal((status / 2) mod 2, 0, "a program clears WEL");

      elsif run("test_protected_region_rejects_program") then
        flash_set_protection(net, flash_a, 16#00B000#, sector_bytes, locked => true);
        qspi_flash_write_enable(net, master_a);
        qspi_flash_page_program(net, master_a, 16#00B000#, bytes_of((0 => 16#12#)));
        poll_until_ready(net);
        -- Ignored as by a real part: no error, no change
        flash_check_content_fill(net, flash_a, 16#00B000#, 1, 16#FF#);

      elsif run("test_sparse_preload_leaves_the_gap_erased") then
        flash_preload(net, flash_a, 16#000000#, bytes_of((16#11#, 16#22#)));
        flash_preload(net, flash_a, 16#400000#, bytes_of((16#33#, 16#44#)));
        qspi_flash_read(net, master_a, 16#000000#, 2, got);
        check_bytes(got, bytes_of((16#11#, 16#22#)), "first region");
        deallocate(got);
        qspi_flash_read(net, master_a, 16#400000#, 2, got);
        check_bytes(got, bytes_of((16#33#, 16#44#)), "second region");
        deallocate(got);
        -- The 4 MiB between them was never allocated
        qspi_flash_read(net, master_a, 16#200000#, 4, got);
        check_bytes(got, bytes_of((16#FF#, 16#FF#, 16#FF#, 16#FF#)), "the gap");
        deallocate(got);

      elsif run("test_preload_fill_of_one_mebibyte") then
        -- O(1) in its length: materializing a mebibyte would show in the run time
        flash_preload_fill(net, flash_a, 16#100000#, 1024 * 1024, 16#C3#);
        qspi_flash_read(net, master_a, 16#180000#, 4, got);
        check_bytes(got, bytes_of((16#C3#, 16#C3#, 16#C3#, 16#C3#)), "middle of the fill");
        deallocate(got);
        flash_check_content_fill(net, flash_a, 16#200000#, 4, 16#FF#);

      elsif run("test_written_regions_reports_only_what_was_programmed") then
        qspi_flash_write_enable(net, master_a);
        qspi_flash_page_program(net, master_a, 16#00C000#, ramp(4, 1));
        poll_until_ready(net);
        flash_get_written_regions(net, flash_a, regions);
        check_equal(length(regions), 2, "exactly one [addr, len] pair");
        check_equal(get(regions, 0), 16#00C000#, "region address");
        check_equal(get(regions, 1), 4, "region length");
        deallocate(regions);

      elsif run("test_four_byte_addressing_reaches_the_same_data") then
        -- The last 8 bytes of the 16 MiB device, reached with a 4-byte and a
        -- 3-byte address
        expected := ramp(8, 16#C0#);
        flash_preload(net, flash_a, 16#00FFFFF8#, expected);
        qspi_flash_enter_4byte(net, master_a);
        qspi_flash_read(net, master_a, 16#00FFFFF8#, 8, got, addr_bytes => 4);
        check_bytes(got, expected, "4-byte addressed read");
        deallocate(got);
        qspi_flash_exit_4byte(net, master_a);
        qspi_flash_read(net, master_a, 16#FFFFF8#, 8, got, addr_bytes => 3);
        check_bytes(got, expected, "3-byte addressed read");
        deallocate(got);
        deallocate(expected);

      elsif run("test_qpi_mode_opcode_is_transferred_at_x4") then
        -- In QPI mode the opcode itself is x4, which the VC cannot know in
        -- advance: this is why cs_assert returns a directive
        expected := ramp(8, 16#E0#);
        flash_preload(net, flash_a, 16#00D000#, expected);
        qspi_flash_enter_qpi(net, master_a);
        qspi_flash_read(net, master_a, 16#00D000#, 8, got, opcode_lanes => 4, lanes => 4);
        check_bytes(got, expected, "read in QPI mode");
        deallocate(got);
        qspi_flash_exit_qpi(net, master_a);
        deallocate(expected);

      elsif run("test_erase_takes_its_busy_time") then
        flash_set_timing_enable(net, flash_a, true);
        flash_set_timing(net, flash_a, "tSE", 100 us);
        qspi_flash_write_enable(net, master_a);
        start := now;
        qspi_flash_sector_erase(net, master_a, 16#00E000#);
        poll_until_ready(net);
        check(
          now - start >= 100 us,
          "the erase reported ready after " & to_string(now - start) &
          ", less than the 100 us it was configured to take"
        );

      elsif run("test_timing_disabled_makes_erase_instant") then
        flash_set_timing_enable(net, flash_a, false);
        qspi_flash_write_enable(net, master_a);
        start := now;
        qspi_flash_sector_erase(net, master_a, 16#00F000#);
        poll_until_ready(net);
        -- Only the bus traffic takes time
        check(now - start < 50 us, "with timing disabled the erase still took " & to_string(now - start));

      elsif run("test_continuous_read_needs_no_opcode") then
        -- docs-start: qspi_master_continuous_read
        -- A 0xEB whose mode byte has M5:M4 = 10 arms continuous read: the next
        -- transaction has no opcode and starts with the x4 address
        expected := ramp(8, 16#70#);
        flash_preload(net, flash_a, 16#013000#, expected);

        qspi_flash_quad_io_read(net, master_a, 16#013000#, 8, got, mode_byte => 16#A0#);
        check_bytes(got, expected, "the 0xEB that arms continuous read");
        deallocate(got);

        -- No opcode: address and mode byte at x4, dummy cycles, data at x4.
        -- The mode byte is the only way out of the mode.
        address := qspi_flash_address_bytes(16#013000#, 3);
        append(address, 16#A0#);
        qspi_transfer(
          net,
          master_a,
          cmd => null_integer_array,
          data => got,
          addr => address,
          addr_lanes => 4,
          dummy_cycles => qspi_flash_quad_io_read_dummy,
          num_read_bytes => 8,
          read_lanes => 4
        );
        check_bytes(got, expected, "the opcode-less continuous read");
        deallocate(got);
        deallocate(address);

        -- A mode byte whose M5:M4 is not 10 leaves continuous read
        address := qspi_flash_address_bytes(16#013000#, 3);
        append(address, 16#00#);
        qspi_transfer(
          net,
          master_a,
          cmd => null_integer_array,
          data => got,
          addr => address,
          addr_lanes => 4,
          dummy_cycles => qspi_flash_quad_io_read_dummy,
          num_read_bytes => 8,
          read_lanes => 4
        );
        check_bytes(got, expected, "the transaction that disarms continuous read");
        deallocate(got);
        deallocate(address);

        qspi_flash_read(net, master_a, 16#013000#, 8, got);
        check_bytes(got, expected, "an ordinary read after leaving continuous mode");
        deallocate(got);
        deallocate(expected);
        -- docs-end: qspi_master_continuous_read

      elsif run("test_partial_byte_aborts_a_page_program") then
        -- A real part abandons a page program whose clock count is not a
        -- multiple of 8. Three clocks after the data byte prove the trailing
        -- bits reach the model.
        disable_stop(get_logger(flash_a), error);
        qspi_flash_write_enable(net, master_a);
        qspi_transfer(
          net,
          master_a,
          cmd => bytes_of((0 => 16#02#)),
          data => got,
          addr => qspi_flash_address_bytes(16#014000#, 3),
          wr_data => bytes_of((0 => 16#5A#)),
          dummy_cycles => 3,
          num_read_bytes => 0
        );
        poll_until_ready(net);
        -- The master releases the IOs for its three dummy cycles while the
        -- device expects the next program byte, so it samples 'Z' on io(0) at
        -- each of the three rising edges: 3 errors
        check_equal(get_log_count(get_logger(flash_a), error), 3, "metavalues sampled in the trailing clocks");
        reset_log_count(get_logger(flash_a), error);
        -- Aborted, so the array is untouched
        flash_check_content_fill(net, flash_a, 16#014000#, 1, 16#FF#);
        flash_get_stat(net, flash_a, "abort_count", count);
        check(count > 0, "the truncated program should have been counted as an abort");

      elsif run("test_two_instances_are_independent") then
        flash_preload(net, flash_a, 16#015000#, bytes_of((16#11#, 16#22#)));
        flash_preload(net, flash_b, 16#015000#, bytes_of((16#33#, 16#44#)));

        qspi_flash_read(net, master_a, 16#015000#, 2, got);
        check_bytes(got, bytes_of((16#11#, 16#22#)), "device A");
        deallocate(got);

        qspi_flash_read(net, master_b, 16#015000#, 2, got);
        check_bytes(got, bytes_of((16#33#, 16#44#)), "device B");
        deallocate(got);

        qspi_flash_read_id(net, master_a, got, 3);
        check_equal(get(got, 0), 16#EF#, "device A manufacturer");
        deallocate(got);
        qspi_flash_read_id(net, master_b, got, 3);
        check_equal(get(got, 0), 16#C2#, "device B manufacturer");
        deallocate(got);

        -- Erasing A leaves B alone
        qspi_flash_write_enable(net, master_a);
        qspi_flash_sector_erase(net, master_a, 16#015000#);
        poll_until_ready(net);
        flash_check_content_fill(net, flash_a, 16#015000#, 2, 16#FF#);
        flash_check_content(net, flash_b, 16#015000#, bytes_of((16#33#, 16#44#)));

      elsif run("test_protocol_violation_is_reported") then
        -- bad_master deselects CS for 20 ns, not the 5 ns configured: the
        -- master keeps CS high for at least one SCK period. The violation is in
        -- the gap between two commands, and two commands have one gap: 1 error,
        -- on the logger of the protocol checker of the flash.
        -- docs-start: flash_protocol_violation
        disable_stop(get_logger(protocol_checker(checked_flash)), error);
        qspi_flash_read_id(net, bad_master, got, 3);
        deallocate(got);
        qspi_flash_read_id(net, bad_master, got, 3);
        deallocate(got);
        check_equal(get_log_count(get_logger(protocol_checker(checked_flash)), error), 1, "tSHSL violations");
        get_check_count(net, protocol_checker(checked_flash), qspi_cs_deselect, count);
        check_equal(count, 1, "qspi_cs_deselect count");
        reset_log_count(get_logger(protocol_checker(checked_flash)), error);
        -- docs-end: flash_protocol_violation

      elsif run("test_protocol_checks_can_be_switched_off") then
        -- The same traffic against a device created without a protocol checker
        -- logs nothing, which makes a clean log mean something elsewhere
        disable_stop(get_logger(unchecked_flash), error);
        qspi_flash_read_id(net, unchecked_master, got, 3);
        deallocate(got);
        qspi_flash_read_id(net, unchecked_master, got, 3);
        deallocate(got);
        check_equal(get_log_count(get_logger(unchecked_flash), error), 0, "errors with protocol checks off");

      elsif run("test_commands_are_ignored_while_busy") then
        flash_set_timing_enable(net, flash_a, true);
        flash_set_timing(net, flash_a, "tSE", 200 us);
        flash_preload(net, flash_a, 16#011000#, bytes_of((0 => 16#AA#)));

        qspi_flash_write_enable(net, master_a);
        qspi_flash_sector_erase(net, master_a, 16#012000#);

        -- Issued while the erase runs: a real part drops it, and the VC must
        -- still answer the bus
        qspi_flash_write_enable(net, master_a);
        qspi_flash_page_program(net, master_a, 16#011000#, bytes_of((0 => 16#00#)));

        poll_until_ready(net);
        flash_check_content(net, flash_a, 16#011000#, bytes_of((0 => 16#AA#)));

      elsif run("test_content_mismatch_is_a_check_failure") then
        disable_stop(get_logger(flash_a), error);
        flash_check_content(net, flash_a, 16#000100#, bytes_of((0 => 16#00#)));
        -- The check is a message: wait until the VC has handled it
        wait_until_idle(net, as_sync(flash_a));
        check_equal(get_log_count(get_logger(flash_a), error), 1, "content mismatches on erased flash");
        reset_log_count(get_logger(flash_a), error);

      elsif run("test_non_default_configuration") then
        disable_stop(get_logger(protocol_checker(custom_flash)), error);

        qspi_flash_read_id(net, custom_master, got, 3);
        check_equal(get(got, 0), 16#20#, "manufacturer id");
        check_equal(get(got, 1), 16#BA#, "memory type");
        check_equal(get(got, 2), 16#19#, "capacity");
        deallocate(got);

        -- Above 16 MiB, read with a 4-byte address and no 0xB7 first: the
        -- device powers up in 4-byte addressing
        expected := ramp(8, 16#40#);
        flash_preload(net, custom_flash, 16#1800000#, expected);
        qspi_flash_read(net, custom_master, 16#1800000#, 8, got, addr_bytes => 4);
        check_bytes(got, expected, "4-byte read above 16 MiB");
        deallocate(got);
        deallocate(expected);

        -- The two commands above are back to back with the 50 ns CS deselect
        -- time of the master, short of the 60 ns tSHSL: one violation
        check_equal(get_log_count(get_logger(protocol_checker(custom_flash)), error), 1, "tSHSL violations");
        reset_log_count(get_logger(protocol_checker(custom_flash)), error);

      elsif run("test_metavalue_on_io_is_reported") then
        -- docs-start: flash_metavalue
        disable_stop(get_logger(raw_flash), error);
        send_raw_byte(metavalue_beat => 3);
        check_equal(get_log_count(get_logger(raw_flash), error), 1, "metavalues on the IOs");
        reset_log_count(get_logger(raw_flash), error);
        -- docs-end: flash_metavalue

      elsif run("test_default_id_instances_are_independent") then
        check(get_id(default_flash_1) /= get_id(default_flash_2), "the default ids differ");
        flash_preload(net, default_flash_1, 16#016000#, bytes_of((16#5A#, 16#A5#)));
        flash_preload(net, default_flash_2, 16#016000#, bytes_of((16#C3#, 16#3C#)));

        qspi_flash_read(net, default_master_1, 16#016000#, 2, got);
        check_bytes(got, bytes_of((16#5A#, 16#A5#)), "default device 1");
        deallocate(got);

        qspi_flash_read(net, default_master_2, 16#016000#, 2, got);
        check_bytes(got, bytes_of((16#C3#, 16#3C#)), "default device 2");
        deallocate(got);

      elsif run("test_wait_for_time_and_until_idle") then
        start := now;
        -- A message to the VC, so it returns at once
        wait_for_time(net, as_sync(flash_a), 1 ms);
        check_equal(now, start, "wait_for_time returned at once");
        wait_until_idle(net, as_sync(flash_a));
        check_equal(now - start, 1 ms, "time the VC was busy waiting");
      end if;

      -- Content checks are messages: every VC handles them before the test ends
      for idx in flashes'range loop
        wait_until_idle(net, as_sync(flashes(idx)));
      end loop;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 50 ms);
end architecture;
