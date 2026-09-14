-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Handles and procedures of the Ethernet verification components. They are
-- the same for every PHY interface: a monitor or source entity (gmii_monitor,
-- gmii_source, ...) only adds the pin timing of its interface.
--
-- VHDL handles simulation semantics and pin timing, Python handles Ethernet
-- verification semantics (awesome_vunit_vcs.ethernet). A test controls the
-- components with the procedures below and never needs to write Python.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.textio.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

use work.vcs_python_pkg.py_bool;
use work.vcs_python_pkg.py_str;

package ethernet_pkg is
  -- The PHY interfaces with a VHDL frontend. The image of a value names the
  -- Python PHY decoder.
  type ethernet_phy_t is (gmii, xgmii);

  -- Protocol checks, named like the check IDs of the Python checker
  type ethernet_check_t is (
    eth_preamble,
    eth_sfd,
    eth_fcs,
    eth_runt,
    eth_giant,
    eth_phy_error,
    eth_carrier,
    eth_ifg,
    eth_termination,
    eth_metavalue,
    eth_frame_state,
    eth_control,
    eth_link_fault,
    eth_scoreboard
  );

  -- What a source appends to the frame data
  type ethernet_fcs_mode_t is (
    -- Pad (when enabled) and append the correct FCS
    fcs_append,
    -- Pad (when enabled) and append the inverted FCS
    fcs_bad,
    -- Nothing: the data already ends with an FCS or deliberately has none
    fcs_none
  );

  -- Statistics of a monitor. Octet counts saturate at integer'high and a
  -- minimum/maximum without a value is -1.
  type ethernet_statistics_t is record
    total_frames : natural;
    good_frames : natural;
    bad_frames : natural;
    wire_octets : natural;
    payload_octets : natural;
    fcs_errors : natural;
    phy_error_frames : natural;
    runts : natural;
    giants : natural;
    min_frame_octets : integer;
    max_frame_octets : integer;
    min_ifg_octets : integer;
    max_ifg_octets : integer;
  end record;

  type ethernet_monitor_t is record
    -- Private
    p_std_cfg : std_cfg_t;
    p_phy : ethernet_phy_t;
    p_link_rate_mbps : positive;
    p_lanes : positive;
    p_both_edges : boolean;
    p_allow_lane4_start : boolean;
    p_min_preamble_octets : natural;
    p_max_preamble_octets : natural;
    p_min_frame_octets : natural;
    p_max_frame_octets : natural;
    p_min_ifg_octets : natural;
    p_has_fcs : boolean;
    p_batch_length : positive;
    p_flush_at_frame_end : boolean;
    p_delta_unit : time;
    p_log_frames : boolean;
  end record;

  type ethernet_source_t is record
    -- Private
    p_std_cfg : std_cfg_t;
    p_phy : ethernet_phy_t;
    p_link_rate_mbps : positive;
    p_lanes : positive;
    p_both_edges : boolean;
    p_deficit_idle : boolean;
  end record;

  constant ethernet_provider : string := "awesome_vunit_vcs";

  -- A passive monitor of one direction of an interface.
  --
  -- The id defaults to awesome_vunit_vcs:<phy>_monitor:<n>. The monitor
  -- reports protocol violations on its checker, other messages on its logger.
  --
  -- link_rate_mbps is the rate of the link (1000 for GMII, 2500 for
  -- overclocked GMII) used for utilization statistics.
  -- The preamble, frame and IFG limits configure the protocol checks. Frame
  -- octets count from the destination address to the FCS; has_fcs = false
  -- is for frames observed without an FCS.
  --
  -- The monitor sends what it samples to Python in batches of up to
  -- batch_length samples, and at the end of every frame when
  -- flush_at_frame_end. Sample times are kept with a resolution of
  -- delta_unit. log_frames logs every received frame at debug level.
  --
  -- lanes, both_edges and allow_lane4_start describe interfaces with several
  -- lanes per clock edge, see xgmii_pkg; one-octet-per-cycle PHYs such as
  -- GMII ignore them.
  impure function new_ethernet_monitor(
    phy : ethernet_phy_t;
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
    lanes : positive := 1;
    both_edges : boolean := false;
    allow_lane4_start : boolean := false;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_monitor_t;

  -- An active source driving one direction of an interface. The id defaults
  -- to awesome_vunit_vcs:<phy>_source:<n>.
  impure function new_ethernet_source(
    phy : ethernet_phy_t;
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
    lanes : positive := 1;
    both_edges : boolean := false;
    deficit_idle : boolean := true;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t;

  impure function get_id(monitor : ethernet_monitor_t) return id_t;
  impure function get_logger(monitor : ethernet_monitor_t) return logger_t;
  impure function get_checker(monitor : ethernet_monitor_t) return checker_t;
  impure function as_sync(monitor : ethernet_monitor_t) return sync_handle_t;

  impure function get_id(source : ethernet_source_t) return id_t;
  impure function get_logger(source : ethernet_source_t) return logger_t;
  impure function as_sync(source : ethernet_source_t) return sync_handle_t;

  -- Python module and class of the backends
  constant ethernet_backend_module : string := "awesome_vunit_vcs.ethernet.vunit_backend";
  constant ethernet_monitor_backend_class : string := "MonitorBackend";
  constant ethernet_source_backend_class : string := "SourceBackend";

  -- Constructor arguments of the Python backends
  impure function backend_arguments(monitor : ethernet_monitor_t) return string;
  impure function backend_arguments(source : ethernet_source_t) return string;

  ---------------------------------------------------------------------------
  -- Monitor
  --
  -- wait_until_idle(net, as_sync(monitor)) returns when the monitor has seen
  -- the end of any frame in progress and Python has processed everything
  -- sampled so far. The procedures that return a value wait for that too.
  ---------------------------------------------------------------------------

  -- Enable or disable one protocol check
  procedure set_check_enabled(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    check : ethernet_check_t;
    enabled : boolean := true
  );

  -- Violations found by a check while it was enabled
  procedure get_check_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    check : ethernet_check_t;
    variable count : out natural
  );

  -- Frames received, good or bad
  procedure get_frame_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable count : out natural
  );

  procedure get_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable statistics : out ethernet_statistics_t
  );

  -- Log a human readable statistics summary on the logger of the monitor
  procedure log_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    log_level : log_level_t := info
  );

  -- Expect the next received frame to be data: the octets from the
  -- destination address up to, not including, the FCS, leftmost octet
  -- first. Differences are check failures (ETH_SCOREBOARD), as are expected
  -- frames not received when the simulation ends.
  procedure expect_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    data : std_ulogic_vector
  );

  -- Write the frames received from now on to a PCAPNG file (Wireshark).
  -- A relative file_name is relative to the directory the simulator runs in;
  -- output_path(runner_cfg) is a good place. The capture has no preamble or
  -- SFD, the FCS when include_fcs and bad frames when include_errored.
  procedure start_capture(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    file_name : string;
    include_fcs : boolean := true;
    include_errored : boolean := true
  );

  -- Close all captures of the monitor. Captures are also closed when the
  -- simulation ends.
  procedure stop_capture(
    signal net : inout network_t;
    monitor : ethernet_monitor_t
  );

  ---------------------------------------------------------------------------
  -- Source
  --
  -- A source transmits frames in the order they are sent, back to back with
  -- the IFG of each frame after it. wait_until_idle(net, as_sync(source))
  -- returns when all frames sent before it are transmitted.
  ---------------------------------------------------------------------------

  constant no_error_offsets : integer_vector(1 to 0) := (others => 0);

  -- Transmit data, the octets from the destination address up to, not
  -- including, the FCS, leftmost octet first.
  --
  -- The arguments may describe traffic the standard forbids: a bad FCS, no
  -- padding, a short or long preamble, a wrong SFD, a short IFG. The error
  -- signal is asserted with the wire octets in error_offsets, where 0 is the
  -- first preamble octet.
  procedure send_ethernet_frame(
    signal net : inout network_t;
    source : ethernet_source_t;
    data : std_ulogic_vector;
    fcs : ethernet_fcs_mode_t := fcs_append;
    pad : boolean := true;
    preamble_octets : natural := 7;
    sfd : std_ulogic_vector(7 downto 0) := x"D5";
    ifg_octets : natural := 12;
    error_offsets : integer_vector := no_error_offsets
  );

  -- Transmit the packet a Scapy expression builds, for example
  -- "Ether(dst='02:00:00:00:00:01')/IP()/UDP(dport=1234)". Needs the scapy
  -- extra of awesome-vunit-vcs.
  procedure send_ethernet_packet(
    signal net : inout network_t;
    source : ethernet_source_t;
    scapy_expression : string;
    fcs : ethernet_fcs_mode_t := fcs_append;
    pad : boolean := true;
    preamble_octets : natural := 7;
    sfd : std_ulogic_vector(7 downto 0) := x"D5";
    ifg_octets : natural := 12;
    error_offsets : integer_vector := no_error_offsets
  );

  -- Message types
  constant ethernet_set_check_enabled_msg : msg_type_t := new_msg_type("ethernet set check enabled");
  constant ethernet_get_check_count_msg : msg_type_t := new_msg_type("ethernet get check count");
  constant ethernet_get_frame_count_msg : msg_type_t := new_msg_type("ethernet get frame count");
  constant ethernet_get_statistics_msg : msg_type_t := new_msg_type("ethernet get statistics");
  constant ethernet_log_statistics_msg : msg_type_t := new_msg_type("ethernet log statistics");
  constant ethernet_expect_frame_msg : msg_type_t := new_msg_type("ethernet expect frame");
  constant ethernet_start_capture_msg : msg_type_t := new_msg_type("ethernet start capture");
  constant ethernet_stop_capture_msg : msg_type_t := new_msg_type("ethernet stop capture");
  constant ethernet_send_frame_msg : msg_type_t := new_msg_type("ethernet send frame");
  constant ethernet_send_packet_msg : msg_type_t := new_msg_type("ethernet send packet");
  constant ethernet_reply_msg : msg_type_t := new_msg_type("ethernet reply");

  -- Private
  -- The frame transmission options of a send message, as Python keyword arguments
  impure function pop_transmit_options(msg : msg_t) return string;
end package;

package body ethernet_pkg is
  impure function new_ethernet_monitor(
    phy : ethernet_phy_t;
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
    lanes : positive := 1;
    both_edges : boolean := false;
    allow_lane4_start : boolean := false;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_monitor_t is
  begin
    return (
      p_std_cfg => create_std_cfg(
        id => id,
        provider => ethernet_provider,
        vc_name => ethernet_phy_t'image(phy) & "_monitor",
        unexpected_msg_type_policy => unexpected_msg_type_policy
      ),
      p_phy => phy,
      p_link_rate_mbps => link_rate_mbps,
      p_lanes => lanes,
      p_both_edges => both_edges,
      p_allow_lane4_start => allow_lane4_start,
      p_min_preamble_octets => min_preamble_octets,
      p_max_preamble_octets => max_preamble_octets,
      p_min_frame_octets => min_frame_octets,
      p_max_frame_octets => max_frame_octets,
      p_min_ifg_octets => min_ifg_octets,
      p_has_fcs => has_fcs,
      p_batch_length => batch_length,
      p_flush_at_frame_end => flush_at_frame_end,
      p_delta_unit => delta_unit,
      p_log_frames => log_frames
    );
  end;

  impure function new_ethernet_source(
    phy : ethernet_phy_t;
    id : id_t := null_id;
    link_rate_mbps : positive := 1000;
    lanes : positive := 1;
    both_edges : boolean := false;
    deficit_idle : boolean := true;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return ethernet_source_t is
  begin
    return (
      p_std_cfg => create_std_cfg(
        id => id,
        provider => ethernet_provider,
        vc_name => ethernet_phy_t'image(phy) & "_source",
        unexpected_msg_type_policy => unexpected_msg_type_policy
      ),
      p_phy => phy,
      p_link_rate_mbps => link_rate_mbps,
      p_lanes => lanes,
      p_both_edges => both_edges,
      p_deficit_idle => deficit_idle
    );
  end;

  impure function get_id(monitor : ethernet_monitor_t) return id_t is
  begin
    return get_id(monitor.p_std_cfg);
  end;

  impure function get_logger(monitor : ethernet_monitor_t) return logger_t is
  begin
    return get_logger(monitor.p_std_cfg);
  end;

  impure function get_checker(monitor : ethernet_monitor_t) return checker_t is
  begin
    return get_checker(monitor.p_std_cfg);
  end;

  impure function as_sync(monitor : ethernet_monitor_t) return sync_handle_t is
  begin
    return get_actor(monitor.p_std_cfg);
  end;

  impure function get_id(source : ethernet_source_t) return id_t is
  begin
    return get_id(source.p_std_cfg);
  end;

  impure function get_logger(source : ethernet_source_t) return logger_t is
  begin
    return get_logger(source.p_std_cfg);
  end;

  impure function as_sync(source : ethernet_source_t) return sync_handle_t is
  begin
    return get_actor(source.p_std_cfg);
  end;

  function link_rate_bps(link_rate_mbps : positive) return string is
  begin
    return integer'image(link_rate_mbps) & "_000_000";
  end;

  -- The options of the Python PHY decoder that the PHY has
  impure function phy_options(monitor : ethernet_monitor_t) return string is
  begin
    if monitor.p_phy = xgmii then
      return
        ", phy_options={'lanes': " & integer'image(monitor.p_lanes) &
        ", 'allow_lane4_start': " & py_bool(monitor.p_allow_lane4_start) & "}";
    end if;
    return "";
  end;

  impure function phy_options(source : ethernet_source_t) return string is
  begin
    if source.p_phy = xgmii then
      return
        ", phy_options={'lanes': " & integer'image(source.p_lanes) &
        ", 'deficit_idle': " & py_bool(source.p_deficit_idle) & "}";
    end if;
    return "";
  end;

  impure function backend_arguments(monitor : ethernet_monitor_t) return string is
  begin
    return
      py_str(full_name(get_id(monitor))) & ", " &
      py_str(ethernet_phy_t'image(monitor.p_phy)) &
      ", link_rate_bps=" & link_rate_bps(monitor.p_link_rate_mbps) &
      ", min_preamble_octets=" & integer'image(monitor.p_min_preamble_octets) &
      ", max_preamble_octets=" & integer'image(monitor.p_max_preamble_octets) &
      ", min_frame_octets=" & integer'image(monitor.p_min_frame_octets) &
      ", max_frame_octets=" & integer'image(monitor.p_max_frame_octets) &
      ", min_ifg_octets=" & integer'image(monitor.p_min_ifg_octets) &
      ", has_fcs=" & py_bool(monitor.p_has_fcs) &
      ", log_frames=" & py_bool(monitor.p_log_frames) &
      phy_options(monitor);
  end;

  impure function backend_arguments(source : ethernet_source_t) return string is
  begin
    return
      py_str(full_name(get_id(source))) & ", " &
      py_str(ethernet_phy_t'image(source.p_phy)) &
      ", link_rate_bps=" & link_rate_bps(source.p_link_rate_mbps) &
      phy_options(source);
  end;

  procedure request_integer(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable msg : inout msg_t;
    variable value : out integer
  ) is
    variable reply_msg : msg_t;
  begin
    request(net, get_actor(monitor.p_std_cfg), msg, reply_msg);
    value := pop(reply_msg);
    delete(reply_msg);
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    check : ethernet_check_t;
    enabled : boolean := true
  ) is
    variable msg : msg_t := new_msg(ethernet_set_check_enabled_msg);
  begin
    push(msg, ethernet_check_t'pos(check));
    push(msg, enabled);
    send(net, get_actor(monitor.p_std_cfg), msg);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    check : ethernet_check_t;
    variable count : out natural
  ) is
    variable msg : msg_t := new_msg(ethernet_get_check_count_msg);
  begin
    push(msg, ethernet_check_t'pos(check));
    request_integer(net, monitor, msg, count);
  end;

  procedure get_frame_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable count : out natural
  ) is
    variable msg : msg_t := new_msg(ethernet_get_frame_count_msg);
  begin
    request_integer(net, monitor, msg, count);
  end;

  procedure get_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable statistics : out ethernet_statistics_t
  ) is
    variable msg : msg_t := new_msg(ethernet_get_statistics_msg);
    variable reply_msg : msg_t;
  begin
    request(net, get_actor(monitor.p_std_cfg), msg, reply_msg);
    statistics.total_frames := pop(reply_msg);
    statistics.good_frames := pop(reply_msg);
    statistics.bad_frames := pop(reply_msg);
    statistics.wire_octets := pop(reply_msg);
    statistics.payload_octets := pop(reply_msg);
    statistics.fcs_errors := pop(reply_msg);
    statistics.phy_error_frames := pop(reply_msg);
    statistics.runts := pop(reply_msg);
    statistics.giants := pop(reply_msg);
    statistics.min_frame_octets := pop(reply_msg);
    statistics.max_frame_octets := pop(reply_msg);
    statistics.min_ifg_octets := pop(reply_msg);
    statistics.max_ifg_octets := pop(reply_msg);
    delete(reply_msg);
  end;

  procedure log_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    log_level : log_level_t := info
  ) is
    variable msg : msg_t := new_msg(ethernet_log_statistics_msg);
  begin
    push(msg, log_level_t'pos(log_level));
    send(net, get_actor(monitor.p_std_cfg), msg);
  end;

  procedure expect_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    data : std_ulogic_vector
  ) is
    variable msg : msg_t := new_msg(ethernet_expect_frame_msg);
  begin
    check(
      get_checker(monitor), data'length mod 8 = 0,
      "Frame data must be whole octets, got " & integer'image(data'length) & " bits"
    );
    push(msg, data);
    send(net, get_actor(monitor.p_std_cfg), msg);
  end;

  procedure start_capture(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    file_name : string;
    include_fcs : boolean := true;
    include_errored : boolean := true
  ) is
    variable msg : msg_t := new_msg(ethernet_start_capture_msg);
  begin
    push(msg, file_name);
    push(msg, include_fcs);
    push(msg, include_errored);
    send(net, get_actor(monitor.p_std_cfg), msg);
  end;

  procedure stop_capture(
    signal net : inout network_t;
    monitor : ethernet_monitor_t
  ) is
    variable msg : msg_t := new_msg(ethernet_stop_capture_msg);
  begin
    send(net, get_actor(monitor.p_std_cfg), msg);
  end;

  procedure push_transmit_options(
    msg : msg_t;
    fcs : ethernet_fcs_mode_t;
    pad : boolean;
    preamble_octets : natural;
    sfd : std_ulogic_vector(7 downto 0);
    ifg_octets : natural;
    error_offsets : integer_vector
  ) is
  begin
    push(msg, ethernet_fcs_mode_t'pos(fcs));
    push(msg, pad);
    push(msg, preamble_octets);
    push(msg, sfd);
    push(msg, ifg_octets);
    push(msg, error_offsets'length);
    for idx in error_offsets'range loop
      push(msg, error_offsets(idx));
    end loop;
  end;

  impure function pop_transmit_options(msg : msg_t) return string is
    constant fcs : ethernet_fcs_mode_t := ethernet_fcs_mode_t'val(integer'(pop(msg)));
    constant pad : boolean := pop(msg);
    constant preamble_octets : natural := pop(msg);
    constant sfd : std_ulogic_vector(7 downto 0) := pop(msg);
    constant ifg_octets : natural := pop(msg);
    constant num_error_offsets : natural := pop(msg);
    variable error_offsets : line;
    constant fcs_image : string := ethernet_fcs_mode_t'image(fcs);
  begin
    write(error_offsets, string'("("));
    for idx in 1 to num_error_offsets loop
      write(error_offsets, integer'image(integer'(pop(msg))) & ",");
    end loop;
    write(error_offsets, string'(")"));

    return
      "fcs=" & py_str(fcs_image(fcs_image'left + 4 to fcs_image'right)) &
      ", pad=" & py_bool(pad) &
      ", preamble_octets=" & integer'image(preamble_octets) &
      ", sfd=" & integer'image(to_integer(unsigned(sfd))) &
      ", ifg_octets=" & integer'image(ifg_octets) &
      ", error_offsets=" & error_offsets.all;
  end;

  procedure send_ethernet_frame(
    signal net : inout network_t;
    source : ethernet_source_t;
    data : std_ulogic_vector;
    fcs : ethernet_fcs_mode_t := fcs_append;
    pad : boolean := true;
    preamble_octets : natural := 7;
    sfd : std_ulogic_vector(7 downto 0) := x"D5";
    ifg_octets : natural := 12;
    error_offsets : integer_vector := no_error_offsets
  ) is
    variable msg : msg_t := new_msg(ethernet_send_frame_msg);
  begin
    check(
      get_checker(source.p_std_cfg), data'length mod 8 = 0,
      "Frame data must be whole octets, got " & integer'image(data'length) & " bits"
    );
    push(msg, data);
    push_transmit_options(msg, fcs, pad, preamble_octets, sfd, ifg_octets, error_offsets);
    send(net, get_actor(source.p_std_cfg), msg);
  end;

  procedure send_ethernet_packet(
    signal net : inout network_t;
    source : ethernet_source_t;
    scapy_expression : string;
    fcs : ethernet_fcs_mode_t := fcs_append;
    pad : boolean := true;
    preamble_octets : natural := 7;
    sfd : std_ulogic_vector(7 downto 0) := x"D5";
    ifg_octets : natural := 12;
    error_offsets : integer_vector := no_error_offsets
  ) is
    variable msg : msg_t := new_msg(ethernet_send_packet_msg);
  begin
    push(msg, scapy_expression);
    push_transmit_options(msg, fcs, pad, preamble_octets, sfd, ifg_octets, error_offsets);
    send(net, get_actor(source.p_std_cfg), msg);
  end;
end package body;
