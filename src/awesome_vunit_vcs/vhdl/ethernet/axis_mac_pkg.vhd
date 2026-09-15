-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The AXI-Stream MAC client verification components: a source, a sink, a
-- monitor and a protocol checker, with handles, constructors and the procedures
-- of ethernet_pkg for them. The interface carries frames the way a MAC client
-- sees them: one AXI-Stream packet per frame, from the destination address up
-- to the FCS (or without FCS), with tkeep marking the octets of the last beat
-- and tuser(0) with tlast marking an errored frame.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.stream_master_pkg.all;
use vunit_lib.stream_slave_pkg.all;
use vunit_lib.vc_pkg.all;

use work.ethernet_pkg.all;

library python_bridge;
use python_bridge.python_pkg.all;

package axis_mac_pkg is

  -- An AXI-Stream MAC client source, for the axis_mac_source entity. It drives one direction of an AXI-Stream MAC client
  -- interface.
  type axis_mac_source_t is record
    -- Private
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    p_cfg : ethernet_cfg_t;
  end record;

  -- An AXI-Stream MAC client protocol checker, for the axis_mac_protocol_checker entity. It checks the
  -- protocol of one direction of an AXI-Stream MAC client interface.
  type axis_mac_protocol_checker_t is record
    -- Private
    p_type : ethernet_component_type_t;
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_explicit_logger : boolean;
    p_explicit_actor : boolean;
    p_explicit_checker : boolean;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    p_cfg : ethernet_cfg_t;
  end record;

  -- No protocol checker: a monitor created with it does not check the protocol
  constant null_axis_mac_protocol_checker : axis_mac_protocol_checker_t := (
    p_type => null_ethernet_component,
    p_id => null_id,
    p_logger => null_logger,
    p_actor => null_actor,
    p_checker => null_checker,
    p_explicit_logger => false,
    p_explicit_actor => false,
    p_explicit_checker => false,
    p_unexpected_msg_type_policy => fail,
    p_cfg => null_ethernet_cfg
  );

  -- The protocol checker a monitor creates for itself: the link and frame
  -- configuration of the monitor and the default limits of
  -- :vhdl:`axis_mac_pkg.new_axis_mac_protocol_checker`
  constant default_axis_mac_protocol_checker : axis_mac_protocol_checker_t := (
    p_type => default_ethernet_component,
    p_id => null_id,
    p_logger => null_logger,
    p_actor => null_actor,
    p_checker => null_checker,
    p_explicit_logger => false,
    p_explicit_actor => false,
    p_explicit_checker => false,
    p_unexpected_msg_type_policy => fail,
    p_cfg => null_ethernet_cfg
  );

  -- An AXI-Stream MAC client monitor, for the axis_mac_monitor entity. It reconstructs the frames of
  -- one direction of an AXI-Stream MAC client interface.
  type axis_mac_monitor_t is record
    -- Private
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    p_cfg : ethernet_cfg_t;
    p_protocol_checker : axis_mac_protocol_checker_t;
  end record;

  -- Create a source.
  --
  -- bytes_per_beat is the width of tkeep; tdata has 8 bits per octet.
  -- user_length is the width of tuser; the source drives tuser(0) with tlast of
  -- an errored frame. has_fcs = false sends frames without FCS.
  -- valid_low_percent is the chance in percent of a clock with tvalid low
  -- before each beat after the first of a frame, drawn from seed.
  -- link_rate_mbps is used for statistics only.
  --
  -- The id defaults to awesome_vunit_vcs:axis_mac_source:<n>, n counting the
  -- sources from 1. The logger defaults to the logger of the id, the actor to
  -- a new actor of the id and the checker to a new checker reporting to the
  -- logger. A message the source does not handle is a check failure, or
  -- ignored when unexpected_msg_type_policy is ignore.
  impure function new_axis_mac_source(
    bytes_per_beat : positive := 8;
    user_length : positive := 1;
    has_fcs : boolean := true;
    valid_low_percent : natural := 0;
    seed : natural := 0;
    link_rate_mbps : positive := 10000;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_source_t;

  -- Create a monitor.
  --
  -- bytes_per_beat and user_length are the widths of tkeep and tuser.
  -- link_rate_mbps is used for utilization statistics.
  -- has_fcs = false is for frames observed without an FCS; min_frame_octets is
  -- the size a transmitter pads to, which check_ethernet_frame accepts.
  --
  -- The monitor sends what it samples to Python in batches of up to
  -- batch_length samples, and at the end of every frame when
  -- flush_at_frame_end. Sample times are kept with a resolution of delta_unit.
  -- log_frames logs every received frame at debug level.
  --
  -- A monitor does not check the protocol itself. With protocol_checker, it
  -- instantiates a protocol checker on the same pins: pass
  -- default_axis_mac_protocol_checker for the default checks or a protocol checker
  -- created with :vhdl:`axis_mac_pkg.new_axis_mac_protocol_checker`. Its id becomes
  -- <monitor id>:protocol_checker, and its logger, actor and checker derive
  -- from that id unless they were given explicitly.
  --
  -- The id, logger, actor, checker and unexpected_msg_type_policy are like
  -- those of :vhdl:`axis_mac_pkg.new_axis_mac_source`, with the id defaulting to
  -- awesome_vunit_vcs:axis_mac_monitor:<n>.
  impure function new_axis_mac_monitor(
    bytes_per_beat : positive := 8;
    user_length : positive := 1;
    link_rate_mbps : positive := 10000;
    has_fcs : boolean := true;
    min_frame_octets : natural := 64;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    protocol_checker : axis_mac_protocol_checker_t := null_axis_mac_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_monitor_t;

  -- Create a protocol checker. Violations of its checks are check failures
  -- on its checker.
  --
  -- bytes_per_beat and user_length are the widths of tkeep and tuser.
  -- link_rate_mbps is used for sample times only.
  -- The frame limits configure the checks; a maximum of 0 disables that limit.
  -- Besides the frame checks it checks the AXI-Stream rules: eth_keep, eth_stable
  -- and eth_valid. Frame octets count from the destination address to
  -- the FCS; has_fcs = false is for frames observed without an FCS. The
  -- batching options are those of :vhdl:`axis_mac_pkg.new_axis_mac_monitor`.
  --
  -- The id, logger, actor, checker and unexpected_msg_type_policy are like
  -- those of :vhdl:`axis_mac_pkg.new_axis_mac_source`, with the id defaulting to
  -- awesome_vunit_vcs:axis_mac_protocol_checker:<n>.
  impure function new_axis_mac_protocol_checker(
    bytes_per_beat : positive := 8;
    user_length : positive := 1;
    link_rate_mbps : positive := 10000;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_protocol_checker_t;

  -- The id of a VC. The Python backend of the VC is the object vc in the
  -- session of this id: ``new_session(get_id(monitor))``.
  impure function get_id(source : axis_mac_source_t) return id_t;
  impure function get_id(monitor : axis_mac_monitor_t) return id_t;
  impure function get_id(protocol_checker : axis_mac_protocol_checker_t) return id_t;

  -- The logger, actor and checker of a VC
  impure function get_logger(source : axis_mac_source_t) return logger_t;
  impure function get_logger(monitor : axis_mac_monitor_t) return logger_t;
  impure function get_logger(protocol_checker : axis_mac_protocol_checker_t) return logger_t;
  impure function get_actor(source : axis_mac_source_t) return actor_t;
  impure function get_actor(monitor : axis_mac_monitor_t) return actor_t;
  impure function get_actor(protocol_checker : axis_mac_protocol_checker_t) return actor_t;
  impure function get_checker(source : axis_mac_source_t) return checker_t;
  impure function get_checker(monitor : axis_mac_monitor_t) return checker_t;
  impure function get_checker(protocol_checker : axis_mac_protocol_checker_t) return checker_t;

  -- The synchronization VCI of a VC
  impure function as_sync(source : axis_mac_source_t) return sync_handle_t;
  impure function as_sync(monitor : axis_mac_monitor_t) return sync_handle_t;
  impure function as_sync(protocol_checker : axis_mac_protocol_checker_t) return sync_handle_t;

  -- The stream VCI of a VC. A source is a stream master: push_stream pushes
  -- one octet, and the octet with last ends a frame, transmitted with
  -- default_frame_options. A monitor is a stream slave: pop_stream pops the
  -- octets of the frames it receives, last with the last octet of a frame.
  impure function as_stream(source : axis_mac_source_t) return stream_master_t;
  impure function as_stream(monitor : axis_mac_monitor_t) return stream_slave_t;

  -- The Ethernet VCI of a VC
  impure function as_ethernet_source(source : axis_mac_source_t) return ethernet_source_t;
  impure function as_ethernet_monitor(monitor : axis_mac_monitor_t) return ethernet_monitor_t;
  impure function as_ethernet_protocol_checker(protocol_checker : axis_mac_protocol_checker_t)
    return ethernet_protocol_checker_t;

  -- The protocol checker of a monitor, null_axis_mac_protocol_checker when it has none
  function get_protocol_checker(monitor : axis_mac_monitor_t) return axis_mac_protocol_checker_t;

  -- The widths of the tdata, tkeep and tuser ports of a VC
  impure function data_length(source : axis_mac_source_t) return positive;
  impure function data_length(monitor : axis_mac_monitor_t) return positive;
  impure function data_length(protocol_checker : axis_mac_protocol_checker_t) return positive;
  impure function keep_length(source : axis_mac_source_t) return positive;
  impure function keep_length(monitor : axis_mac_monitor_t) return positive;
  impure function keep_length(protocol_checker : axis_mac_protocol_checker_t) return positive;
  impure function user_length(source : axis_mac_source_t) return positive;
  impure function user_length(monitor : axis_mac_monitor_t) return positive;
  impure function user_length(protocol_checker : axis_mac_protocol_checker_t) return positive;

  -- The procedures of :vhdl:`ethernet_pkg.push_ethernet_frame`,
  -- :vhdl:`ethernet_pkg.push_ethernet_packet` and
  -- :vhdl:`ethernet_pkg.push_ethernet_sequence` for an AXI-Stream MAC client source
  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : axis_mac_source_t;
    data : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  );
  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : axis_mac_source_t;
    destination : std_ulogic_vector;
    source_address : std_ulogic_vector;
    ethertype : std_ulogic_vector;
    payload : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  );
  procedure push_ethernet_packet(
    signal net : inout network_t;
    source : axis_mac_source_t;
    function_name : string;
    arguments : arg_t := null_arg;
    options : ethernet_frame_options_t := default_frame_options
  );
  procedure push_ethernet_sequence(
    signal net : inout network_t;
    source : axis_mac_source_t;
    function_name : string;
    arguments : arg_t := null_arg;
    count : natural := 0;
    seed : string := ""
  );

  -- The monitor procedures of ethernet_pkg, such as
  -- :vhdl:`ethernet_pkg.pop_ethernet_frame`, :vhdl:`ethernet_pkg.check_ethernet_frame`
  -- and :vhdl:`ethernet_pkg.get_statistics`, for an AXI-Stream MAC client monitor
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable reference : inout ethernet_reference_t
  );
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  );
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  );
  procedure check_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    expected : std_ulogic_vector;
    msg : string := "";
    blocking : boolean := true
  );
  procedure check_ethernet_sequence(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    function_name : string;
    arguments : arg_t := null_arg;
    count : natural := 0;
    seed : string := ""
  );
  procedure get_statistics(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_statistics(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable statistics : out ethernet_statistics_t
  );
  procedure get_frame_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_frame_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable count : out natural
  );
  procedure log_statistics(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    log_level : log_level_t := info
  );
  procedure start_capture(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    file_name : string;
    include_fcs : boolean := true;
    include_errored : boolean := true
  );
  procedure stop_capture(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t
  );

  -- The procedures of :vhdl:`ethernet_pkg.set_check_enabled` and
  -- :vhdl:`ethernet_pkg.get_check_count` for an AXI-Stream MAC client protocol checker
  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t;
    check : ethernet_check_t;
    enabled : boolean := true
  );
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t;
    check : ethernet_check_t;
    variable count : out natural
  );

  -- The same procedures for a monitor. The monitor counts the checks it runs
  -- itself (:vhdl:`ethernet_pkg.is_monitor_check`: ``eth_scoreboard`` and
  -- ``eth_user``, which Python code reports with ``vc.error``) and forwards the
  -- protocol checks to the protocol checker it instantiates
  -- (:vhdl:`axis_mac_pkg.get_protocol_checker`). A protocol check on a monitor
  -- without a protocol checker is a failure on the logger of the monitor.
  procedure set_check_enabled(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    check : ethernet_check_t;
    enabled : boolean := true
  );
  procedure get_check_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_check_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    check : ethernet_check_t;
    variable count : out natural
  );

  -- Recover a VC, see :vhdl:`ethernet_pkg.reset`
  procedure reset(
    signal net : inout network_t;
    source : axis_mac_source_t
  );
  procedure reset(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    clear_statistics : boolean := false
  );
  procedure reset(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t
  );

  -- An AXI-Stream MAC client sink, for the axis_mac_sink entity. It drives tready
  -- of one AXI-Stream interface with a backpressure pattern.
  type axis_mac_sink_t is record
    -- Private
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    p_ready_high_percent : natural;
    p_seed : natural;
  end record;

  -- Create a sink.
  --
  -- ready_high_percent is the chance in percent that tready is high on a clock,
  -- drawn from seed: 100 keeps tready high, 0 low.
  --
  -- The id, logger, actor, checker and unexpected_msg_type_policy are like
  -- those of :vhdl:`axis_mac_pkg.new_axis_mac_source`, with the id defaulting to
  -- awesome_vunit_vcs:axis_mac_sink:<n>.
  impure function new_axis_mac_sink(
    ready_high_percent : natural := 100;
    seed : natural := 0;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_sink_t;

  -- The id, logger, actor, checker and synchronization VCI of a sink
  impure function get_id(sink : axis_mac_sink_t) return id_t;
  impure function get_logger(sink : axis_mac_sink_t) return logger_t;
  impure function get_actor(sink : axis_mac_sink_t) return actor_t;
  impure function get_checker(sink : axis_mac_sink_t) return checker_t;
  impure function as_sync(sink : axis_mac_sink_t) return sync_handle_t;

  -- The backpressure pattern a sink starts with
  function get_ready_high_percent(sink : axis_mac_sink_t) return natural;
  function get_ready_seed(sink : axis_mac_sink_t) return natural;
  function get_unexpected_msg_type_policy(sink : axis_mac_sink_t) return unexpected_msg_type_policy_t;

  -- Change the backpressure pattern of a sink from the next clock on
  procedure set_ready_pattern(
    signal net : inout network_t;
    sink : axis_mac_sink_t;
    ready_high_percent : natural;
    seed : natural := 0
  );

  -- Return a sink to the pattern it was created with. Blocks until the sink
  -- has handled it, also while the clock is stopped.
  procedure reset(
    signal net : inout network_t;
    sink : axis_mac_sink_t
  );

  -- The message types of a sink
  constant set_axis_mac_sink_ready_msg : msg_type_t := new_msg_type("set axis mac sink ready");
  constant reset_axis_mac_sink_msg : msg_type_t := new_msg_type("reset axis mac sink");
  constant reset_axis_mac_sink_reply_msg : msg_type_t := new_msg_type("reset axis mac sink reply");

  -- Private: the VC an entity implements
  impure function to_ethernet_vc(source : axis_mac_source_t) return ethernet_vc_t;
  impure function to_ethernet_vc(monitor : axis_mac_monitor_t) return ethernet_vc_t;
  impure function to_ethernet_vc(protocol_checker : axis_mac_protocol_checker_t) return ethernet_vc_t;
end package;

package body axis_mac_pkg is
  -- Reports configuration errors of the constructors
  constant axis_mac_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:axis_mac_pkg");
  constant axis_mac_pkg_checker : checker_t := new_checker(axis_mac_pkg_logger);

  impure function cfg_data_length(cfg : ethernet_cfg_t) return positive is
  begin
    return 8 * cfg.p_lanes;
  end;

  impure function new_axis_mac_source(
    bytes_per_beat : positive := 8;
    user_length : positive := 1;
    has_fcs : boolean := true;
    valid_low_percent : natural := 0;
    seed : natural := 0;
    link_rate_mbps : positive := 10000;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_source_t is
    constant identity : ethernet_identity_t := new_ethernet_identity("axis_mac_source", id, logger, actor, checker);
  begin

    return (
      p_id => identity.p_id,
      p_logger => identity.p_logger,
      p_actor => identity.p_actor,
      p_checker => identity.p_checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy,
      p_cfg => new_ethernet_cfg(
        interface => axis,
        link_rate_mbps => link_rate_mbps,
        lanes => bytes_per_beat,
        user_length => user_length,
        has_fcs => has_fcs,
        valid_low_percent => valid_low_percent,
        seed => seed,
        min_preamble_octets => 0,
        max_preamble_octets => 0,
        min_ifg_octets => 0
      )
    );
  end;

  impure function new_axis_mac_protocol_checker(
    bytes_per_beat : positive := 8;
    user_length : positive := 1;
    link_rate_mbps : positive := 10000;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_protocol_checker_t is
    constant identity : ethernet_identity_t :=
      new_ethernet_identity("axis_mac_protocol_checker", id, logger, actor, checker);
  begin

    return (
      p_type => custom_ethernet_component,
      p_id => identity.p_id,
      p_logger => identity.p_logger,
      p_actor => identity.p_actor,
      p_checker => identity.p_checker,
      p_explicit_logger => identity.p_explicit_logger,
      p_explicit_actor => identity.p_explicit_actor,
      p_explicit_checker => identity.p_explicit_checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy,
      p_cfg => new_ethernet_cfg(
        interface => axis,
        link_rate_mbps => link_rate_mbps,
        lanes => bytes_per_beat,
        user_length => user_length,
        min_preamble_octets => 0,
        max_preamble_octets => 0,
        min_frame_octets => min_frame_octets,
        max_frame_octets => max_frame_octets,
        min_ifg_octets => 0,
        has_fcs => has_fcs,
        batch_length => batch_length,
        flush_at_frame_end => flush_at_frame_end,
        delta_unit => delta_unit
      )
    );
  end;

  -- The protocol checker of a monitor with id parent and configuration
  -- monitor_cfg, like get_valid_protocol_checker of axi_stream_pkg
  impure function child_protocol_checker(
    protocol_checker : axis_mac_protocol_checker_t;
    parent : id_t;
    monitor_cfg : ethernet_cfg_t
  ) return axis_mac_protocol_checker_t is
    variable result : axis_mac_protocol_checker_t := protocol_checker;
    variable identity : ethernet_identity_t;
  begin
    if protocol_checker.p_type = null_ethernet_component then
      return protocol_checker;
    elsif protocol_checker.p_type = default_ethernet_component then
      result.p_cfg := new_ethernet_cfg(
        interface => axis,
        link_rate_mbps => monitor_cfg.p_link_rate_mbps,
        lanes => monitor_cfg.p_lanes,
        user_length => monitor_cfg.p_user_length,
        min_preamble_octets => 0,
        max_preamble_octets => 0,
        min_ifg_octets => 0,
        min_frame_octets => monitor_cfg.p_min_frame_octets,
        has_fcs => monitor_cfg.p_has_fcs,
        batch_length => monitor_cfg.p_batch_length,
        flush_at_frame_end => monitor_cfg.p_flush_at_frame_end,
        delta_unit => monitor_cfg.p_delta_unit
      );
    elsif protocol_checker.p_cfg.p_lanes /= monitor_cfg.p_lanes or
      protocol_checker.p_cfg.p_user_length /= monitor_cfg.p_user_length then
      check_failed(
        axis_mac_pkg_checker,
        "The protocol checker of a monitor must have its bytes_per_beat and user_length"
      );
    end if;

    identity := inherit_ethernet_identity(
      (
        p_id => protocol_checker.p_id,
        p_logger => protocol_checker.p_logger,
        p_actor => protocol_checker.p_actor,
        p_checker => protocol_checker.p_checker,
        p_explicit_logger => protocol_checker.p_explicit_logger,
        p_explicit_actor => protocol_checker.p_explicit_actor,
        p_explicit_checker => protocol_checker.p_explicit_checker
      ),
      "protocol_checker",
      parent
    );
    result.p_type := custom_ethernet_component;
    result.p_id := identity.p_id;
    result.p_logger := identity.p_logger;
    result.p_actor := identity.p_actor;
    result.p_checker := identity.p_checker;
    return result;
  end;

  impure function new_axis_mac_monitor(
    bytes_per_beat : positive := 8;
    user_length : positive := 1;
    link_rate_mbps : positive := 10000;
    has_fcs : boolean := true;
    min_frame_octets : natural := 64;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    protocol_checker : axis_mac_protocol_checker_t := null_axis_mac_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_monitor_t is
    constant identity : ethernet_identity_t := new_ethernet_identity("axis_mac_monitor", id, logger, actor, checker);
    constant cfg : ethernet_cfg_t := new_ethernet_cfg(
      interface => axis,
      link_rate_mbps => link_rate_mbps,
      lanes => bytes_per_beat,
      user_length => user_length,
      min_preamble_octets => 0,
      max_preamble_octets => 0,
      min_ifg_octets => 0,
      has_fcs => has_fcs,
      min_frame_octets => min_frame_octets,
      batch_length => batch_length,
      flush_at_frame_end => flush_at_frame_end,
      delta_unit => delta_unit,
      log_frames => log_frames
    );
  begin

    return (
      p_id => identity.p_id,
      p_logger => identity.p_logger,
      p_actor => identity.p_actor,
      p_checker => identity.p_checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy,
      p_cfg => cfg,
      p_protocol_checker => child_protocol_checker(protocol_checker, identity.p_id, cfg)
    );
  end;

  impure function get_id(source : axis_mac_source_t) return id_t is
  begin
    return source.p_id;
  end;

  impure function get_id(monitor : axis_mac_monitor_t) return id_t is
  begin
    return monitor.p_id;
  end;

  impure function get_id(protocol_checker : axis_mac_protocol_checker_t) return id_t is
  begin
    return protocol_checker.p_id;
  end;

  impure function get_logger(source : axis_mac_source_t) return logger_t is
  begin
    return source.p_logger;
  end;

  impure function get_logger(monitor : axis_mac_monitor_t) return logger_t is
  begin
    return monitor.p_logger;
  end;

  impure function get_logger(protocol_checker : axis_mac_protocol_checker_t) return logger_t is
  begin
    return protocol_checker.p_logger;
  end;

  impure function get_actor(source : axis_mac_source_t) return actor_t is
  begin
    return source.p_actor;
  end;

  impure function get_actor(monitor : axis_mac_monitor_t) return actor_t is
  begin
    return monitor.p_actor;
  end;

  impure function get_actor(protocol_checker : axis_mac_protocol_checker_t) return actor_t is
  begin
    return protocol_checker.p_actor;
  end;

  impure function get_checker(source : axis_mac_source_t) return checker_t is
  begin
    return source.p_checker;
  end;

  impure function get_checker(monitor : axis_mac_monitor_t) return checker_t is
  begin
    return monitor.p_checker;
  end;

  impure function get_checker(protocol_checker : axis_mac_protocol_checker_t) return checker_t is
  begin
    return protocol_checker.p_checker;
  end;

  impure function as_sync(source : axis_mac_source_t) return sync_handle_t is
  begin
    return source.p_actor;
  end;

  impure function as_sync(monitor : axis_mac_monitor_t) return sync_handle_t is
  begin
    return monitor.p_actor;
  end;

  impure function as_sync(protocol_checker : axis_mac_protocol_checker_t) return sync_handle_t is
  begin
    return protocol_checker.p_actor;
  end;

  impure function as_stream(source : axis_mac_source_t) return stream_master_t is
  begin
    return (p_actor => source.p_actor);
  end;

  impure function as_stream(monitor : axis_mac_monitor_t) return stream_slave_t is
  begin
    return (p_actor => monitor.p_actor);
  end;

  impure function as_ethernet_source(source : axis_mac_source_t) return ethernet_source_t is
  begin
    return (p_actor => source.p_actor, p_checker => source.p_checker);
  end;

  impure function as_ethernet_monitor(monitor : axis_mac_monitor_t) return ethernet_monitor_t is
  begin
    return (p_actor => monitor.p_actor, p_checker => monitor.p_checker);
  end;

  impure function as_ethernet_protocol_checker(protocol_checker : axis_mac_protocol_checker_t)
    return ethernet_protocol_checker_t is
  begin
    return (p_actor => protocol_checker.p_actor, p_checker => protocol_checker.p_checker);
  end;

  function get_protocol_checker(monitor : axis_mac_monitor_t) return axis_mac_protocol_checker_t is
  begin
    return monitor.p_protocol_checker;
  end;

  impure function data_length(source : axis_mac_source_t) return positive is
  begin
    return cfg_data_length(source.p_cfg);
  end;

  impure function data_length(monitor : axis_mac_monitor_t) return positive is
  begin
    return cfg_data_length(monitor.p_cfg);
  end;

  impure function data_length(protocol_checker : axis_mac_protocol_checker_t) return positive is
  begin
    return cfg_data_length(protocol_checker.p_cfg);
  end;

  impure function keep_length(source : axis_mac_source_t) return positive is
  begin
    return source.p_cfg.p_lanes;
  end;

  impure function keep_length(monitor : axis_mac_monitor_t) return positive is
  begin
    return monitor.p_cfg.p_lanes;
  end;

  impure function keep_length(protocol_checker : axis_mac_protocol_checker_t) return positive is
  begin
    return protocol_checker.p_cfg.p_lanes;
  end;

  impure function user_length(source : axis_mac_source_t) return positive is
  begin
    return source.p_cfg.p_user_length;
  end;

  impure function user_length(monitor : axis_mac_monitor_t) return positive is
  begin
    return monitor.p_cfg.p_user_length;
  end;

  impure function user_length(protocol_checker : axis_mac_protocol_checker_t) return positive is
  begin
    return protocol_checker.p_cfg.p_user_length;
  end;

  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : axis_mac_source_t;
    data : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  ) is
  begin
    push_ethernet_frame(net, as_ethernet_source(source), data, options);
  end;

  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : axis_mac_source_t;
    destination : std_ulogic_vector;
    source_address : std_ulogic_vector;
    ethertype : std_ulogic_vector;
    payload : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  ) is
  begin
    push_ethernet_frame(net, as_ethernet_source(source), destination, source_address, ethertype, payload, options);
  end;

  procedure push_ethernet_packet(
    signal net : inout network_t;
    source : axis_mac_source_t;
    function_name : string;
    arguments : arg_t := null_arg;
    options : ethernet_frame_options_t := default_frame_options
  ) is
  begin
    push_ethernet_packet(net, as_ethernet_source(source), function_name, arguments, options);
  end;

  procedure push_ethernet_sequence(
    signal net : inout network_t;
    source : axis_mac_source_t;
    function_name : string;
    arguments : arg_t := null_arg;
    count : natural := 0;
    seed : string := ""
  ) is
  begin
    push_ethernet_sequence(net, as_ethernet_source(source), function_name, arguments, count, seed);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    pop_ethernet_frame(net, as_ethernet_monitor(monitor), reference);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  ) is
  begin
    pop_ethernet_frame(net, as_ethernet_monitor(monitor), data, length, fcs_ok);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  ) is
  begin
    pop_ethernet_frame(net, as_ethernet_monitor(monitor), data, length);
  end;

  procedure check_ethernet_frame(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    expected : std_ulogic_vector;
    msg : string := "";
    blocking : boolean := true
  ) is
  begin
    check_ethernet_frame(net, as_ethernet_monitor(monitor), expected, msg, blocking);
  end;

  procedure check_ethernet_sequence(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    function_name : string;
    arguments : arg_t := null_arg;
    count : natural := 0;
    seed : string := ""
  ) is
  begin
    check_ethernet_sequence(net, as_ethernet_monitor(monitor), function_name, arguments, count, seed);
  end;

  procedure get_statistics(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    get_statistics(net, as_ethernet_monitor(monitor), reference);
  end;

  procedure get_statistics(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable statistics : out ethernet_statistics_t
  ) is
  begin
    get_statistics(net, as_ethernet_monitor(monitor), statistics);
  end;

  procedure get_frame_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    get_frame_count(net, as_ethernet_monitor(monitor), reference);
  end;

  procedure get_frame_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    variable count : out natural
  ) is
  begin
    get_frame_count(net, as_ethernet_monitor(monitor), count);
  end;

  procedure log_statistics(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    log_level : log_level_t := info
  ) is
  begin
    log_statistics(net, as_ethernet_monitor(monitor), log_level);
  end;

  procedure start_capture(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    file_name : string;
    include_fcs : boolean := true;
    include_errored : boolean := true
  ) is
  begin
    start_capture(net, as_ethernet_monitor(monitor), file_name, include_fcs, include_errored);
  end;

  procedure stop_capture(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t
  ) is
  begin
    stop_capture(net, as_ethernet_monitor(monitor));
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t;
    check : ethernet_check_t;
    enabled : boolean := true
  ) is
  begin
    set_check_enabled(net, as_ethernet_protocol_checker(protocol_checker), check, enabled);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    get_check_count(net, as_ethernet_protocol_checker(protocol_checker), check, reference);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t;
    check : ethernet_check_t;
    variable count : out natural
  ) is
  begin
    get_check_count(net, as_ethernet_protocol_checker(protocol_checker), check, count);
  end;

  -- Fails on the logger of the monitor when it has no protocol checker to forward to
  impure function has_protocol_checker(monitor : axis_mac_monitor_t; procedure_name : string) return boolean is
  begin
    if get_protocol_checker(monitor) = null_axis_mac_protocol_checker then
      failure(
        get_logger(monitor),
        procedure_name & " needs a protocol checker, but the monitor has none. Create the monitor with " &
        "protocol_checker => new_axis_mac_protocol_checker or default_axis_mac_protocol_checker"
      );
      return false;
    end if;
    return true;
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    check : ethernet_check_t;
    enabled : boolean := true
  ) is
  begin
    if is_monitor_check(check) then
      set_check_enabled(net, as_ethernet_monitor(monitor), check, enabled);
    elsif has_protocol_checker(monitor, "set_check_enabled") then
      set_check_enabled(net, get_protocol_checker(monitor), check, enabled);
    end if;
  end;

  procedure get_check_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    if is_monitor_check(check) then
      get_check_count(net, as_ethernet_monitor(monitor), check, reference);
    elsif has_protocol_checker(monitor, "get_check_count") then
      get_check_count(net, get_protocol_checker(monitor), check, reference);
    end if;
  end;

  procedure get_check_count(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    check : ethernet_check_t;
    variable count : out natural
  ) is
  begin
    if is_monitor_check(check) then
      get_check_count(net, as_ethernet_monitor(monitor), check, count);
    elsif has_protocol_checker(monitor, "get_check_count") then
      get_check_count(net, get_protocol_checker(monitor), check, count);
    end if;
  end;

  procedure reset(
    signal net : inout network_t;
    source : axis_mac_source_t
  ) is
  begin
    reset(net, as_ethernet_source(source));
  end;

  procedure reset(
    signal net : inout network_t;
    monitor : axis_mac_monitor_t;
    clear_statistics : boolean := false
  ) is
  begin
    reset(net, as_ethernet_monitor(monitor), clear_statistics);
  end;

  procedure reset(
    signal net : inout network_t;
    protocol_checker : axis_mac_protocol_checker_t
  ) is
  begin
    reset(net, as_ethernet_protocol_checker(protocol_checker));
  end;

  impure function new_axis_mac_sink(
    ready_high_percent : natural := 100;
    seed : natural := 0;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return axis_mac_sink_t is
    constant identity : ethernet_identity_t := new_ethernet_identity("axis_mac_sink", id, logger, actor, checker);
  begin
    return (
      p_id => identity.p_id,
      p_logger => identity.p_logger,
      p_actor => identity.p_actor,
      p_checker => identity.p_checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy,
      p_ready_high_percent => ready_high_percent,
      p_seed => seed
    );
  end;

  impure function get_id(sink : axis_mac_sink_t) return id_t is
  begin
    return sink.p_id;
  end;

  impure function get_logger(sink : axis_mac_sink_t) return logger_t is
  begin
    return sink.p_logger;
  end;

  impure function get_actor(sink : axis_mac_sink_t) return actor_t is
  begin
    return sink.p_actor;
  end;

  impure function get_checker(sink : axis_mac_sink_t) return checker_t is
  begin
    return sink.p_checker;
  end;

  impure function as_sync(sink : axis_mac_sink_t) return sync_handle_t is
  begin
    return sink.p_actor;
  end;

  function get_ready_high_percent(sink : axis_mac_sink_t) return natural is
  begin
    return sink.p_ready_high_percent;
  end;

  function get_ready_seed(sink : axis_mac_sink_t) return natural is
  begin
    return sink.p_seed;
  end;

  function get_unexpected_msg_type_policy(sink : axis_mac_sink_t) return unexpected_msg_type_policy_t is
  begin
    return sink.p_unexpected_msg_type_policy;
  end;

  procedure set_ready_pattern(
    signal net : inout network_t;
    sink : axis_mac_sink_t;
    ready_high_percent : natural;
    seed : natural := 0
  ) is
    variable msg : msg_t := new_msg(set_axis_mac_sink_ready_msg);
  begin
    push(msg, ready_high_percent);
    push(msg, seed);
    send(net, sink.p_actor, msg);
  end;

  procedure reset(
    signal net : inout network_t;
    sink : axis_mac_sink_t
  ) is
    variable request_msg : msg_t := new_msg(reset_axis_mac_sink_msg);
    variable reply_msg : msg_t;
  begin
    request(net, sink.p_actor, request_msg, reply_msg);
    delete(reply_msg);
  end;

  impure function to_ethernet_vc(source : axis_mac_source_t) return ethernet_vc_t is
  begin
    return (
      p_kind => source_vc,
      p_id => source.p_id,
      p_logger => source.p_logger,
      p_actor => source.p_actor,
      p_checker => source.p_checker,
      p_unexpected_msg_type_policy => source.p_unexpected_msg_type_policy,
      p_cfg => source.p_cfg
    );
  end;

  impure function to_ethernet_vc(monitor : axis_mac_monitor_t) return ethernet_vc_t is
  begin
    return (
      p_kind => monitor_vc,
      p_id => monitor.p_id,
      p_logger => monitor.p_logger,
      p_actor => monitor.p_actor,
      p_checker => monitor.p_checker,
      p_unexpected_msg_type_policy => monitor.p_unexpected_msg_type_policy,
      p_cfg => monitor.p_cfg
    );
  end;

  impure function to_ethernet_vc(protocol_checker : axis_mac_protocol_checker_t) return ethernet_vc_t is
  begin
    return (
      p_kind => protocol_checker_vc,
      p_id => protocol_checker.p_id,
      p_logger => protocol_checker.p_logger,
      p_actor => protocol_checker.p_actor,
      p_checker => protocol_checker.p_checker,
      p_unexpected_msg_type_policy => protocol_checker.p_unexpected_msg_type_policy,
      p_cfg => protocol_checker.p_cfg
    );
  end;
end package body;
