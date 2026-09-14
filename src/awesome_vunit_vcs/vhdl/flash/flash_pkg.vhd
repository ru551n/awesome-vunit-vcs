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
-- The pin timing of the controller is checked by a
-- :vhdl:`qspi_protocol_checker_pkg.qspi_protocol_checker_t` given to
-- new_flash, which the component instantiates on its pins.
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
use vunit_lib.dict_pkg.all;

library python_bridge;
context python_bridge.python_context;

use work.qspi_pkg.all;
use work.qspi_protocol_checker_pkg.all;
use work.vcs_python_pkg.new_vc_session;
use work.vcs_python_pkg.py_bool;
use work.vcs_python_pkg.py_str;

package flash_pkg is
  ---------------------------------------------------------------------------
  -- Handle
  ---------------------------------------------------------------------------

  -- The address widths a device advertises in SFDP
  type flash_addr_modes_t is (both, three_only, four_only);

  -- The handle of a flash, created with :vhdl:`flash_pkg.new_flash`. It is
  -- the generic of the flash entity and the first argument of the procedures
  -- below.
  type flash_t is record
    -- Private. Use new_flash and the procedures below.
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
    -- Output delays of the device
    p_t_clqv : delay_length;
    p_t_shqz : delay_length;
    -- Pin timing of the controller
    p_protocol_checker : qspi_protocol_checker_t;
    -- Standard VC configuration
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
  end record;

  -- No flash
  constant null_flash : flash_t := (
    p_size_bytes => 1,
    p_page_bytes => 1,
    p_sector_bytes => 1,
    p_block32_bytes => 0,
    p_block_bytes => 1,
    p_addr_bytes => 3,
    p_addr_modes => both,
    p_jedec_id => 0,
    p_electronic_id => -1,
    p_sr1_default => 0,
    p_sr2_default => 0,
    p_sr3_default => 0,
    p_t_pp => 0 ns,
    p_t_se => 0 ns,
    p_t_be32 => 0 ns,
    p_t_be64 => 0 ns,
    p_t_ce => 0 ns,
    p_t_w => 0 ns,
    p_t_rst => 0 ns,
    p_t_res1 => 0 ns,
    p_t_res2 => 0 ns,
    p_timing_enabled => false,
    p_t_clqv => 0 ns,
    p_t_shqz => 0 ns,
    p_protocol_checker => null_qspi_protocol_checker,
    p_id => null_id,
    p_logger => null_logger,
    p_actor => null_actor,
    p_checker => null_checker,
    p_unexpected_msg_type_policy => fail
  );

  -- A QSPI NOR flash device.
  --
  -- Geometry: ``size_bytes``, ``page_bytes``, ``sector_bytes`` and
  -- ``block_bytes`` must be powers of two that divide each other;
  -- ``block32_bytes`` = 0 means the device has no 32 KiB block erase.
  -- ``addr_bytes`` is the power-up address width and ``addr_modes`` the
  -- widths the device supports. ``electronic_id`` = -1 derives the 0xAB
  -- electronic ID from the capacity byte of ``jedec_id``. The device reports
  -- an invalid configuration on its logger when it starts.
  --
  -- ``t_pp`` .. ``t_res2`` are the busy times of a page program, sector
  -- erase, 32 KiB and 64 KiB block erase, chip erase, status register write,
  -- reset and release from deep power-down (tRES1 and tRES2).
  -- ``timing_enabled`` = false makes every busy time 0 until
  -- :vhdl:`flash_pkg.flash_set_timing_enable`. ``t_clqv`` and ``t_shqz`` are
  -- the delays of the device's own output after SCK falls and CS rises.
  --
  -- The pin timing of the controller is not checked unless
  -- ``protocol_checker`` is a
  -- :vhdl:`qspi_protocol_checker_pkg.new_qspi_protocol_checker`, which the
  -- flash instantiates on its pins with the id ``<id>:protocol_checker``
  -- unless it was created with an explicit id. Metavalues on the IOs the
  -- device samples, content mismatches and backend errors are reported on
  -- the checker of the flash.
  --
  -- ``id`` defaults to ``awesome_vunit_vcs:flash:<n>`` and is the identity of
  -- the Python backend. The logger defaults to the logger of the id, the
  -- actor to a new actor of the id and the checker to a checker on the
  -- logger. ``unexpected_msg_type_policy`` says whether a message of an
  -- unknown type is a failure (``fail``) or ignored (``ignore``).
  impure function new_flash(
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
    t_clqv : delay_length := 6 ns;
    t_shqz : delay_length := 6 ns;
    protocol_checker : qspi_protocol_checker_t := null_qspi_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return flash_t;

  -- The id, logger, actor and checker of the flash, and its handle for
  -- wait_until_idle and wait_for_time of sync_pkg
  impure function get_id(flash : flash_t) return id_t;
  impure function get_logger(flash : flash_t) return logger_t;
  impure function get_actor(flash : flash_t) return actor_t;
  impure function get_checker(flash : flash_t) return checker_t;
  impure function as_sync(flash : flash_t) return sync_handle_t;

  -- The protocol checker the flash instantiates, with its final id, or
  -- :vhdl:`qspi_protocol_checker_pkg.null_qspi_protocol_checker`
  function protocol_checker(flash : flash_t) return qspi_protocol_checker_t;

  -- The delay of the device's output after SCK falls (tCLQV) and of
  -- releasing it after CS rises (tSHQZ)
  function output_delay_clqv(flash : flash_t) return delay_length;
  function output_delay_shqz(flash : flash_t) return delay_length;

  -- Handle a message type no handler took, following the unexpected message
  -- type policy of the handle like vc_pkg.unexpected_msg_type of VUnit: a
  -- check failure ``Got unexpected message <name>`` on the checker of the
  -- handle unless the policy is ignore or the message was already handled
  procedure unexpected_msg_type(msg_type : msg_type_t; flash : flash_t);

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

  -- Scattered literals as a vector of whole bytes, leftmost byte at address
  procedure flash_preload(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    data : std_ulogic_vector
  );

  -- Fill num_bytes from address with value. O(1) in num_bytes: the model
  -- stores a run, and only the length crosses to Python.
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

  -- A pending request, redeemed with the matching await procedure
  alias flash_reference_t is msg_t;

  -- Non-blocking: request num_bytes of content from address
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

  -- Blocking read-back of num_bytes from address. The caller owns data and
  -- deallocates it.
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

  -- Compare the content with expected, a vector of whole bytes with the byte
  -- of address leftmost, such as the RAM of a DUT that booted from the flash
  procedure flash_check_content(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    expected : std_ulogic_vector
  );

  -- Compare num_bytes of content from address with the constant value in
  -- Python, without an expected array; 16#FF#, erased, by default. A mismatch
  -- is a check failure on the checker of the device naming the first
  -- differing address.
  procedure flash_check_content_fill(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    value : natural range 0 to 255 := 16#FF#
  );

  -- Blocking: the regions the controller programmed or erased over the bus,
  -- coalesced, as a flat [address, length, address, length, ...]. Preloads
  -- and images are not included. The caller owns regions.
  procedure flash_get_written_regions(
    signal net : inout network_t;
    flash : flash_t;
    variable regions : out integer_array_t
  );

  -- Non-blocking: request the written regions
  procedure flash_get_written_regions(
    signal net : inout network_t;
    flash : flash_t;
    variable reference : inout flash_reference_t
  );

  -- Blocking: redeem a reference of
  -- :vhdl:`flash_pkg.flash_get_written_regions`. The caller owns regions.
  procedure await_flash_get_written_regions_reply(
    signal net : inout network_t;
    variable reference : inout flash_reference_t;
    variable regions : out integer_array_t
  );

  ---------------------------------------------------------------------------
  -- Configuration
  ---------------------------------------------------------------------------

  -- Switch the busy times on (the default) or off. false makes every busy
  -- time 0 and ends a busy period that is running, also for
  -- :vhdl:`flash_pkg.flash_wait_until_ready`.
  procedure flash_set_timing_enable(
    signal net : inout network_t;
    flash : flash_t;
    enable : boolean := true
  );

  -- Override one busy time: "tPP", "tSE", "tBE32", "tBE64", "tCE", "tW",
  -- "tRST", "tRES1" or "tRES2". Another name is a failure on the logger of
  -- the device.
  procedure flash_set_timing(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    duration : delay_length
  );

  -- Lock (the default) or unlock num_bytes from address. A program or erase touching a
  -- locked region is ignored, as by a real part. Preloads are not affected,
  -- and the locks survive a reset.
  procedure flash_set_protection(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    locked : boolean := true
  );

  -- Block until a busy time the device has started is over. The default
  -- timeout is longer than the default chip erase (t_ce); a request that
  -- times out is a failure. A controller polling the status register over
  -- the bus is the stronger check.
  procedure flash_wait_until_ready(
    signal net : inout network_t;
    flash : flash_t;
    timeout : delay_length := 1 min
  );

  -- Blocking: return the flash to standby, as a power-on reset of its
  -- volatile state. The status registers, write enable, addressing and QPI
  -- mode, continuous read and deep power-down return to their defaults, and a
  -- busy period ends, so :vhdl:`flash_pkg.flash_wait_until_ready` returns at
  -- once. A transaction in progress is dropped: the flash ignores the rest of
  -- that CS low period, and the next CS fall starts a command normally. The
  -- content and the regions locked with flash_set_protection are kept. The
  -- statistics and the written regions are kept too, unless
  -- clear_statistics, which sets every counter to 0 and forgets the written
  -- regions.
  procedure reset(
    signal net : inout network_t;
    flash : flash_t;
    clear_statistics : boolean := false
  );

  -- Blocking: a counter or piece of state of the model, for example
  -- "program_count", "erase_count", "ignored_command_count", "abort_count",
  -- "wip", "addr_bytes". An unknown name, or a value that does not fit an
  -- integer, is reported on the logger of the device and returns 0.
  procedure flash_get_stat(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    variable value : out integer
  );

  -- Non-blocking: request a counter or piece of state of the model
  procedure flash_get_stat(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    variable reference : inout flash_reference_t
  );

  -- Blocking: redeem a reference of :vhdl:`flash_pkg.flash_get_stat`
  procedure await_flash_get_stat_reply(
    signal net : inout network_t;
    variable reference : inout flash_reference_t;
    variable value : out integer
  );

  ---------------------------------------------------------------------------
  -- Protocol checks
  ---------------------------------------------------------------------------

  -- :vhdl:`qspi_protocol_checker_pkg.set_check_enabled` for the protocol
  -- checker of the flash. A flash without a protocol checker reports
  -- ``<id> has no protocol checker`` as a check failure on its checker.
  procedure set_check_enabled(
    signal net : inout network_t;
    flash : flash_t;
    check : qspi_check_t;
    enabled : boolean := true
  );

  -- Blocking: :vhdl:`qspi_protocol_checker_pkg.get_check_count` for the
  -- protocol checker of the flash. A flash without a protocol checker reports
  -- ``<id> has no protocol checker`` as a check failure on its checker, and
  -- count is 0.
  procedure get_check_count(
    signal net : inout network_t;
    flash : flash_t;
    check : qspi_check_t;
    variable count : out natural
  );

  -- Non-blocking: request the violation count of a rule of the protocol
  -- checker of the flash, redeemed with
  -- :vhdl:`qspi_protocol_checker_pkg.await_get_check_count_reply`. A flash
  -- without a protocol checker reports ``<id> has no protocol checker`` as a
  -- check failure on its checker, and reference is then null_msg, which is
  -- not to be awaited.
  procedure get_check_count(
    signal net : inout network_t;
    flash : flash_t;
    check : qspi_check_t;
    variable reference : inout qspi_protocol_checker_reference_t
  );

  ---------------------------------------------------------------------------
  -- The packed directive, see awesome_vunit_vcs/flash/directive.py
  ---------------------------------------------------------------------------

  -- The version of the directive layout. Bumped whenever the layout below
  -- changes, and compared with LAYOUT_VERSION of the backend when the
  -- component starts.
  constant flash_layout_version : natural := 1;

  -- Private, for the component. What the component does next. Every field
  -- of a directive describes the same, next action.
  type flash_action_t is (receive, transmit, ignore_rest);

  -- Private, for the component. A directive unpacked by decode_directive.
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

  -- Private, for the component. The bit position and width of each field.
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

  -- Private, for the component. The layout occupies bits 0 to 29: a VHDL
  -- integer is signed 32-bit.
  constant dir_packed_max : natural := 2 ** 30 - 1;

  -- Private, for the component. Bit index of the volatile flag within the
  -- flags field.
  constant dir_flag_volatile : natural := 0;

  -- Private, for the component. Unpack a directive returned by the backend.
  -- A value outside the layout is a failure.
  function decode_directive(packed : integer) return flash_directive_t;

  ---------------------------------------------------------------------------
  -- Message types
  ---------------------------------------------------------------------------

  -- The message types the procedures above send to the component
  constant preload_flash_content_msg : msg_type_t := new_msg_type("preload flash content");
  constant fill_flash_content_msg : msg_type_t := new_msg_type("fill flash content");
  constant load_flash_image_msg : msg_type_t := new_msg_type("load flash image");
  constant read_flash_content_msg : msg_type_t := new_msg_type("read flash content");
  constant read_flash_content_reply_msg : msg_type_t := new_msg_type("read flash content reply");
  constant check_flash_content_msg : msg_type_t := new_msg_type("check flash content");
  constant check_flash_content_fill_msg : msg_type_t := new_msg_type("check flash content fill");
  constant get_flash_written_regions_msg : msg_type_t := new_msg_type("get flash written regions");
  constant get_flash_written_regions_reply_msg : msg_type_t := new_msg_type("get flash written regions reply");
  constant set_flash_timing_enable_msg : msg_type_t := new_msg_type("set flash timing enable");
  constant set_flash_timing_msg : msg_type_t := new_msg_type("set flash timing");
  constant set_flash_protection_msg : msg_type_t := new_msg_type("set flash protection");
  constant wait_until_flash_ready_msg : msg_type_t := new_msg_type("wait until flash ready");
  constant wait_until_flash_ready_reply_msg : msg_type_t := new_msg_type("wait until flash ready reply");
  constant reset_flash_msg : msg_type_t := new_msg_type("reset flash");
  constant reset_flash_reply_msg : msg_type_t := new_msg_type("reset flash reply");
  constant get_flash_stat_msg : msg_type_t := new_msg_type("get flash stat");
  constant get_flash_stat_reply_msg : msg_type_t := new_msg_type("get flash stat reply");

  ---------------------------------------------------------------------------
  -- Private, for the component
  ---------------------------------------------------------------------------

  -- Private. The Python module and class of the backend.
  constant flash_backend_module : string := "awesome_vunit_vcs.flash.vunit_backend";
  constant flash_backend_class : string := "FlashBackend";

  -- Private. The Python session of a flash, identified by its id. Two flashes
  -- with the same id would share one Python backend, which is a failure on
  -- the logger of the flash.
  impure function new_vc_session(flash : flash_t) return python_session_t;

  -- Private. The constructor arguments of the backend.
  impure function backend_arguments(flash : flash_t) return string;

  -- Private. A time as the two Python arguments "hi, lo", with
  -- ``t = hi * 2**30 fs + lo fs``, the convention of vcs_python_pkg and
  -- awesome_vunit_vcs.common.vunit_bridge.
  function python_time_arguments(value : time) return string;

  -- Private. The time of hi and lo returned by Python.
  function from_python_time(hi : natural; lo : natural) return time;

  -- Private. The logger and checker of errors in new_flash, such as an id
  -- that already has an actor.
  constant flash_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:flash_pkg");
  constant flash_pkg_checker : checker_t := new_checker(flash_pkg_logger);
end package;

package body flash_pkg is
  constant time_split : time := 1073741824 fs;

  -- The full names of the ids with a Python session. The guard mirrors
  -- new_vc_session of ethernet_vc_pkg and should move to
  -- common/vcs_python_pkg, a follow-up for the maintainer.
  constant vc_sessions : dict_t := new_dict;

  impure function new_vc_session(flash : flash_t) return python_session_t is
    constant name : string := full_name(flash.p_id);
  begin
    if has_key(vc_sessions, name) then
      failure(
        flash.p_logger,
        "Two verification components have the id " & name & " and would share one Python backend"
      );
    else
      set_string(vc_sessions, name, "");
    end if;
    return new_vc_session(flash.p_id);
  end;

  impure function new_flash(
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
    t_clqv : delay_length := 6 ns;
    t_shqz : delay_length := 6 ns;
    protocol_checker : qspi_protocol_checker_t := null_qspi_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return flash_t is
    variable result : flash_t := (
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
      p_t_clqv => t_clqv,
      p_t_shqz => t_shqz,
      p_protocol_checker => null_qspi_protocol_checker,
      p_id => id,
      p_logger => logger,
      p_actor => actor,
      p_checker => checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy
    );
  begin
    if id = null_id then
      result.p_id := enumerate(get_id("flash", parent => get_id("awesome_vunit_vcs")));
    end if;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;
    if actor = null_actor then
      result.p_actor := new_vc_actor(result.p_id, flash_pkg_checker);
    end if;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;
    result.p_protocol_checker := get_valid_protocol_checker(protocol_checker, result.p_id);

    return result;
  end;

  impure function get_id(flash : flash_t) return id_t is
  begin
    return flash.p_id;
  end;

  impure function get_logger(flash : flash_t) return logger_t is
  begin
    return flash.p_logger;
  end;

  impure function get_actor(flash : flash_t) return actor_t is
  begin
    return flash.p_actor;
  end;

  impure function get_checker(flash : flash_t) return checker_t is
  begin
    return flash.p_checker;
  end;

  impure function as_sync(flash : flash_t) return sync_handle_t is
  begin
    return flash.p_actor;
  end;

  function protocol_checker(flash : flash_t) return qspi_protocol_checker_t is
  begin
    return flash.p_protocol_checker;
  end;

  function output_delay_clqv(flash : flash_t) return delay_length is
  begin
    return flash.p_t_clqv;
  end;

  function output_delay_shqz(flash : flash_t) return delay_length is
  begin
    return flash.p_t_shqz;
  end;

  procedure unexpected_msg_type(msg_type : msg_type_t; flash : flash_t) is
  begin
    if is_already_handled(msg_type) or flash.p_unexpected_msg_type_policy = ignore then
      null;
    else
      check_failed(flash.p_checker, "Got unexpected message " & name(msg_type));
    end if;
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
    variable msg : msg_t := new_msg(preload_flash_content_msg);
    -- push_integer_array_t_ref takes ownership, so the message carries a copy
    -- and the caller keeps data. The component deallocates the copy.
    variable owned : integer_array_t := copy(data);
  begin
    push(msg, address);
    push_integer_array_t_ref(msg, owned);
    send(net, get_actor(flash), msg);
  end;

  -- A vector of whole bytes as a byte array, leftmost byte first. The caller
  -- owns the result.
  impure function to_byte_array(data : std_ulogic_vector; procedure_name : string) return integer_array_t is
    constant num_bytes : natural := data'length / 8;
    alias bits : std_ulogic_vector(0 to data'length - 1) is data;
    variable bytes : integer_array_t := new_1d(length => num_bytes, bit_width => 8, is_signed => false);
  begin
    assert data'length mod 8 = 0
      report procedure_name & ": vector length " & integer'image(data'length) & " is not a whole number of bytes"
      severity failure;

    for idx in 0 to num_bytes - 1 loop
      set(bytes, idx, to_integer(unsigned(bits(8 * idx to 8 * idx + 7))));
    end loop;

    return bytes;
  end;

  procedure flash_preload(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    data : std_ulogic_vector
  ) is
    variable bytes : integer_array_t := to_byte_array(data, "flash_preload");
  begin
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
    variable msg : msg_t := new_msg(fill_flash_content_msg);
  begin
    push(msg, address);
    push(msg, num_bytes);
    push(msg, value);
    send(net, get_actor(flash), msg);
  end;

  procedure flash_load_image(
    signal net : inout network_t;
    flash : flash_t;
    file_name : string;
    format : string := "auto";
    base_address : natural := 0
  ) is
    variable msg : msg_t := new_msg(load_flash_image_msg);
  begin
    push_string(msg, file_name);
    push_string(msg, format);
    push(msg, base_address);
    send(net, get_actor(flash), msg);
  end;

  procedure flash_read_back(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    variable reference : inout flash_reference_t
  ) is
  begin
    reference := new_msg(read_flash_content_msg);
    push(reference, address);
    push(reference, num_bytes);
    send(net, get_actor(flash), reference);
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
    variable msg : msg_t := new_msg(check_flash_content_msg);
    -- A copy, as in flash_preload
    variable owned : integer_array_t := copy(expected);
  begin
    push(msg, address);
    push_integer_array_t_ref(msg, owned);
    send(net, get_actor(flash), msg);
  end;

  procedure flash_check_content(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    expected : std_ulogic_vector
  ) is
    variable bytes : integer_array_t := to_byte_array(expected, "flash_check_content");
  begin
    flash_check_content(net, flash, address, bytes);
    deallocate(bytes);
  end;

  procedure flash_check_content_fill(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    value : natural range 0 to 255 := 16#FF#
  ) is
    variable msg : msg_t := new_msg(check_flash_content_fill_msg);
  begin
    push(msg, address);
    push(msg, num_bytes);
    push(msg, value);
    send(net, get_actor(flash), msg);
  end;

  procedure flash_get_written_regions(
    signal net : inout network_t;
    flash : flash_t;
    variable reference : inout flash_reference_t
  ) is
  begin
    reference := new_msg(get_flash_written_regions_msg);
    send(net, get_actor(flash), reference);
  end;

  procedure await_flash_get_written_regions_reply(
    signal net : inout network_t;
    variable reference : inout flash_reference_t;
    variable regions : out integer_array_t
  ) is
    variable reply_msg : msg_t;
  begin
    receive_reply(net, reference, reply_msg);
    regions := pop_integer_array_t_ref(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure flash_get_written_regions(
    signal net : inout network_t;
    flash : flash_t;
    variable regions : out integer_array_t
  ) is
    variable reference : flash_reference_t;
  begin
    flash_get_written_regions(net, flash, reference);
    await_flash_get_written_regions_reply(net, reference, regions);
  end;

  procedure flash_set_timing_enable(
    signal net : inout network_t;
    flash : flash_t;
    enable : boolean := true
  ) is
    variable msg : msg_t := new_msg(set_flash_timing_enable_msg);
  begin
    push(msg, enable);
    send(net, get_actor(flash), msg);
  end;

  procedure flash_set_timing(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    duration : delay_length
  ) is
    variable msg : msg_t := new_msg(set_flash_timing_msg);
  begin
    push_string(msg, name);
    push_time(msg, duration);
    send(net, get_actor(flash), msg);
  end;

  procedure flash_set_protection(
    signal net : inout network_t;
    flash : flash_t;
    address : natural;
    num_bytes : positive;
    locked : boolean := true
  ) is
    variable msg : msg_t := new_msg(set_flash_protection_msg);
  begin
    push(msg, address);
    push(msg, num_bytes);
    push(msg, locked);
    send(net, get_actor(flash), msg);
  end;

  procedure flash_wait_until_ready(
    signal net : inout network_t;
    flash : flash_t;
    timeout : delay_length := 1 min
  ) is
    variable request_msg : msg_t := new_msg(wait_until_flash_ready_msg);
    variable reply_msg : msg_t;
  begin
    -- A timeout is a check failure of com
    request(net, get_actor(flash), request_msg, reply_msg, timeout => timeout);
    delete(reply_msg);
  end;

  procedure reset(
    signal net : inout network_t;
    flash : flash_t;
    clear_statistics : boolean := false
  ) is
    variable request_msg : msg_t := new_msg(reset_flash_msg);
    variable reply_msg : msg_t;
  begin
    push(request_msg, clear_statistics);
    -- Blocking, so the first stimulus of a test cannot race the reset
    request(net, get_actor(flash), request_msg, reply_msg);
    delete(reply_msg);
  end;

  procedure flash_get_stat(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    variable reference : inout flash_reference_t
  ) is
  begin
    reference := new_msg(get_flash_stat_msg);
    push_string(reference, name);
    send(net, get_actor(flash), reference);
  end;

  procedure await_flash_get_stat_reply(
    signal net : inout network_t;
    variable reference : inout flash_reference_t;
    variable value : out integer
  ) is
    variable reply_msg : msg_t;
  begin
    receive_reply(net, reference, reply_msg);
    value := pop_integer(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure flash_get_stat(
    signal net : inout network_t;
    flash : flash_t;
    name : string;
    variable value : out integer
  ) is
    variable reference : flash_reference_t;
  begin
    flash_get_stat(net, flash, name, reference);
    await_flash_get_stat_reply(net, reference, value);
  end;

  -- Whether the flash has a protocol checker, after a check failure when not
  impure function has_protocol_checker(flash : flash_t) return boolean is
  begin
    if flash.p_protocol_checker = null_qspi_protocol_checker then
      check_failed(flash.p_checker, full_name(flash.p_id) & " has no protocol checker");
      return false;
    end if;
    return true;
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    flash : flash_t;
    check : qspi_check_t;
    enabled : boolean := true
  ) is
  begin
    if has_protocol_checker(flash) then
      set_check_enabled(net, flash.p_protocol_checker, check, enabled);
    end if;
  end;

  procedure get_check_count(
    signal net : inout network_t;
    flash : flash_t;
    check : qspi_check_t;
    variable count : out natural
  ) is
  begin
    if has_protocol_checker(flash) then
      get_check_count(net, flash.p_protocol_checker, check, count);
    else
      count := 0;
    end if;
  end;

  procedure get_check_count(
    signal net : inout network_t;
    flash : flash_t;
    check : qspi_check_t;
    variable reference : inout qspi_protocol_checker_reference_t
  ) is
  begin
    reference := null_msg;
    if has_protocol_checker(flash) then
      get_check_count(net, flash.p_protocol_checker, check, reference);
    end if;
  end;
end package body;
