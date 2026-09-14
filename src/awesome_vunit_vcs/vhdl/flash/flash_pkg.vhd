-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handle and procedures of the QSPI NOR flash verification component
-- (flash.vhd).
--
-- The component is a pin-level shift engine; every decision about what the
-- bytes on the wire mean is taken by the Python device model
-- (awesome_vunit_vcs.flash), which the component creates as its backend. A
-- testbench configures the device with new_flash and controls it with the
-- procedures below, and never needs to write Python.
--
-- The package also holds the VHDL half of the packed directive the backend
-- returns for every byte (awesome_vunit_vcs/flash/directive.py). The component
-- checks the backend's layout version against flash_layout_version when it
-- starts, so a layout drift fails at time 0 instead of as a wrong byte later.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.integer_array_pkg.all;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

use work.qspi_pkg.all;
use work.qspi_master_pkg.flash_provider;
use work.vcs_python_pkg.py_bool;
use work.vcs_python_pkg.py_str;

package flash_pkg is
  ---------------------------------------------------------------------------
  -- Handle
  ---------------------------------------------------------------------------

  -- The address widths a device advertises in SFDP
  type flash_addr_modes_t is (both, three_only, four_only);

  type flash_t is record
    -- Private. Use new_flash and the procedures below.
    p_std_cfg : std_cfg_t;
    -- Geometry
    p_size_bytes : positive;
    p_page_bytes : positive;
    p_sector_bytes : positive;
    p_block32_bytes : natural;
    p_block_bytes : positive;
    -- Addressing
    p_addr_bytes : positive range 3 to 4;
    p_addr_modes : flash_addr_modes_t;
    -- Identification
    p_jedec_id : natural;
    p_electronic_id : integer;
    -- Status register power-up values
    p_sr1_default : natural range 0 to 255;
    p_sr2_default : natural range 0 to 255;
    p_sr3_default : natural range 0 to 255;
    -- Busy times
    p_t_pp : delay_length;
    p_t_se : delay_length;
    p_t_be32 : delay_length;
    p_t_be64 : delay_length;
    p_t_ce : delay_length;
    p_t_w : delay_length;
    p_t_rst : delay_length;
    p_t_res1 : delay_length;
    p_t_res2 : delay_length;
    p_timing_enabled : boolean;
    -- Pin timing the controller must meet, 0 ns is not checked
    p_t_sck_min : delay_length;
    p_t_sck_high_min : delay_length;
    p_t_sck_low_min : delay_length;
    p_t_slch : delay_length;
    p_t_chsh : delay_length;
    p_t_shsl : delay_length;
    p_t_dvch : delay_length;
    p_t_chdx : delay_length;
    -- Output delays of the device
    p_t_clqv : delay_length;
    p_t_shqz : delay_length;
    p_protocol_checks : boolean;
  end record;

  -- A QSPI NOR flash device. The id defaults to awesome_vunit_vcs:flash:<n>.
  --
  -- Geometry: size_bytes, page_bytes, sector_bytes and block_bytes must be
  -- powers of two that divide each other; block32_bytes = 0 means the device
  -- has no 32 KiB block erase. addr_bytes is the power-up address width and
  -- addr_modes the widths the device supports. electronic_id = -1 derives the
  -- 0xAB electronic ID from the capacity byte of jedec_id. The device reports
  -- an invalid configuration on its logger when it starts.
  --
  -- t_pp .. t_res2 are the busy times of a page program, sector erase, 32 KiB
  -- and 64 KiB block erase, chip erase, status register write, reset and
  -- release from deep power-down (tRES1 and tRES2). timing_enabled = false
  -- makes every busy time 0 until flash_set_timing_enable.
  --
  -- t_sck_min .. t_chdx are minimum times the controller must meet (SCK
  -- period, high and low time, CS low to the first SCK rising edge, the last
  -- SCK edge to CS high, CS high time between commands, data-in setup and
  -- hold). A violation is a check failure; 0 ns disables that check and
  -- protocol_checks = false disables all of them. t_clqv and t_shqz are the
  -- delays of the device's own output after SCK falls and CS rises.
  impure function new_flash(
    id : id_t := null_id;
    size_bytes : positive := 16 * 1024 * 1024;
    page_bytes : positive := 256;
    sector_bytes : positive := 4096;
    block32_bytes : natural := 32768;
    block_bytes : positive := 65536;
    addr_bytes : positive range 3 to 4 := 3;
    addr_modes : flash_addr_modes_t := both;
    jedec_id : natural := 16#EF4018#;
    electronic_id : integer := -1;
    sr1_default : natural range 0 to 255 := 16#00#;
    sr2_default : natural range 0 to 255 := 16#02#;
    sr3_default : natural range 0 to 255 := 16#00#;
    t_pp : delay_length := 700 us;
    t_se : delay_length := 45 ms;
    t_be32 : delay_length := 120 ms;
    t_be64 : delay_length := 150 ms;
    t_ce : delay_length := 20 sec;
    t_w : delay_length := 10 ms;
    t_rst : delay_length := 30 us;
    t_res1 : delay_length := 3 us;
    t_res2 : delay_length := 1800 ns;
    timing_enabled : boolean := true;
    t_sck_min : delay_length := 7519 ps;
    t_sck_high_min : delay_length := 3 ns;
    t_sck_low_min : delay_length := 3 ns;
    t_slch : delay_length := 5 ns;
    t_chsh : delay_length := 5 ns;
    t_shsl : delay_length := 30 ns;
    t_dvch : delay_length := 2 ns;
    t_chdx : delay_length := 3 ns;
    t_clqv : delay_length := 6 ns;
    t_shqz : delay_length := 6 ns;
    protocol_checks : boolean := true;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return flash_t;

  impure function get_id(flash : flash_t) return id_t;
  impure function get_logger(flash : flash_t) return logger_t;
  impure function get_checker(flash : flash_t) return checker_t;
  impure function as_sync(flash : flash_t) return sync_handle_t;

  ---------------------------------------------------------------------------
  -- Initialization, tiered by size so the bytes crossing to Python stay few
  ---------------------------------------------------------------------------

  -- Scattered literals: the bytes cross to Python, so keep this to a few KiB.
  -- The caller keeps data.
  procedure flash_preload(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    data : integer_array_t
  );

  -- Bytes, leftmost byte first
  procedure flash_preload(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    data : std_ulogic_vector
  );

  -- O(1) in num_bytes: the model stores a run
  procedure flash_preload_fill(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    value : natural range 0 to 255 := 16#FF#
  );

  -- An Intel HEX, S-record (.srec, .s19), raw binary or JSON image, opened by
  -- Python. format "auto" picks the format from the file extension. A relative
  -- file_name is relative to the directory the simulator runs in.
  procedure flash_load_image(
    signal net : inout network_t;
    flash : flash_t;
    file_name : string;
    format : string := "auto";
    base_address : natural := 0
  );

  ---------------------------------------------------------------------------
  -- Read-back and checking
  ---------------------------------------------------------------------------

  -- A pending read-back, redeemed with await_flash_read_back_reply
  alias flash_reference_t is msg_t;

  -- Non-blocking: request num_bytes of content
  procedure flash_read_back(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    variable reference : inout flash_reference_t
  );

  -- The caller owns data and deallocates it. data is empty when the request
  -- failed, which the device reports on its logger.
  procedure await_flash_read_back_reply(
    signal net : inout network_t;
    variable reference : inout flash_reference_t;
    variable data : out integer_array_t
  );

  -- Blocking read-back
  procedure flash_read_back(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    variable data : out integer_array_t
  );

  -- Compare the content with expected in Python. A mismatch is a check
  -- failure on the checker of the device naming the first differing address.
  -- The caller keeps expected.
  procedure flash_check_content(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    expected : integer_array_t
  );

  procedure flash_check_content_fill(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    value : natural range 0 to 255
  );

  -- The regions the controller programmed or erased, coalesced, as a flat
  -- [address, length, address, length, ...]. The caller owns regions.
  procedure flash_get_written_regions(
    signal net : inout network_t;
    flash : flash_t;
    variable regions : out integer_array_t
  );

  ---------------------------------------------------------------------------
  -- Configuration
  ---------------------------------------------------------------------------

  -- false makes every busy time 0
  procedure flash_set_timing_enable(
    signal net : inout network_t;
    flash : flash_t;
    enable : boolean
  );

  -- Override one busy time: "tPP", "tSE", "tBE32", "tBE64", "tCE", "tW",
  -- "tRST", "tRES1" or "tRES2"
  procedure flash_set_timing(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    duration : delay_length
  );

  -- Lock or unlock a region. A program or erase touching a locked region is
  -- ignored, as by a real part.
  procedure flash_set_protection(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    locked : boolean
  );

  -- Block until a program or erase the device has started is finished. A
  -- controller polling the status register over the bus is the stronger check.
  procedure flash_wait_until_ready(
    signal net : inout network_t;
    flash : flash_t;
    timeout : delay_length := 1 sec
  );

  -- Power-on reset of the volatile state (status, mode, write enable); the
  -- content is kept. Blocking.
  procedure flash_reset(
    signal net : inout network_t;
    flash : flash_t
  );

  -- A counter or piece of state of the model, for example "program_count",
  -- "erase_count", "ignored_command_count", "abort_count", "wip", "addr_bytes".
  -- An unknown name, or a value that does not fit an integer, is reported on
  -- the logger of the device and returns 0.
  procedure flash_get_stat(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    variable value : out integer
  );

  ---------------------------------------------------------------------------
  -- The packed directive, see awesome_vunit_vcs/flash/directive.py
  ---------------------------------------------------------------------------

  -- Bumped whenever the layout below changes
  constant flash_layout_version : natural := 1;

  -- What the component does next. Every field of a directive describes the
  -- same, next action.
  type flash_action_t is (receive, transmit, ignore_rest);

  type flash_directive_t is record
    action : flash_action_t;
    -- Lanes of this action
    lanes : lane_count_t;
    -- SCK cycles with the IOs released before this action
    pre_dummy_cycles : natural;
    -- The byte to drive when action = transmit
    byte_out : natural range 0 to 255;
    -- The byte depends on simulation time (a status register), so the next
    -- xfer call passes the time
    is_volatile : boolean;
    -- Always 1
    num_bytes : positive;
  end record;

  constant dir_action_shift : natural := 0;
  constant dir_action_width : natural := 2;
  constant dir_lanes_shift : natural := 2;
  constant dir_lanes_width : natural := 3;
  constant dir_dummy_shift : natural := 5;
  constant dir_dummy_width : natural := 6;
  constant dir_byte_out_shift : natural := 11;
  constant dir_byte_out_width : natural := 8;
  constant dir_flags_shift : natural := 19;
  constant dir_flags_width : natural := 2;
  constant dir_num_bytes_shift : natural := 21;
  constant dir_num_bytes_width : natural := 9;

  -- The layout occupies bits 0 to 29: a VHDL integer is signed 32-bit
  constant dir_packed_max : natural := 2 ** 30 - 1;

  -- Bit index of the volatile flag within the flags field
  constant dir_flag_volatile : natural := 0;

  function decode_directive(packed : integer) return flash_directive_t;

  ---------------------------------------------------------------------------
  -- Message types
  ---------------------------------------------------------------------------

  constant flash_preload_msg : msg_type_t := new_msg_type("flash preload");
  constant flash_preload_fill_msg : msg_type_t := new_msg_type("flash preload fill");
  constant flash_load_image_msg : msg_type_t := new_msg_type("flash load image");
  constant flash_read_back_msg : msg_type_t := new_msg_type("flash read back");
  constant flash_read_back_reply_msg : msg_type_t := new_msg_type("flash read back reply");
  constant flash_check_content_msg : msg_type_t := new_msg_type("flash check content");
  constant flash_check_content_fill_msg : msg_type_t := new_msg_type("flash check content fill");
  constant flash_written_regions_msg : msg_type_t := new_msg_type("flash written regions");
  constant flash_written_regions_reply_msg : msg_type_t := new_msg_type("flash written regions reply");
  constant flash_set_timing_enable_msg : msg_type_t := new_msg_type("flash set timing enable");
  constant flash_set_timing_msg : msg_type_t := new_msg_type("flash set timing");
  constant flash_set_protection_msg : msg_type_t := new_msg_type("flash set protection");
  constant flash_wait_until_ready_msg : msg_type_t := new_msg_type("flash wait until ready");
  constant flash_reset_msg : msg_type_t := new_msg_type("flash reset");
  constant flash_get_stat_msg : msg_type_t := new_msg_type("flash get stat");
  constant flash_get_stat_reply_msg : msg_type_t := new_msg_type("flash get stat reply");

  ---------------------------------------------------------------------------
  -- Private, for the component
  ---------------------------------------------------------------------------

  -- Python module and class of the backend
  constant flash_backend_module : string := "awesome_vunit_vcs.flash.vunit_backend";
  constant flash_backend_class : string := "FlashBackend";

  -- Constructor arguments of the backend
  impure function backend_arguments(flash : flash_t) return string;

  -- A time as the two Python arguments "hi, lo", t = hi * 2**30 fs + lo fs,
  -- the convention of vcs_python_pkg and awesome_vunit_vcs.common.vunit_bridge
  function python_time_arguments(value : time) return string;

  -- The time of hi and lo returned by Python
  function from_python_time(hi : natural; lo : natural) return time;
end package;

package body flash_pkg is
  constant time_split : time := 1073741824 fs;

  impure function new_flash(
    id : id_t := null_id;
    size_bytes : positive := 16 * 1024 * 1024;
    page_bytes : positive := 256;
    sector_bytes : positive := 4096;
    block32_bytes : natural := 32768;
    block_bytes : positive := 65536;
    addr_bytes : positive range 3 to 4 := 3;
    addr_modes : flash_addr_modes_t := both;
    jedec_id : natural := 16#EF4018#;
    electronic_id : integer := -1;
    sr1_default : natural range 0 to 255 := 16#00#;
    sr2_default : natural range 0 to 255 := 16#02#;
    sr3_default : natural range 0 to 255 := 16#00#;
    t_pp : delay_length := 700 us;
    t_se : delay_length := 45 ms;
    t_be32 : delay_length := 120 ms;
    t_be64 : delay_length := 150 ms;
    t_ce : delay_length := 20 sec;
    t_w : delay_length := 10 ms;
    t_rst : delay_length := 30 us;
    t_res1 : delay_length := 3 us;
    t_res2 : delay_length := 1800 ns;
    timing_enabled : boolean := true;
    t_sck_min : delay_length := 7519 ps;
    t_sck_high_min : delay_length := 3 ns;
    t_sck_low_min : delay_length := 3 ns;
    t_slch : delay_length := 5 ns;
    t_chsh : delay_length := 5 ns;
    t_shsl : delay_length := 30 ns;
    t_dvch : delay_length := 2 ns;
    t_chdx : delay_length := 3 ns;
    t_clqv : delay_length := 6 ns;
    t_shqz : delay_length := 6 ns;
    protocol_checks : boolean := true;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return flash_t is
  begin
    return (
      p_std_cfg => create_std_cfg(
        id => id,
        provider => flash_provider,
        vc_name => "flash",
        unexpected_msg_type_policy => unexpected_msg_type_policy
      ),
      p_size_bytes => size_bytes,
      p_page_bytes => page_bytes,
      p_sector_bytes => sector_bytes,
      p_block32_bytes => block32_bytes,
      p_block_bytes => block_bytes,
      p_addr_bytes => addr_bytes,
      p_addr_modes => addr_modes,
      p_jedec_id => jedec_id,
      p_electronic_id => electronic_id,
      p_sr1_default => sr1_default,
      p_sr2_default => sr2_default,
      p_sr3_default => sr3_default,
      p_t_pp => t_pp,
      p_t_se => t_se,
      p_t_be32 => t_be32,
      p_t_be64 => t_be64,
      p_t_ce => t_ce,
      p_t_w => t_w,
      p_t_rst => t_rst,
      p_t_res1 => t_res1,
      p_t_res2 => t_res2,
      p_timing_enabled => timing_enabled,
      p_t_sck_min => t_sck_min,
      p_t_sck_high_min => t_sck_high_min,
      p_t_sck_low_min => t_sck_low_min,
      p_t_slch => t_slch,
      p_t_chsh => t_chsh,
      p_t_shsl => t_shsl,
      p_t_dvch => t_dvch,
      p_t_chdx => t_chdx,
      p_t_clqv => t_clqv,
      p_t_shqz => t_shqz,
      p_protocol_checks => protocol_checks
    );
  end;

  impure function get_id(flash : flash_t) return id_t is
  begin
    return get_id(flash.p_std_cfg);
  end;

  impure function get_logger(flash : flash_t) return logger_t is
  begin
    return get_logger(flash.p_std_cfg);
  end;

  impure function get_checker(flash : flash_t) return checker_t is
  begin
    return get_checker(flash.p_std_cfg);
  end;

  impure function as_sync(flash : flash_t) return sync_handle_t is
  begin
    return get_actor(flash.p_std_cfg);
  end;

  function python_time_arguments(value : time) return string is
    constant hi : natural := value / time_split;
    constant lo : natural := (value - hi * time_split) / 1 fs;
  begin
    return integer'image(hi) & ", " & integer'image(lo);
  end;

  function from_python_time(hi : natural; lo : natural) return time is
  begin
    return hi * time_split + lo * 1 fs;
  end;

  -- A time as a Python tuple (hi, lo)
  function to_python_time(value : time) return string is
  begin
    return "(" & python_time_arguments(value) & ")";
  end;

  function addr_modes_argument(addr_modes : flash_addr_modes_t) return string is
  begin
    case addr_modes is
      when both => return "0";
      when three_only => return "3";
      when four_only => return "4";
    end case;
  end;

  impure function backend_arguments(flash : flash_t) return string is
  begin
    return
      py_str(full_name(get_id(flash))) &
      ", size_bytes=" & integer'image(flash.p_size_bytes) &
      ", page_bytes=" & integer'image(flash.p_page_bytes) &
      ", sector_bytes=" & integer'image(flash.p_sector_bytes) &
      ", block32_bytes=" & integer'image(flash.p_block32_bytes) &
      ", block_bytes=" & integer'image(flash.p_block_bytes) &
      ", addr_bytes=" & integer'image(flash.p_addr_bytes) &
      ", addr_modes=" & addr_modes_argument(flash.p_addr_modes) &
      ", jedec_id=" & integer'image(flash.p_jedec_id) &
      ", electronic_id=" & integer'image(flash.p_electronic_id) &
      ", sr1_default=" & integer'image(flash.p_sr1_default) &
      ", sr2_default=" & integer'image(flash.p_sr2_default) &
      ", sr3_default=" & integer'image(flash.p_sr3_default) &
      ", busy={'tPP': " & to_python_time(flash.p_t_pp) &
      ", 'tSE': " & to_python_time(flash.p_t_se) &
      ", 'tBE32': " & to_python_time(flash.p_t_be32) &
      ", 'tBE64': " & to_python_time(flash.p_t_be64) &
      ", 'tCE': " & to_python_time(flash.p_t_ce) &
      ", 'tW': " & to_python_time(flash.p_t_w) &
      ", 'tRST': " & to_python_time(flash.p_t_rst) &
      ", 'tRES1': " & to_python_time(flash.p_t_res1) &
      ", 'tRES2': " & to_python_time(flash.p_t_res2) & "}" &
      ", timing_enabled=" & py_bool(flash.p_timing_enabled);
  end;

  -- width bits of a non-negative integer, starting at shift
  function extract_field(packed : integer; shift : natural; width : natural) return natural is
  begin
    return (packed / (2 ** shift)) mod (2 ** width);
  end;

  function decode_directive(packed : integer) return flash_directive_t is
    constant action : natural := extract_field(packed, dir_action_shift, dir_action_width);
    constant lanes : natural := extract_field(packed, dir_lanes_shift, dir_lanes_width);
    constant flags : natural := extract_field(packed, dir_flags_shift, dir_flags_width);
    constant num_bytes : natural := extract_field(packed, dir_num_bytes_shift, dir_num_bytes_width);
  begin
    assert packed >= 0 and packed <= dir_packed_max
      report "flash_pkg.decode_directive: packed directive " & integer'image(packed) &
        " is outside 0 to " & integer'image(dir_packed_max) & ", a layout drift or a field overflow"
      severity failure;
    assert action <= flash_action_t'pos(flash_action_t'high)
      report "flash_pkg.decode_directive: action code " & integer'image(action) & " is not a flash_action_t"
      severity failure;
    assert lanes = 1 or lanes = 2 or lanes = 4
      report "flash_pkg.decode_directive: lane count " & integer'image(lanes) & " is not 1, 2 or 4"
      severity failure;
    assert num_bytes >= 1
      report "flash_pkg.decode_directive: num_bytes must be at least 1"
      severity failure;

    return (
      action => flash_action_t'val(action),
      lanes => lanes,
      pre_dummy_cycles => extract_field(packed, dir_dummy_shift, dir_dummy_width),
      byte_out => extract_field(packed, dir_byte_out_shift, dir_byte_out_width),
      is_volatile => (flags / (2 ** dir_flag_volatile)) mod 2 = 1,
      num_bytes => num_bytes
    );
  end;

  procedure flash_preload(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    data : integer_array_t
  ) is
    variable msg : msg_t := new_msg(flash_preload_msg);
    -- push_integer_array_t_ref takes ownership, so the message carries a copy
    -- and the caller keeps data. The component deallocates the copy.
    variable owned : integer_array_t := copy(data);
  begin
    push(msg, address);
    push_integer_array_t_ref(msg, owned);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_preload(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    data : std_ulogic_vector
  ) is
    constant num_bytes : natural := data'length / 8;
    alias bits : std_ulogic_vector(0 to data'length - 1) is data;
    variable bytes : integer_array_t := new_1d(length => num_bytes, bit_width => 8, is_signed => false);
  begin
    assert data'length mod 8 = 0
      report "flash_preload: vector length " & integer'image(data'length) & " is not a whole number of bytes"
      severity failure;

    for idx in 0 to num_bytes - 1 loop
      set(bytes, idx, to_integer(unsigned(bits(8 * idx to 8 * idx + 7))));
    end loop;

    flash_preload(net, flash, address, bytes);
    deallocate(bytes);
  end;

  procedure flash_preload_fill(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    value : natural range 0 to 255 := 16#FF#
  ) is
    variable msg : msg_t := new_msg(flash_preload_fill_msg);
  begin
    push(msg, address);
    push(msg, num_bytes);
    push(msg, value);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_load_image(
    signal net : inout network_t;
    flash : flash_t;
    file_name : string;
    format : string := "auto";
    base_address : natural := 0
  ) is
    variable msg : msg_t := new_msg(flash_load_image_msg);
  begin
    push_string(msg, file_name);
    push_string(msg, format);
    push(msg, base_address);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_read_back(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    variable reference : inout flash_reference_t
  ) is
  begin
    reference := new_msg(flash_read_back_msg);
    push(reference, address);
    push(reference, num_bytes);
    send(net, get_actor(flash.p_std_cfg), reference);
  end;

  procedure await_flash_read_back_reply(
    signal net : inout network_t;
    variable reference : inout flash_reference_t;
    variable data : out integer_array_t
  ) is
    variable reply_msg : msg_t;
  begin
    receive_reply(net, reference, reply_msg);
    data := pop_integer_array_t_ref(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure flash_read_back(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    variable data : out integer_array_t
  ) is
    variable reference : flash_reference_t;
  begin
    flash_read_back(net, flash, address, num_bytes, reference);
    await_flash_read_back_reply(net, reference, data);
  end;

  procedure flash_check_content(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    expected : integer_array_t
  ) is
    variable msg : msg_t := new_msg(flash_check_content_msg);
    -- A copy, as in flash_preload
    variable owned : integer_array_t := copy(expected);
  begin
    push(msg, address);
    push_integer_array_t_ref(msg, owned);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_check_content_fill(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    value : natural range 0 to 255
  ) is
    variable msg : msg_t := new_msg(flash_check_content_fill_msg);
  begin
    push(msg, address);
    push(msg, num_bytes);
    push(msg, value);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_get_written_regions(
    signal net : inout network_t;
    flash : flash_t;
    variable regions : out integer_array_t
  ) is
    variable request_msg : msg_t := new_msg(flash_written_regions_msg);
    variable reply_msg : msg_t;
  begin
    request(net, get_actor(flash.p_std_cfg), request_msg, reply_msg);
    regions := pop_integer_array_t_ref(reply_msg);
    delete(reply_msg);
  end;

  procedure flash_set_timing_enable(
    signal net : inout network_t;
    flash : flash_t;
    enable : boolean
  ) is
    variable msg : msg_t := new_msg(flash_set_timing_enable_msg);
  begin
    push(msg, enable);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_set_timing(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    duration : delay_length
  ) is
    variable msg : msg_t := new_msg(flash_set_timing_msg);
  begin
    push_string(msg, name);
    push_time(msg, duration);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_set_protection(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    locked : boolean
  ) is
    variable msg : msg_t := new_msg(flash_set_protection_msg);
  begin
    push(msg, address);
    push(msg, num_bytes);
    push(msg, locked);
    send(net, get_actor(flash.p_std_cfg), msg);
  end;

  procedure flash_wait_until_ready(
    signal net : inout network_t;
    flash : flash_t;
    timeout : delay_length := 1 sec
  ) is
    variable request_msg : msg_t := new_msg(flash_wait_until_ready_msg);
    variable reply_msg : msg_t;
  begin
    request(net, get_actor(flash.p_std_cfg), request_msg, reply_msg, timeout => timeout);
    delete(reply_msg);
  end;

  procedure flash_reset(
    signal net : inout network_t;
    flash : flash_t
  ) is
    variable request_msg : msg_t := new_msg(flash_reset_msg);
    variable reply_msg : msg_t;
  begin
    -- Blocking, so the first stimulus of a test cannot race the reset
    request(net, get_actor(flash.p_std_cfg), request_msg, reply_msg);
    delete(reply_msg);
  end;

  procedure flash_get_stat(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    variable value : out integer
  ) is
    variable request_msg : msg_t := new_msg(flash_get_stat_msg);
    variable reply_msg : msg_t;
  begin
    push_string(request_msg, name);
    request(net, get_actor(flash.p_std_cfg), request_msg, reply_msg);
    value := pop_integer(reply_msg);
    delete(reply_msg);
  end;
end package body;
