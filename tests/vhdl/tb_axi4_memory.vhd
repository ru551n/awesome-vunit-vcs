-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The memory of the AXI4 slaves: the scenarios of VUnit's tb_memory on
-- axi4_memory_t, and what it adds (sparse 64-bit addresses, ranges of
-- permissions, bulk transfers, integer arrays and images). The failures
-- VUnit's memory logs as failures are check failures on the checker of the
-- memory here.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.axi4_context;

entity tb_axi4_memory is
  generic (
    runner_cfg : string;
    tb_path : string);
end entity;

architecture tb of tb_axi4_memory is

begin

  main : process

    variable memory : axi4_memory_t;
    variable buf : axi4_buffer_t;
    variable byte : natural;
    variable data : integer_array_t;
    variable logger : logger_t;

    procedure test_write_integer (word : integer; expected : integer_vector) is
    begin

      write_integer(memory, 0, word, bytes_per_word => expected'length);
      for idx in expected'range loop

        check_equal(read_byte(memory, idx), expected(idx));
      end loop;

    end;

    -- A memory with an id of its own, since every memory has a Python session
    impure function new_memory (
      name : string;
      default_permissions : permissions_t := no_access;
      endian : endianness_t := little_endian;
      size_bytes : natural := 0
    ) return axi4_memory_t is
    begin

      return new_axi4_memory(
        size_bytes => size_bytes,
        default_permissions => default_permissions,
        endian => endian,
        id => get_id("tb_axi4_memory:" & name)
      );
    end;

  begin

    test_runner_setup(runner, runner_cfg);

    if run("test_new_memory") then
      memory := new_memory("memory");
      check_equal(num_bytes(memory), 0);
      check_true(get_logger(memory) = get_logger(get_id(memory)));

    elsif run("test_clear_memory") then
      memory := new_memory("memory");
      for i in 0 to 2 loop

        buf := allocate(memory, 1024);
        check_equal(base_address(buf), 0, "base address");
        check_equal(last_address(buf), 1023, "last address");
        clear(memory);
      end loop;

    elsif run("test_allocate") then
      memory := new_memory("memory");
      for i in 0 to 2 loop

        buf := allocate(memory, 1024);
        check_equal(base_address(buf), 1024 * i, "base address");
        check_equal(last_address(buf), 1024 * (i + 1) - 1, "last address");
        check_equal(num_bytes(buf), 1024);
        check_equal(num_bytes(memory), (i + 1) * 1024);
      end loop;

    elsif run("test_allocate_a_lot") then
      memory := new_memory("memory");
      for i in 0 to 500 - 1 loop

        buf := allocate(memory, 500);
        check_equal(base_address(buf), 500 * i, "base address");
      end loop;

    elsif run("test_allocate_with_alignment") then
      memory := new_memory("memory");
      buf := allocate(memory, 1);
      buf := allocate(memory, 1, alignment => 8);
      check_equal(base_address(buf), 8, "aligned base address");
      check_true(get_permissions(memory, 1) = no_access, "No access at unallocated location");
      check_true(get_permissions(memory, 7) = no_access, "No access at unallocated location");
      buf := allocate(memory, 1, alignment => 16);
      check_equal(base_address(buf), 16, "aligned base address");

    elsif run("test_allocate_at_a_64_bit_address") then
      memory := new_memory("memory");
      buf := allocate(memory, x"0123_4567_89AB_0000", 16, name => "far", permissions => read_only);
      check_equal(std_ulogic_vector(wide_base_address(buf)), std_ulogic_vector'(x"0123_4567_89AB_0000"));
      check_equal(name(buf), "far");
      check_equal(num_bytes(memory), 0, "a buffer at an address does not move the next one");
      check_equal(
        describe_address(memory, x"0123_4567_89AB_0002"),
        "address 81985529216434178 at offset 2 within buffer 'far' at range (81985529216434176 to 81985529216434191)"
      );

    elsif run("test_read_and_write_byte") then
      memory := new_memory("memory");
      buf := allocate(memory, 2);
      write_byte(memory, 0, 255);
      write_byte(memory, 1, 128);
      check_equal(read_byte(memory, 0), 255);
      check_equal(read_byte(memory, 1), 128);

    elsif run("test_huge_sparse_addresses") then
      -- A 64-bit address space costs nothing until it is touched
      memory := new_memory("memory", default_permissions => read_and_write);
      write_word(memory, x"FFFF_FFFF_FFFF_FFFC", x"DEADBEEF");
      check_equal(read_word(memory, x"FFFF_FFFF_FFFF_FFFC", 4), std_ulogic_vector'(x"DEADBEEF"));
      check_equal(read_byte(memory, x"FFFF_FFFF_FFFF_FFFF"), 16#DE#);
      fill(memory, x"8000_0000_0000_0000", 2 ** 30, 16#A5#);
      check_equal(read_byte(memory, x"8000_0000_3FFF_FFFF"), 16#A5#);
      check_equal(read_byte(memory, x"8000_0000_4000_0000"), 0);

    elsif run("test_access_memory_out_of_range") then
      memory := new_memory("memory", size_bytes => 1);
      logger := get_logger(memory);
      buf := allocate(memory, 1);
      mock(logger);
      write_byte(memory, 1, 255);
      check_only_log(logger, "Writing to address 1 out of range 0 to 0", error);
      byte := read_byte(memory, 1);
      check_only_log(logger, "Reading from address 1 out of range 0 to 0", error);
      unmock(logger);

    elsif run("test_default_permissions") then
      memory := new_memory("memory");
      buf := allocate(memory, 1);
      check_true(get_permissions(memory, 0) = read_and_write);
      check_true(get_permissions(memory, 1) = no_access);
      memory := new_memory("ram", default_permissions => read_and_write);
      check_true(get_permissions(memory, 12345) = read_and_write);

    elsif run("test_set_permissions") then
      memory := new_memory("memory");
      buf := allocate(memory, 1);
      for permissions in permissions_t loop

        set_permissions(memory, 0, permissions);
        check_true(get_permissions(memory, 0) = permissions);
      end loop;

      -- A range of any size is one operation
      set_permissions(memory, x"1_0000_0000", 2 ** 30, read_only);
      set_permissions(memory, 100, 10, write_only);
      check_true(get_permissions(memory, 109) = write_only);
      check_true(get_permissions(memory, 110) = no_access);

    elsif run("test_backdoor_ignores_permissions") then
      memory := new_memory("memory");
      buf := allocate(memory, 10, permissions => no_access);
      write_byte(memory, 5, 255);
      check_equal(read_byte(memory, 5), 255);

    elsif run("test_describe_address") then
      memory := new_memory("memory");
      buf := allocate(memory, 2);
      buf := allocate(memory, 10, name => "buffer_name");
      check_equal(name(buf), "buffer_name");
      check_equal(describe_address(memory, 12), "address 12 at unallocated location");
      check_equal(describe_address(memory, 1), "address 1 at offset 1 within anonymous buffer at range (0 to 1)");
      check_equal(describe_address(memory, 2), "address 2 at offset 0 within buffer 'buffer_name' at range (2 to 11)");
      check_equal(describe_address(memory, 5), "address 5 at offset 3 within buffer 'buffer_name' at range (2 to 11)");

    elsif run("test_set_expected_byte") then
      memory := new_memory("memory");
      logger := get_logger(memory);
      buf := allocate(memory, 2);
      set_expected_byte(memory, 0, 77);
      check_true(has_expected_byte(memory, 0), "address 0 has expected byte");
      check_false(has_expected_byte(memory, 1), "address 1 has no expected byte");
      mock(logger);
      write_byte(memory, 0, 255);
      check_only_log(logger, "Writing to " & describe_address(memory, 0) & ". Got 255 expected 77", error);
      unmock(logger);

    elsif run("test_set_expected_word") then
      memory := new_memory("memory");
      logger := get_logger(memory);
      buf := allocate(memory, 2);
      set_expected_word(memory, 0, x"3322");
      mock(logger);
      write_byte(memory, 0, 16#33#);
      check_only_log(logger, "Writing to " & describe_address(memory, 0) & ". Got 51 expected 34", error);
      write_byte(memory, 1, 16#22#);
      check_only_log(logger, "Writing to " & describe_address(memory, 1) & ". Got 34 expected 51", error);
      unmock(logger);

    elsif run("test_set_expected_integer") then
      memory := new_memory("memory");
      buf := allocate(memory, 2);
      set_expected_integer(memory, 0, 16#3322#, bytes_per_word => 2);
      check_equal(get_expected_byte(memory, 0), 16#22#);
      check_equal(get_expected_byte(memory, 1), 16#33#);
      set_expected_integer(memory, 0, 16#3322#, bytes_per_word => 2, endian => big_endian);
      check_equal(get_expected_byte(memory, 0), 16#33#);
      check_equal(get_expected_byte(memory, 1), 16#22#);

    elsif run("test_clear_expected_byte") then
      memory := new_memory("memory");
      buf := allocate(memory, 2);
      set_expected_byte(memory, 0, 77);
      check_true(has_expected_byte(memory, 0), "address 0 has expected byte");
      clear_expected_byte(memory, 0);
      check_false(has_expected_byte(memory, 0), "address 0 cleared expected byte");

    elsif run("test_that_expected_data_was_written") then
      memory := new_memory("memory");
      logger := get_logger(memory);
      buf := allocate(memory, 3);
      set_expected_byte(memory, 0, 77);
      set_expected_byte(memory, 2, 66);
      mock(logger);
      check_false(expected_was_written(buf));
      check_expected_was_written(buf);
      check_log(logger, "The " & describe_address(memory, 0) & " was never written with expected byte 77", error);
      check_only_log(logger, "The " & describe_address(memory, 2) & " was never written with expected byte 66", error);
      write_byte(memory, 0, 77);
      check_false(expected_was_written(buf));
      check_expected_was_written(buf);
      check_only_log(logger, "The " & describe_address(memory, 2) & " was never written with expected byte 66", error);
      write_byte(memory, 2, 66);
      check_true(expected_was_written(buf));
      check_true(expected_was_written(memory));
      check_true(expected_was_written(memory, 0, 3));
      check_expected_was_written(buf);
      check_expected_was_written(memory);
      unmock(logger);

    elsif run("test_write_integer") then
      memory := new_memory("memory");
      buf := allocate(memory, 4);
      test_write_integer(1, (0 => 1));
      test_write_integer(-1, (0 => 255));
      test_write_integer(1, (1, 0, 0, 0));
      test_write_integer(-1, (255, 255, 255, 255));
      test_write_integer(256, (0, 1, 0, 0));
      test_write_integer(-256, (0, 255, 255, 255));
      test_write_integer(integer'high, (255, 255, 255, 127));
      test_write_integer(integer'low, (0, 0, 0, 128));

    elsif run("test_write_word") then
      memory := new_memory("memory");
      buf := allocate(memory, 7);
      write_word(memory, 0, x"11223344556677");
      for idx in 0 to 6 loop

        check_equal(read_byte(memory, idx), 16#77# - 16#11# * idx);
      end loop;

    elsif run("test_read_word") then
      memory := new_memory("memory");
      buf := allocate(memory, 7 + 5);
      write_word(memory, 0, x"11223344556677");
      check_equal(read_word(memory, 0, 7), std_ulogic_vector'(x"11223344556677"));
      check_equal(read_word(memory, 0, 1), std_ulogic_vector'(x"77"));
      check_equal(read_word(memory, 1, 1), std_ulogic_vector'(x"66"));
      write_word(memory, 7, x"aaffbbccdd", endian => big_endian);
      check_equal(read_word(memory, 7, 5, endian => big_endian), std_ulogic_vector'(x"aaffbbccdd"));
      -- The default byte order of the memory
      memory := new_memory("big_endian", endian => big_endian);
      buf := allocate(memory, 7 + 5);
      write_word(memory, 7, x"aaffbbccdd");
      check_equal(read_word(memory, 7, 5), std_ulogic_vector'(x"aaffbbccdd"));
      check_equal(read_word(memory, 7, 1), std_ulogic_vector'(x"aa"));
      check_equal(read_word(memory, 8, 1), std_ulogic_vector'(x"ff"));

    elsif run("test_bulk_bytes") then
      memory := new_memory("memory");
      data := new_1d(length => 1000, bit_width => 8, is_signed => false);
      for idx in 0 to 999 loop

        set(data, idx, idx mod 256);
      end loop;

      write_bytes(memory, x"1_0000_0000", data);
      deallocate(data);
      data := read_bytes(memory, x"1_0000_0000", 1000);
      check_equal(length(data), 1000);
      check_equal(bit_width(data), 8);
      check_equal(get(data, 999), 999 mod 256);
      deallocate(data);

    elsif run("test_integer_arrays") then
      memory := new_memory("memory");
      data := new_2d(width => 2, height => 2, bit_width => 16, is_signed => true);
      set(data, 0, 0, 16#0102#);
      set(data, 1, 0, -1);
      set(data, 0, 1, 16#0304#);
      set(data, 1, 1, 16#0506#);
      buf := write_integer_array(memory, data, name => "image", stride_in_bytes => 6);
      check_equal(num_bytes(buf), 12);
      check_true(get_permissions(memory, 0) = read_only);
      check_equal(read_word(memory, 0, 4), std_ulogic_vector'(x"FFFF0102"));
      check_equal(read_word(memory, 6, 4), std_ulogic_vector'(x"05060304"));
      buf := set_expected_integer_array(memory, data, endian => big_endian);
      check_true(get_permissions(memory, base_address(buf)) = write_only);
      check_equal(get_expected_byte(memory, base_address(buf)), 16#01#);
      check_false(expected_was_written(buf));
      write_integer_array(memory, base_address(buf), data, endian => big_endian);
      check_true(expected_was_written(buf));
      deallocate(data);

    elsif run("test_load_image") then
      memory := new_memory("memory");
      load_image(memory, tb_path & "data/axi4_image.hex", base => 16#1000#);
      check_equal(read_word(memory, 16#1000#, 4), std_ulogic_vector'(x"78563412"));
      load_image(memory, tb_path & "data/axi4_image.hex", "hex", x"8000_0000_0000_0000");
      check_equal(read_byte(memory, x"8000_0000_0000_0003"), 16#78#);
    end if;

    test_runner_cleanup(runner);
  end process;

end architecture;
