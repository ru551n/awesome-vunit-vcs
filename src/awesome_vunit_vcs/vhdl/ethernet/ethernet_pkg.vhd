-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The Ethernet verification component interfaces (VCIs) and the types every
-- Ethernet verification component (VC) shares.
--
-- Every PHY interface has its own VCs, created by the constructors of its
-- package (:vhdl:`gmii_pkg.new_gmii_source`, :vhdl:`xgmii_pkg.new_xgmii_monitor`, ...):
-- a source, a monitor and a protocol checker, each with a handle type of its
-- own, as the AXI-Stream VCs of VUnit have. The procedures of this package work
-- on the interface independent VCI handles that ``as_ethernet_source``,
-- ``as_ethernet_monitor`` and ``as_ethernet_protocol_checker`` return; each PHY
-- package has overloads taking its own handles, so a testbench seldom needs
-- the VCI handles. The standard VUnit VCIs are supported too: sources are
-- stream masters (``as_stream``), monitors are stream slaves and every VC
-- implements the synchronization VCI (``as_sync``).
--
-- VHDL handles simulation semantics and pin timing, Python handles Ethernet
-- verification semantics (awesome_vunit_vcs.ethernet). A test controls the
-- VCs with procedures and never needs to write Python.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.textio.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.vc_pkg.all;

use work.vcs_python_pkg.py_bool;
use work.vcs_python_pkg.py_str;

package ethernet_pkg is
  -- The checks of the Ethernet VCs, named like the check IDs of the Python
  -- checker (upper case in log messages). A protocol checker has the protocol
  -- checks, a monitor ``eth_scoreboard``; ``eth_user`` counts the errors
  -- Python code reports with ``vc.error`` on the VC that owns the backend.
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
    eth_scoreboard,
    eth_user
  );

  -- What a source appends to the frame data:
  --
  -- * ``fcs_append``: pad (when enabled) and append the correct FCS
  -- * ``fcs_bad``: pad (when enabled) and append the inverted FCS
  -- * ``fcs_none``: nothing, the data already ends with an FCS or deliberately has none
  type ethernet_fcs_mode_t is (fcs_append, fcs_bad, fcs_none);

  -- Statistics of a monitor. Octet counts saturate at ``integer'high`` and a
  -- minimum or maximum without a value is -1.
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

  ---------------------------------------------------------------------------
  -- Ethernet VCIs
  --
  -- The interface independent handles of Ethernet sources, monitors and
  -- protocol checkers, like ``stream_master_t`` of VUnit. Get them from a VC
  -- handle with ``as_ethernet_source``, ``as_ethernet_monitor`` or
  -- ``as_ethernet_protocol_checker``.
  ---------------------------------------------------------------------------

  -- The Ethernet source VCI: transmits frames
  type ethernet_source_t is record
    -- Private
    p_actor : actor_t;
    p_checker : checker_t;
  end record;

  -- The Ethernet monitor VCI: receives frames
  type ethernet_monitor_t is record
    -- Private
    p_actor : actor_t;
    p_checker : checker_t;
  end record;

  -- The Ethernet protocol checker VCI: checks the traffic of an interface
  type ethernet_protocol_checker_t is record
    -- Private
    p_actor : actor_t;
    p_checker : checker_t;
  end record;

  -- Reference to a future reply of a non-blocking request
  alias ethernet_reference_t is msg_t;

  -- No error offsets
  constant no_error_offsets : integer_vector(1 to 0) := (others => 0);

  -- The most error offsets a frame can have
  constant max_error_offsets : positive := 16;

  -- How a source transmits a frame, created with
  -- :vhdl:`ethernet_pkg.frame_options`
  type ethernet_frame_options_t is record
    -- Private
    p_fcs : ethernet_fcs_mode_t;
    p_pad : boolean;
    p_preamble_octets : natural;
    p_sfd : std_ulogic_vector(7 downto 0);
    p_ifg_octets : natural;
    p_num_error_offsets : natural;
    p_error_offsets : integer_vector(0 to max_error_offsets - 1);
  end record;

  -- The options of a frame the standard allows: correct FCS, padding to the
  -- minimum frame size, 7 preamble octets, the SFD 0xD5 and 12 IFG octets
  impure function frame_options(
    fcs : ethernet_fcs_mode_t := fcs_append;
    pad : boolean := true;
    preamble_octets : natural := 7;
    sfd : std_ulogic_vector(7 downto 0) := x"D5";
    ifg_octets : natural := 12;
    error_offsets : integer_vector := no_error_offsets
  ) return ethernet_frame_options_t;

  -- The options of a frame the standard allows, see
  -- :vhdl:`ethernet_pkg.frame_options`
  constant default_frame_options : ethernet_frame_options_t := (
    p_fcs => fcs_append,
    p_pad => true,
    p_preamble_octets => 7,
    p_sfd => x"D5",
    p_ifg_octets => 12,
    p_num_error_offsets => 0,
    p_error_offsets => (others => 0)
  );

  ---------------------------------------------------------------------------
  -- Source
  --
  -- A source transmits frames in the order they are pushed, back to back with
  -- the IFG of each frame after it. ``wait_until_idle(net, as_sync(source))``
  -- returns when every frame pushed before it is transmitted.
  --
  -- The options may describe traffic the standard forbids: a bad FCS, no
  -- padding, a short or long preamble, a wrong SFD, a short IFG. The error
  -- signal is asserted with the octets in ``error_offsets``, which count like
  -- data and like the offsets ``eth_phy_error`` reports: 0 is the first octet
  -- after the SFD. Negative offsets reach back into the SFD (-1) and the
  -- preamble. Interfaces with control characters send Error instead.
  ---------------------------------------------------------------------------

  -- Non-blocking: transmit data, the octets from the destination address up
  -- to, not including, the FCS, leftmost octet first
  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : ethernet_source_t;
    data : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  );

  -- Non-blocking: transmit a frame given by its header fields and payload.
  -- destination and source are 48 bits, ethertype 16 bits (a length when
  -- below 0x0600).
  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : ethernet_source_t;
    destination : std_ulogic_vector;
    source_address : std_ulogic_vector;
    ethertype : std_ulogic_vector;
    payload : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  );

  -- Non-blocking: transmit the frame a Python function returns: ``function``
  -- is ``"package.module:function"``, ``arguments`` its keyword arguments, for
  -- example ``"port=1234, size=128"``. The function returns the octets from
  -- the destination address up to, not including, the FCS, or anything
  -- ``bytes()`` accepts, such as a Scapy packet.
  procedure push_ethernet_packet(
    signal net : inout network_t;
    source : ethernet_source_t;
    function_name : string;
    arguments : string := "";
    options : ethernet_frame_options_t := default_frame_options
  );

  -- Non-blocking: transmit the frames a Python generator function yields,
  -- given like :vhdl:`ethernet_pkg.push_ethernet_packet`. count frames, or
  -- until the generator is exhausted when count is 0. The frames are fetched
  -- in batches, so a sequence costs few bridge calls. seed is passed to the
  -- function unchanged; the same function, arguments and seed produce the
  -- same frames, for example ``seed => get_string_seed(runner_cfg)``.
  procedure push_ethernet_sequence(
    signal net : inout network_t;
    source : ethernet_source_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  );

  ---------------------------------------------------------------------------
  -- Monitor
  --
  -- A monitor reconstructs the frames of one direction of an interface. It
  -- publishes every frame received while it has subscribers as an
  -- ``ethernet_frame_msg``, and keeps the frames received while a pop is
  -- pending. ``wait_until_idle(net, as_sync(monitor))`` returns when no frame
  -- is in progress, no pop or blocking check is pending and Python has
  -- processed everything sampled so far. The procedures that return a value
  -- wait for Python too.
  ---------------------------------------------------------------------------

  -- Non-blocking: pop the next frame received, to be read with
  -- :vhdl:`ethernet_pkg.await_pop_ethernet_frame_reply`
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable reference : inout ethernet_reference_t
  );

  -- Blocking: wait for the reply to a non-blocking pop. The frame, from the
  -- destination address up to, not including, the FCS, is written to the
  -- leftmost ``8 * length`` bits of data, which must be long enough.
  -- ``fcs_ok`` is false when the FCS of the frame was wrong.
  procedure await_pop_ethernet_frame_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  );
  procedure await_pop_ethernet_frame_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  );

  -- Blocking: pop the next frame received, see
  -- :vhdl:`ethernet_pkg.await_pop_ethernet_frame_reply`
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  );
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  );

  -- Read the frame of an ``ethernet_frame_msg`` a monitor published, or of a
  -- pop reply, like :vhdl:`ethernet_pkg.await_pop_ethernet_frame_reply`
  procedure pop_ethernet_frame(
    msg : msg_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  );

  -- Check that the next frame received is expected: the octets from the
  -- destination address up to, not including, the FCS, leftmost octet first.
  -- A difference, or an expected frame not received when the test ends, is a
  -- check failure (``ETH_SCOREBOARD``) on the checker of the monitor, prefixed
  -- with msg. Blocking returns when the frame is checked, non-blocking at once.
  procedure check_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    expected : std_ulogic_vector;
    msg : string := "";
    blocking : boolean := true
  );

  -- Non-blocking: check that the next frames received are the frames a Python
  -- generator function yields, given like
  -- :vhdl:`ethernet_pkg.push_ethernet_packet`: count frames, or all when count
  -- is 0, which needs a generator that ends. With the function, arguments and
  -- seed of a push_ethernet_sequence it expects exactly those frames.
  -- Differences are check failures like those of
  -- :vhdl:`ethernet_pkg.check_ethernet_frame`.
  procedure check_ethernet_sequence(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  );

  -- Non-blocking: get the statistics, to be read with
  -- :vhdl:`ethernet_pkg.await_get_statistics_reply`
  procedure get_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable reference : inout ethernet_reference_t
  );

  -- Blocking: wait for the reply to a non-blocking get_statistics
  procedure await_get_statistics_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable statistics : out ethernet_statistics_t
  );

  -- Blocking: get the statistics of the monitor
  procedure get_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable statistics : out ethernet_statistics_t
  );

  -- Non-blocking: get the number of frames received, good or bad, to be read
  -- with :vhdl:`ethernet_pkg.await_get_frame_count_reply`
  procedure get_frame_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable reference : inout ethernet_reference_t
  );

  -- Blocking: wait for the reply to a non-blocking get_frame_count
  procedure await_get_frame_count_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable count : out natural
  );

  -- Blocking: get the number of frames received, good or bad
  procedure get_frame_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable count : out natural
  );

  -- Log a human readable statistics summary on the logger of the monitor
  procedure log_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    log_level : log_level_t := info
  );

  -- Write the frames received from now on to a PCAPNG file (Wireshark). A
  -- relative ``file_name`` is relative to the directory the simulator runs in;
  -- ``output_path(runner_cfg)`` is a good place. The capture has no preamble
  -- or SFD, the FCS when ``include_fcs`` and bad frames when ``include_errored``.
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
  -- Protocol checker
  --
  -- A protocol checker reports every violation of an enabled check as a check
  -- failure on its checker. ``wait_until_idle(net, as_sync(protocol_checker))``
  -- returns when no frame is in progress and Python has checked everything
  -- sampled so far.
  ---------------------------------------------------------------------------

  -- Enable or disable one protocol check
  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : ethernet_protocol_checker_t;
    check : ethernet_check_t;
    enabled : boolean := true
  );

  -- Non-blocking: get the number of violations a check found while enabled,
  -- to be read with :vhdl:`ethernet_pkg.await_get_check_count_reply`
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : ethernet_protocol_checker_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  );

  -- Blocking: wait for the reply to a non-blocking get_check_count
  procedure await_get_check_count_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable count : out natural
  );

  -- Blocking: get the number of violations a check found while enabled
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : ethernet_protocol_checker_t;
    check : ethernet_check_t;
    variable count : out natural
  );

  -- Message types of the Ethernet VCIs. A request with a reply has a
  -- ``*_reply_msg`` type for the reply. A monitor publishes
  -- ``ethernet_frame_msg``.
  constant push_ethernet_frame_msg : msg_type_t := new_msg_type("push ethernet frame");
  constant push_ethernet_packet_msg : msg_type_t := new_msg_type("push ethernet packet");
  constant push_ethernet_sequence_msg : msg_type_t := new_msg_type("push ethernet sequence");
  constant pop_ethernet_frame_msg : msg_type_t := new_msg_type("pop ethernet frame");
  constant pop_ethernet_frame_reply_msg : msg_type_t := new_msg_type("pop ethernet frame reply");
  constant check_ethernet_frame_msg : msg_type_t := new_msg_type("check ethernet frame");
  constant check_ethernet_frame_reply_msg : msg_type_t := new_msg_type("check ethernet frame reply");
  constant check_ethernet_sequence_msg : msg_type_t := new_msg_type("check ethernet sequence");
  constant get_ethernet_statistics_msg : msg_type_t := new_msg_type("get ethernet statistics");
  constant get_ethernet_statistics_reply_msg : msg_type_t := new_msg_type("get ethernet statistics reply");
  constant get_ethernet_frame_count_msg : msg_type_t := new_msg_type("get ethernet frame count");
  constant get_ethernet_frame_count_reply_msg : msg_type_t := new_msg_type("get ethernet frame count reply");
  constant log_ethernet_statistics_msg : msg_type_t := new_msg_type("log ethernet statistics");
  constant start_ethernet_capture_msg : msg_type_t := new_msg_type("start ethernet capture");
  constant stop_ethernet_capture_msg : msg_type_t := new_msg_type("stop ethernet capture");
  constant set_ethernet_check_enabled_msg : msg_type_t := new_msg_type("set ethernet check enabled");
  constant get_ethernet_check_count_msg : msg_type_t := new_msg_type("get ethernet check count");
  constant get_ethernet_check_count_reply_msg : msg_type_t := new_msg_type("get ethernet check count reply");
  constant ethernet_frame_msg : msg_type_t := new_msg_type("ethernet frame");

  ---------------------------------------------------------------------------
  -- Private
  --
  -- For the PHY packages and the VC entities. Testbenches do not use these.
  ---------------------------------------------------------------------------

  -- Private: the PHY interfaces with a VHDL frontend. The image of a value
  -- names the Python PHY decoder.
  type ethernet_interface_t is (gmii, xgmii, mii);

  -- Private: the kinds of Ethernet VC
  type ethernet_vc_kind_t is (source_vc, monitor_vc, protocol_checker_vc);

  -- Private: whether a sub-VC handle, such as the protocol checker of a
  -- monitor, is absent, to be created by the parent VC, or created by the user
  type ethernet_component_type_t is (null_ethernet_component, default_ethernet_component, custom_ethernet_component);

  -- Private: the configuration of an Ethernet VC. A VC uses the fields that
  -- apply to its kind and interface.
  type ethernet_cfg_t is record
    p_interface : ethernet_interface_t;
    p_link_rate_mbps : positive;
    p_lanes : positive;
    p_both_edges : boolean;
    p_allow_lane4_start : boolean;
    p_deficit_idle : boolean;
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

  -- Private: the configuration of null handles
  constant null_ethernet_cfg : ethernet_cfg_t := (
    p_interface => gmii,
    p_link_rate_mbps => 1,
    p_lanes => 1,
    p_both_edges => false,
    p_allow_lane4_start => false,
    p_deficit_idle => false,
    p_min_preamble_octets => 0,
    p_max_preamble_octets => 0,
    p_min_frame_octets => 0,
    p_max_frame_octets => 0,
    p_min_ifg_octets => 0,
    p_has_fcs => true,
    p_batch_length => 1,
    p_flush_at_frame_end => true,
    p_delta_unit => 1 ps,
    p_log_frames => false
  );

  -- Private: create a configuration
  impure function new_ethernet_cfg(
    interface : ethernet_interface_t;
    link_rate_mbps : positive;
    lanes : positive := 1;
    both_edges : boolean := false;
    allow_lane4_start : boolean := false;
    deficit_idle : boolean := true;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false
  ) return ethernet_cfg_t;

  -- Private: the id, logger, actor and checker of a VC, and which of them the
  -- user gave
  type ethernet_identity_t is record
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_explicit_logger : boolean;
    p_explicit_actor : boolean;
    p_explicit_checker : boolean;
  end record;

  -- Private: resolve the identity of a VC the way vc_pkg.create_std_cfg of VUnit
  -- does. A null id becomes awesome_vunit_vcs:<vc_name>:<n>, n counting the
  -- instances from 1. A null logger becomes the logger of the id, a null actor
  -- a new actor of the id, which must not have an actor already, and a null
  -- checker a new checker reporting to the logger.
  impure function new_ethernet_identity(
    vc_name : string;
    id : id_t;
    logger : logger_t;
    actor : actor_t;
    checker : checker_t
  ) return ethernet_identity_t;

  -- Private: the identity of a sub-VC of the VC with id parent, such as its
  -- protocol checker. Its id is <parent>:<name>; the logger, actor and checker
  -- derive from that id unless the user gave them.
  impure function inherit_ethernet_identity(
    identity : ethernet_identity_t;
    name : string;
    parent : id_t
  ) return ethernet_identity_t;

  -- Private: the VC an entity implements, independent of the PHY handle types
  type ethernet_vc_t is record
    p_kind : ethernet_vc_kind_t;
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    p_cfg : ethernet_cfg_t;
  end record;

  -- Private: the frame transmission options of a push message, as Python
  -- keyword arguments
  impure function pop_transmit_options(msg : msg_t) return string;
end package;

package body ethernet_pkg is
  -- Reports errors of the constructors, like vc_pkg_checker of VUnit
  constant ethernet_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:ethernet_pkg");
  constant ethernet_pkg_checker : checker_t := new_checker(ethernet_pkg_logger);

  impure function new_ethernet_cfg(
    interface : ethernet_interface_t;
    link_rate_mbps : positive;
    lanes : positive := 1;
    both_edges : boolean := false;
    allow_lane4_start : boolean := false;
    deficit_idle : boolean := true;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false
  ) return ethernet_cfg_t is
  begin
    return (
      p_interface => interface,
      p_link_rate_mbps => link_rate_mbps,
      p_lanes => lanes,
      p_both_edges => both_edges,
      p_allow_lane4_start => allow_lane4_start,
      p_deficit_idle => deficit_idle,
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

  -- The actor of a VC with a derived identity: a new actor for id, which must
  -- not have one (vc_pkg.vhd, create_std_cfg)
  impure function new_vc_actor(id : id_t) return actor_t is
  begin
    if find(id, enable_deferred_creation => false) /= null_actor then
      check_failed(ethernet_pkg_checker, "An actor already exists for " & full_name(id) & ".");
      return null_actor;
    end if;
    return new_actor(id);
  end;

  impure function resolve_identity(
    id : id_t;
    logger : logger_t;
    actor : actor_t;
    checker : checker_t;
    explicit_logger : boolean;
    explicit_actor : boolean;
    explicit_checker : boolean
  ) return ethernet_identity_t is
    variable result : ethernet_identity_t;
  begin
    result.p_id := id;
    result.p_explicit_logger := explicit_logger;
    result.p_explicit_actor := explicit_actor;
    result.p_explicit_checker := explicit_checker;
    if explicit_logger then
      result.p_logger := logger;
    else
      result.p_logger := get_logger(id);
    end if;
    if explicit_actor then
      result.p_actor := actor;
    else
      result.p_actor := new_vc_actor(id);
    end if;
    if explicit_checker then
      result.p_checker := checker;
    else
      result.p_checker := new_checker(result.p_logger);
    end if;
    return result;
  end;

  impure function new_ethernet_identity(
    vc_name : string;
    id : id_t;
    logger : logger_t;
    actor : actor_t;
    checker : checker_t
  ) return ethernet_identity_t is
    variable instance_id : id_t := id;
  begin
    if id = null_id then
      instance_id := enumerate(get_id(vc_name, parent => get_id("awesome_vunit_vcs")));
    end if;
    return resolve_identity(
      instance_id, logger, actor, checker,
      explicit_logger => logger /= null_logger,
      explicit_actor => actor /= null_actor,
      explicit_checker => checker /= null_checker
    );
  end;

  impure function inherit_ethernet_identity(
    identity : ethernet_identity_t;
    name : string;
    parent : id_t
  ) return ethernet_identity_t is
  begin
    return resolve_identity(
      get_id(name, parent => parent),
      identity.p_logger, identity.p_actor, identity.p_checker,
      identity.p_explicit_logger, identity.p_explicit_actor, identity.p_explicit_checker
    );
  end;

  procedure check_whole_octets(checker : checker_t; data : std_ulogic_vector) is
  begin
    check(
      checker, data'length mod 8 = 0,
      "Frame data must be whole octets, got " & integer'image(data'length) & " bits"
    );
  end;

  impure function frame_options(
    fcs : ethernet_fcs_mode_t := fcs_append;
    pad : boolean := true;
    preamble_octets : natural := 7;
    sfd : std_ulogic_vector(7 downto 0) := x"D5";
    ifg_octets : natural := 12;
    error_offsets : integer_vector := no_error_offsets
  ) return ethernet_frame_options_t is
    alias offsets : integer_vector(0 to error_offsets'length - 1) is error_offsets;
    variable result : ethernet_frame_options_t := (
      p_fcs => fcs,
      p_pad => pad,
      p_preamble_octets => preamble_octets,
      p_sfd => sfd,
      p_ifg_octets => ifg_octets,
      p_num_error_offsets => 0,
      p_error_offsets => (others => 0)
    );
  begin
    if error_offsets'length > max_error_offsets then
      failure(
        ethernet_pkg_logger,
        "A frame has at most " & integer'image(max_error_offsets) & " error offsets, got " &
        integer'image(error_offsets'length)
      );
      return result;
    end if;
    result.p_num_error_offsets := error_offsets'length;
    for idx in offsets'range loop
      result.p_error_offsets(idx) := offsets(idx);
    end loop;
    return result;
  end;

  procedure push_transmit_options(msg : msg_t; options : ethernet_frame_options_t) is
  begin
    push(msg, ethernet_fcs_mode_t'pos(options.p_fcs));
    push(msg, options.p_pad);
    push(msg, options.p_preamble_octets);
    push(msg, options.p_sfd);
    push(msg, options.p_ifg_octets);
    push(msg, options.p_num_error_offsets);
    for idx in 0 to options.p_num_error_offsets - 1 loop
      push(msg, options.p_error_offsets(idx));
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

  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : ethernet_source_t;
    data : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  ) is
    variable msg : msg_t := new_msg(push_ethernet_frame_msg);
  begin
    check_whole_octets(source.p_checker, data);
    push(msg, data);
    push_transmit_options(msg, options);
    send(net, source.p_actor, msg);
  end;

  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : ethernet_source_t;
    destination : std_ulogic_vector;
    source_address : std_ulogic_vector;
    ethertype : std_ulogic_vector;
    payload : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  ) is
  begin
    check(
      source.p_checker, destination'length = 48 and source_address'length = 48 and ethertype'length = 16,
      "The destination and source addresses are 48 bits and the EtherType 16 bits, got " &
      integer'image(destination'length) & ", " & integer'image(source_address'length) & " and " &
      integer'image(ethertype'length) & " bits"
    );
    push_ethernet_frame(net, source, destination & source_address & ethertype & payload, options);
  end;

  procedure push_ethernet_packet(
    signal net : inout network_t;
    source : ethernet_source_t;
    function_name : string;
    arguments : string := "";
    options : ethernet_frame_options_t := default_frame_options
  ) is
    variable msg : msg_t := new_msg(push_ethernet_packet_msg);
  begin
    push(msg, function_name);
    push(msg, arguments);
    push_transmit_options(msg, options);
    send(net, source.p_actor, msg);
  end;

  procedure push_ethernet_sequence(
    signal net : inout network_t;
    source : ethernet_source_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  ) is
    variable msg : msg_t := new_msg(push_ethernet_sequence_msg);
  begin
    push(msg, function_name);
    push(msg, arguments);
    push(msg, count);
    push(msg, seed);
    send(net, source.p_actor, msg);
  end;

  procedure check_ethernet_sequence(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  ) is
    variable msg : msg_t := new_msg(check_ethernet_sequence_msg);
  begin
    push(msg, function_name);
    push(msg, arguments);
    push(msg, count);
    push(msg, seed);
    send(net, monitor.p_actor, msg);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    reference := new_msg(pop_ethernet_frame_msg);
    send(net, monitor.p_actor, reference);
  end;

  procedure pop_ethernet_frame(
    msg : msg_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  ) is
    constant octets : natural := pop(msg);
    constant frame_fcs_ok : boolean := pop(msg);
    constant frame : std_ulogic_vector := pop_std_ulogic_vector(msg);
    alias result : std_ulogic_vector(0 to data'length - 1) is data;
  begin
    if 8 * octets > data'length then
      failure(
        ethernet_pkg_logger,
        "A frame of " & integer'image(octets) & " octets does not fit in " & integer'image(data'length) & " bits"
      );
      length := 0;
      fcs_ok := false;
      return;
    end if;
    if octets > 0 then
      result(0 to 8 * octets - 1) := frame;
    end if;
    length := octets;
    fcs_ok := frame_fcs_ok;
  end;

  procedure await_pop_ethernet_frame_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  ) is
    variable reply_msg : msg_t;
  begin
    receive_reply(net, reference, reply_msg);
    pop_ethernet_frame(reply_msg, data, length, fcs_ok);
    delete(reference);
    delete(reply_msg);
  end;

  procedure await_pop_ethernet_frame_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  ) is
    variable fcs_ok : boolean;
  begin
    await_pop_ethernet_frame_reply(net, reference, data, length, fcs_ok);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  ) is
    variable reference : ethernet_reference_t;
  begin
    pop_ethernet_frame(net, monitor, reference);
    await_pop_ethernet_frame_reply(net, reference, data, length, fcs_ok);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  ) is
    variable fcs_ok : boolean;
  begin
    pop_ethernet_frame(net, monitor, data, length, fcs_ok);
  end;

  procedure check_ethernet_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    expected : std_ulogic_vector;
    msg : string := "";
    blocking : boolean := true
  ) is
    variable request_msg : msg_t := new_msg(check_ethernet_frame_msg);
    variable reply_msg : msg_t;
  begin
    check_whole_octets(monitor.p_checker, expected);
    push(request_msg, expected);
    push(request_msg, msg);
    push(request_msg, blocking);
    if blocking then
      request(net, monitor.p_actor, request_msg, reply_msg);
      delete(reply_msg);
    else
      send(net, monitor.p_actor, request_msg);
    end if;
  end;

  procedure get_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    reference := new_msg(get_ethernet_statistics_msg);
    send(net, monitor.p_actor, reference);
  end;

  procedure await_get_statistics_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable statistics : out ethernet_statistics_t
  ) is
    variable reply_msg : msg_t;
  begin
    receive_reply(net, reference, reply_msg);
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
    delete(reference);
    delete(reply_msg);
  end;

  procedure get_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable statistics : out ethernet_statistics_t
  ) is
    variable reference : ethernet_reference_t;
  begin
    get_statistics(net, monitor, reference);
    await_get_statistics_reply(net, reference, statistics);
  end;

  procedure await_integer_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable value : out natural
  ) is
    variable reply_msg : msg_t;
  begin
    receive_reply(net, reference, reply_msg);
    value := pop(reply_msg);
    delete(reference);
    delete(reply_msg);
  end;

  procedure get_frame_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    reference := new_msg(get_ethernet_frame_count_msg);
    send(net, monitor.p_actor, reference);
  end;

  procedure await_get_frame_count_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable count : out natural
  ) is
  begin
    await_integer_reply(net, reference, count);
  end;

  procedure get_frame_count(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable count : out natural
  ) is
    variable reference : ethernet_reference_t;
  begin
    get_frame_count(net, monitor, reference);
    await_get_frame_count_reply(net, reference, count);
  end;

  procedure log_statistics(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    log_level : log_level_t := info
  ) is
    variable msg : msg_t := new_msg(log_ethernet_statistics_msg);
  begin
    push(msg, log_level_t'pos(log_level));
    send(net, monitor.p_actor, msg);
  end;

  procedure start_capture(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    file_name : string;
    include_fcs : boolean := true;
    include_errored : boolean := true
  ) is
    variable msg : msg_t := new_msg(start_ethernet_capture_msg);
  begin
    push(msg, file_name);
    push(msg, include_fcs);
    push(msg, include_errored);
    send(net, monitor.p_actor, msg);
  end;

  procedure stop_capture(
    signal net : inout network_t;
    monitor : ethernet_monitor_t
  ) is
    variable msg : msg_t := new_msg(stop_ethernet_capture_msg);
  begin
    send(net, monitor.p_actor, msg);
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : ethernet_protocol_checker_t;
    check : ethernet_check_t;
    enabled : boolean := true
  ) is
    variable msg : msg_t := new_msg(set_ethernet_check_enabled_msg);
  begin
    push(msg, ethernet_check_t'pos(check));
    push(msg, enabled);
    send(net, protocol_checker.p_actor, msg);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : ethernet_protocol_checker_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    reference := new_msg(get_ethernet_check_count_msg);
    push(reference, ethernet_check_t'pos(check));
    send(net, protocol_checker.p_actor, reference);
  end;

  procedure await_get_check_count_reply(
    signal net : inout network_t;
    variable reference : inout ethernet_reference_t;
    variable count : out natural
  ) is
  begin
    await_integer_reply(net, reference, count);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : ethernet_protocol_checker_t;
    check : ethernet_check_t;
    variable count : out natural
  ) is
    variable reference : ethernet_reference_t;
  begin
    get_check_count(net, protocol_checker, check, reference);
    await_get_check_count_reply(net, reference, count);
  end;
end package body;
