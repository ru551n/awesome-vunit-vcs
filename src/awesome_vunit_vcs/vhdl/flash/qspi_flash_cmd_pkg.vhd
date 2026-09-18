-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- JEDEC serial NOR flash command layer for the QSPI master VC.
--
-- This is the only place on the master side where a flash opcode appears.
-- qspi_master_pkg and qspi_master.vhd stay protocol-generic; every procedure
-- here is a thin, blocking wrapper that composes the opcode, address, dummy
-- and data phases of one command and hands them to qspi_transfer. Anything
-- this package cannot express -- a vendor command, a deliberately malformed
-- frame for a negative test -- is still reachable by calling qspi_transfer
-- directly.
--
-- The defaults below are the common JEDEC phase shapes (for example eight
-- dummy cycles for 0x0B and 0x6B, four for 0xEB after its mode byte). Every
-- one of them is a parameter, because the number of dummy cycles is
-- configurable in real parts and the device model is free to expect a
-- different value.
--
-- Addressing. Every address-bearing command takes addr_bytes, which is 3 for
-- the classic 24-bit address space and 4 for a part in 4-byte address mode
-- (see qspi_flash_enter_4byte). Addresses are passed as a natural, so the
-- reachable range is 0 .. 2**31 - 1; that covers every 3-byte address and
-- every 4-byte address up to 2 GiB, which is past the top of any part this
-- model targets.
--
-- QPI. A part put into QPI mode with qspi_flash_enter_qpi expects its opcodes
-- on four lanes, so every procedure takes opcode_lanes (and, where the command
-- has one, addr_lanes). qspi_flash_exit_qpi therefore defaults to sending its
-- opcode on four lanes -- it is the one command that is only ever issued while
-- in QPI mode.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;

  use work.qspi_pkg.all;
  use work.qspi_master_pkg.all;

package qspi_flash_cmd_pkg is

  ---------------------------------------------------------------------------
  -- Opcodes
  ---------------------------------------------------------------------------

  -- The opcodes the procedures below send. qspi_flash_op_quad_page_program
  -- and qspi_flash_op_block_erase_32k are passed as their opcode argument;
  -- qspi_flash_op_write_disable has no procedure and is sent with
  -- qspi_transfer.
  constant qspi_flash_op_read_id : natural := 16#9F#;
  constant qspi_flash_op_read : natural := 16#03#;
  constant qspi_flash_op_fast_read : natural := 16#0B#;
  constant qspi_flash_op_quad_output_read : natural := 16#6B#;
  constant qspi_flash_op_quad_io_read : natural := 16#EB#;
  constant qspi_flash_op_write_enable : natural := 16#06#;
  constant qspi_flash_op_write_disable : natural := 16#04#;
  constant qspi_flash_op_page_program : natural := 16#02#;
  constant qspi_flash_op_quad_page_program : natural := 16#32#;
  constant qspi_flash_op_sector_erase : natural := 16#20#;
  constant qspi_flash_op_block_erase_32k : natural := 16#52#;
  constant qspi_flash_op_block_erase_64k : natural := 16#D8#;
  constant qspi_flash_op_chip_erase : natural := 16#C7#;
  constant qspi_flash_op_enter_4byte : natural := 16#B7#;
  constant qspi_flash_op_exit_4byte : natural := 16#E9#;
  constant qspi_flash_op_enter_qpi : natural := 16#38#;
  constant qspi_flash_op_exit_qpi : natural := 16#FF#;

  -- Status registers 1, 2 and 3 have one opcode each, indexed by number.
  subtype qspi_flash_status_index_t is positive range 1 to 3;

  -- Read and write status register opcodes, indexed by qspi_flash_status_index_t.
  constant qspi_flash_op_read_status : integer_vector(1 to 3) := (16#05#, 16#35#, 16#15#);
  constant qspi_flash_op_write_status : integer_vector(1 to 3) := (16#01#, 16#31#, 16#11#);

  -- Default dummy-cycle counts of the commands that have them.
  constant qspi_flash_fast_read_dummy : natural := 8;
  constant qspi_flash_quad_output_read_dummy : natural := 8;
  constant qspi_flash_quad_io_read_dummy : natural := 4;

  -- Address width, in bytes, of a part in the classic and in 4-byte mode.
  subtype qspi_flash_addr_bytes_t is positive range 3 to 4;

  ---------------------------------------------------------------------------
  -- Byte-array helpers
  ---------------------------------------------------------------------------

  -- A one-element byte array, for an opcode. The caller owns the result.
  impure function qspi_flash_opcode_bytes (opcode : natural) return integer_array_t;

  -- num_bytes address bytes, most significant first. The caller owns the
  -- result.
  impure function qspi_flash_address_bytes (addr : natural; num_bytes : qspi_flash_addr_bytes_t) return integer_array_t;

  ---------------------------------------------------------------------------
  -- Identification
  ---------------------------------------------------------------------------

  -- 0x9F. data is replaced by the num_bytes manufacturer and device bytes
  -- read back, and is owned by the caller afterwards.
  procedure qspi_flash_read_id (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    variable data : inout integer_array_t;
    num_bytes : positive := 3;
    opcode_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  );

  ---------------------------------------------------------------------------
  -- Reads
  ---------------------------------------------------------------------------

  -- 0x03: address and data on lanes, no dummy cycles. data is replaced by
  -- the num_bytes bytes read, which the caller owns, as for all reads below.
  procedure qspi_flash_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode_lanes : lane_count_t := 1;
    lanes : lane_count_t := 1
  );

  -- 0x0B: address and data on lanes after dummy_cycles. In QPI mode every
  -- phase is on four lanes, which is opcode_lanes => 4, lanes => 4.
  procedure qspi_flash_fast_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    dummy_cycles : natural := qspi_flash_fast_read_dummy;
    opcode_lanes : lane_count_t := 1;
    lanes : lane_count_t := 1
  );

  -- 0x6B: opcode and address on one lane, data on four.
  procedure qspi_flash_quad_output_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    dummy_cycles : natural := qspi_flash_quad_output_read_dummy;
    opcode_lanes : lane_count_t := 1
  );

  -- 0xEB: opcode on one lane, then address plus the M7-M0 mode byte on four,
  -- then the dummy cycles, then data on four. Set send_mode_byte false for a
  -- part that does not implement continuous-read mode.
  procedure qspi_flash_quad_io_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    dummy_cycles : natural := qspi_flash_quad_io_read_dummy;
    mode_byte : natural := 0;
    send_mode_byte : boolean := true;
    opcode_lanes : lane_count_t := 1
  );

  ---------------------------------------------------------------------------
  -- Writes and erases
  ---------------------------------------------------------------------------

  -- 0x06: set the write enable latch.
  procedure qspi_flash_write_enable (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  );

  -- 0x02 by default, with the bytes of data. A quad input page program is
  -- opcode => qspi_flash_op_quad_page_program, data_lanes => 4. The caller
  -- keeps data.
  procedure qspi_flash_page_program (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    data : integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode : natural := qspi_flash_op_page_program;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  );

  -- 0x02 with data, a vector of whole bytes with the byte of addr leftmost,
  -- for example x"DEADBEEF". The other parameters are those of the
  -- integer_array_t overload.
  procedure qspi_flash_page_program (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    data : std_ulogic_vector;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode : natural := qspi_flash_op_page_program;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  );

  -- 0x20: erase the 4 KiB sector at addr.
  procedure qspi_flash_sector_erase (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1
  );

  -- 0xD8 (64 KiB) by default; pass qspi_flash_op_block_erase_32k for 32 KiB.
  procedure qspi_flash_block_erase (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode : natural := qspi_flash_op_block_erase_64k;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1
  );

  -- 0xC7: erase the whole device.
  procedure qspi_flash_chip_erase (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  );

  ---------------------------------------------------------------------------
  -- Status registers
  ---------------------------------------------------------------------------

  -- 0x05, 0x35 or 0x15: read status register 1, 2 or 3 into status.
  procedure qspi_flash_read_status (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    variable status : out natural;
    register_index : qspi_flash_status_index_t := 1;
    opcode_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  );

  -- 0x01, 0x31 or 0x11: write value to status register 1, 2 or 3. Needs a
  -- preceding qspi_flash_write_enable on a real part.
  procedure qspi_flash_write_status (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    value : natural;
    register_index : qspi_flash_status_index_t := 1;
    opcode_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  );

  ---------------------------------------------------------------------------
  -- Mode changes
  ---------------------------------------------------------------------------

  -- 0xB7: enter 4-byte address mode.
  procedure qspi_flash_enter_4byte (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  );

  -- 0xE9: leave 4-byte address mode.
  procedure qspi_flash_exit_4byte (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  );

  -- 0x38: sent on one lane, since the part is not in QPI mode yet.
  procedure qspi_flash_enter_qpi (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  );

  -- 0xFF: sent on four lanes, since the part is in QPI mode when it is issued.
  procedure qspi_flash_exit_qpi (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 4
  );
end package;

package body qspi_flash_cmd_pkg is

  impure function qspi_flash_opcode_bytes (opcode : natural) return integer_array_t is

    variable result : integer_array_t;
  begin

    result := new_1d(length => 1, bit_width => 8, is_signed => false);
    set(result, 0, opcode);

    return result;
  end;

  impure function qspi_flash_address_bytes (
    addr : natural;
    num_bytes : qspi_flash_addr_bytes_t
  ) return integer_array_t is

    constant addr_value : u_unsigned(8 * num_bytes - 1 downto 0) := to_unsigned(addr, 8 * num_bytes);
    variable result : integer_array_t;
    variable byte : natural;
  begin

    result := new_1d(length => num_bytes, bit_width => 8, is_signed => false);
    for index in 0 to num_bytes - 1 loop

      -- Most significant byte first.
      byte := to_integer(addr_value(8 * (num_bytes - index) - 1 downto 8 * (num_bytes - index - 1)));
      set(result, index, byte);
    end loop;

    return result;
  end;

  -- An address byte array with the mode byte appended, for 0xEB.
  impure function address_and_mode_bytes (
    addr : natural;
    num_bytes : qspi_flash_addr_bytes_t;
    mode_byte : natural
  ) return integer_array_t is

    variable result : integer_array_t;
  begin

    result := qspi_flash_address_bytes(addr, num_bytes);
    append(result, mode_byte);

    return result;
  end;

  -- Every command below funnels through this: compose the phases, run one
  -- transaction, and free the byte arrays the command itself allocated.
  procedure run_command (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode : natural;
    opcode_lanes : lane_count_t;
    addr : integer_array_t;
    addr_lanes : lane_count_t;
    wr_data : integer_array_t;
    wr_lanes : lane_count_t;
    dummy_cycles : natural;
    variable rd_data : inout integer_array_t;
    num_read_bytes : natural;
    read_lanes : lane_count_t
  ) is

    variable cmd : integer_array_t := qspi_flash_opcode_bytes(opcode);
  begin

    qspi_transfer(
      net => net,
      qspi_master => qspi_master,
      cmd => cmd,
      data => rd_data,
      cmd_lanes => opcode_lanes,
      addr => addr,
      addr_lanes => addr_lanes,
      wr_data => wr_data,
      wr_lanes => wr_lanes,
      dummy_cycles => dummy_cycles,
      num_read_bytes => num_read_bytes,
      read_lanes => read_lanes
    );

    deallocate(cmd);
  end;

  -- An opcode-only command: no address, no data, no dummy cycles.
  procedure run_opcode_only (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode : natural;
    opcode_lanes : lane_count_t
  ) is

    variable rd_data : integer_array_t := null_integer_array;
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => opcode,
      opcode_lanes => opcode_lanes,
      addr => null_integer_array,
      addr_lanes => 1,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => 0,
      rd_data => rd_data,
      num_read_bytes => 0,
      read_lanes => 1
    );

    deallocate(rd_data);
  end;

  procedure qspi_flash_read_id (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    variable data : inout integer_array_t;
    num_bytes : positive := 3;
    opcode_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  ) is
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_read_id,
      opcode_lanes => opcode_lanes,
      addr => null_integer_array,
      addr_lanes => 1,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => 0,
      rd_data => data,
      num_read_bytes => num_bytes,
      read_lanes => data_lanes
    );
  end;

  procedure qspi_flash_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode_lanes : lane_count_t := 1;
    lanes : lane_count_t := 1
  ) is

    variable address : integer_array_t := qspi_flash_address_bytes(addr, addr_bytes);
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_read,
      opcode_lanes => opcode_lanes,
      addr => address,
      addr_lanes => lanes,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => 0,
      rd_data => data,
      num_read_bytes => num_bytes,
      read_lanes => lanes
    );

    deallocate(address);
  end;

  procedure qspi_flash_fast_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    dummy_cycles : natural := qspi_flash_fast_read_dummy;
    opcode_lanes : lane_count_t := 1;
    lanes : lane_count_t := 1
  ) is

    variable address : integer_array_t := qspi_flash_address_bytes(addr, addr_bytes);
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_fast_read,
      opcode_lanes => opcode_lanes,
      addr => address,
      addr_lanes => lanes,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => dummy_cycles,
      rd_data => data,
      num_read_bytes => num_bytes,
      read_lanes => lanes
    );

    deallocate(address);
  end;

  procedure qspi_flash_quad_output_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    dummy_cycles : natural := qspi_flash_quad_output_read_dummy;
    opcode_lanes : lane_count_t := 1
  ) is

    variable address : integer_array_t := qspi_flash_address_bytes(addr, addr_bytes);
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_quad_output_read,
      opcode_lanes => opcode_lanes,
      addr => address,
      addr_lanes => 1,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => dummy_cycles,
      rd_data => data,
      num_read_bytes => num_bytes,
      read_lanes => 4
    );

    deallocate(address);
  end;

  procedure qspi_flash_quad_io_read (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    num_bytes : positive;
    variable data : inout integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    dummy_cycles : natural := qspi_flash_quad_io_read_dummy;
    mode_byte : natural := 0;
    send_mode_byte : boolean := true;
    opcode_lanes : lane_count_t := 1
  ) is

    variable address : integer_array_t;
  begin

    if send_mode_byte then
      address := address_and_mode_bytes(addr, addr_bytes, mode_byte);
    else
      address := qspi_flash_address_bytes(addr, addr_bytes);
    end if;

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_quad_io_read,
      opcode_lanes => opcode_lanes,
      addr => address,
      addr_lanes => 4,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => dummy_cycles,
      rd_data => data,
      num_read_bytes => num_bytes,
      read_lanes => 4
    );

    deallocate(address);
  end;

  procedure qspi_flash_write_enable (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  ) is
  begin

    run_opcode_only(net, qspi_master, qspi_flash_op_write_enable, opcode_lanes);
  end;

  procedure qspi_flash_page_program (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    data : integer_array_t;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode : natural := qspi_flash_op_page_program;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  ) is

    variable address : integer_array_t := qspi_flash_address_bytes(addr, addr_bytes);
    variable rd_data : integer_array_t := null_integer_array;
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => opcode,
      opcode_lanes => opcode_lanes,
      addr => address,
      addr_lanes => addr_lanes,
      wr_data => data,
      wr_lanes => data_lanes,
      dummy_cycles => 0,
      rd_data => rd_data,
      num_read_bytes => 0,
      read_lanes => 1
    );

    deallocate(address);
    deallocate(rd_data);
  end;

  procedure qspi_flash_page_program (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    data : std_ulogic_vector;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode : natural := qspi_flash_op_page_program;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  ) is

    alias bits : std_ulogic_vector(0 to data'length - 1) is data;
    variable bytes : integer_array_t := new_1d(length => data'length / 8, bit_width => 8, is_signed => false);
  begin

    assert data'length mod 8 = 0
      report "qspi_flash_page_program: vector length " & integer'image(data'length) & " is not a whole number of bytes"
      severity failure;
    for idx in 0 to data'length / 8 - 1 loop

      set(bytes, idx, to_integer(unsigned(bits(8 * idx to 8 * idx + 7))));
    end loop;

    qspi_flash_page_program(net, qspi_master, addr, bytes, addr_bytes, opcode, opcode_lanes, addr_lanes, data_lanes);
    deallocate(bytes);
  end;

  procedure run_erase (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode : natural;
    addr : natural;
    addr_bytes : qspi_flash_addr_bytes_t;
    opcode_lanes : lane_count_t;
    addr_lanes : lane_count_t
  ) is

    variable address : integer_array_t := qspi_flash_address_bytes(addr, addr_bytes);
    variable rd_data : integer_array_t := null_integer_array;
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => opcode,
      opcode_lanes => opcode_lanes,
      addr => address,
      addr_lanes => addr_lanes,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => 0,
      rd_data => rd_data,
      num_read_bytes => 0,
      read_lanes => 1
    );

    deallocate(address);
    deallocate(rd_data);
  end;

  procedure qspi_flash_sector_erase (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1
  ) is
  begin

    run_erase(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_sector_erase,
      addr => addr,
      addr_bytes => addr_bytes,
      opcode_lanes => opcode_lanes,
      addr_lanes => addr_lanes
    );
  end;

  procedure qspi_flash_block_erase (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    addr : natural;
    addr_bytes : qspi_flash_addr_bytes_t := 3;
    opcode : natural := qspi_flash_op_block_erase_64k;
    opcode_lanes : lane_count_t := 1;
    addr_lanes : lane_count_t := 1
  ) is
  begin

    run_erase(
      net => net,
      qspi_master => qspi_master,
      opcode => opcode,
      addr => addr,
      addr_bytes => addr_bytes,
      opcode_lanes => opcode_lanes,
      addr_lanes => addr_lanes
    );
  end;

  procedure qspi_flash_chip_erase (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  ) is
  begin

    run_opcode_only(net, qspi_master, qspi_flash_op_chip_erase, opcode_lanes);
  end;

  procedure qspi_flash_read_status (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    variable status : out natural;
    register_index : qspi_flash_status_index_t := 1;
    opcode_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  ) is

    variable data : integer_array_t := null_integer_array;
  begin

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_read_status(register_index),
      opcode_lanes => opcode_lanes,
      addr => null_integer_array,
      addr_lanes => 1,
      wr_data => null_integer_array,
      wr_lanes => 1,
      dummy_cycles => 0,
      rd_data => data,
      num_read_bytes => 1,
      read_lanes => data_lanes
    );

    status := get(data, 0);
    deallocate(data);
  end;

  procedure qspi_flash_write_status (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    value : natural;
    register_index : qspi_flash_status_index_t := 1;
    opcode_lanes : lane_count_t := 1;
    data_lanes : lane_count_t := 1
  ) is

    variable wr_data : integer_array_t := new_1d(length => 1, bit_width => 8, is_signed => false);
    variable rd_data : integer_array_t := null_integer_array;
  begin

    set(wr_data, 0, value);

    run_command(
      net => net,
      qspi_master => qspi_master,
      opcode => qspi_flash_op_write_status(register_index),
      opcode_lanes => opcode_lanes,
      addr => null_integer_array,
      addr_lanes => 1,
      wr_data => wr_data,
      wr_lanes => data_lanes,
      dummy_cycles => 0,
      rd_data => rd_data,
      num_read_bytes => 0,
      read_lanes => 1
    );

    deallocate(wr_data);
    deallocate(rd_data);
  end;

  procedure qspi_flash_enter_4byte (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  ) is
  begin

    run_opcode_only(net, qspi_master, qspi_flash_op_enter_4byte, opcode_lanes);
  end;

  procedure qspi_flash_exit_4byte (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  ) is
  begin

    run_opcode_only(net, qspi_master, qspi_flash_op_exit_4byte, opcode_lanes);
  end;

  procedure qspi_flash_enter_qpi (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 1
  ) is
  begin

    run_opcode_only(net, qspi_master, qspi_flash_op_enter_qpi, opcode_lanes);
  end;

  procedure qspi_flash_exit_qpi (
    signal net : inout network_t;
    qspi_master : qspi_master_t;
    opcode_lanes : lane_count_t := 4
  ) is
  begin

    run_opcode_only(net, qspi_master, qspi_flash_op_exit_qpi, opcode_lanes);
  end;

end package body;
