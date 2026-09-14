-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The MII verification components: a source, a monitor and a protocol
-- checker, with handles, constructors and the procedures of ethernet_pkg for
-- them. MII (IEEE 802.3 Clause 22) carries one nibble per clock cycle, least
-- significant nibble first, at 10 Mbit/s (2.5 MHz clock) or 100 Mbit/s (25 MHz
-- clock).

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

package mii_pkg is

  -- A MII source, for the mii_source entity. It drives one direction of a MII
  -- interface.
  type mii_source_t is record
    -- Private
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    p_cfg : ethernet_cfg_t;
  end record;

  -- A MII protocol checker, for the mii_protocol_checker entity. It checks the
  -- protocol of one direction of a MII interface.
  type mii_protocol_checker_t is record
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
  constant null_mii_protocol_checker : mii_protocol_checker_t := (
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
  -- :vhdl:`mii_pkg.new_mii_protocol_checker`
  constant default_mii_protocol_checker : mii_protocol_checker_t := (
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

  -- A MII monitor, for the mii_monitor entity. It reconstructs the frames of
  -- one direction of a MII interface.
  type mii_monitor_t is record
    -- Private
    p_id : id_t;
    p_logger : logger_t;
    p_actor : actor_t;
    p_checker : checker_t;
    p_unexpected_msg_type_policy : unexpected_msg_type_policy_t;
    p_cfg : ethernet_cfg_t;
    p_protocol_checker : mii_protocol_checker_t;
  end record;

  -- Create a source.
  --
  -- link_rate_mbps is the rate of the link, 10 or 100.
  --
  -- The id defaults to awesome_vunit_vcs:mii_source:<n>, n counting the
  -- sources from 1. The logger defaults to the logger of the id, the actor to
  -- a new actor of the id and the checker to a new checker reporting to the
  -- logger. A message the source does not handle is a check failure, or
  -- ignored when unexpected_msg_type_policy is ignore.
  impure function new_mii_source(
    link_rate_mbps : positive := 100;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mii_source_t;

  -- Create a monitor.
  --
  -- link_rate_mbps is the rate of the link, 10 or 100, used for utilization
  -- statistics.
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
  -- default_mii_protocol_checker for the default checks or a protocol checker
  -- created with :vhdl:`mii_pkg.new_mii_protocol_checker`. Its id becomes
  -- <monitor id>:protocol_checker, and its logger, actor and checker derive
  -- from that id unless they were given explicitly.
  --
  -- The id, logger, actor, checker and unexpected_msg_type_policy are like
  -- those of :vhdl:`mii_pkg.new_mii_source`, with the id defaulting to
  -- awesome_vunit_vcs:mii_monitor:<n>.
  impure function new_mii_monitor(
    link_rate_mbps : positive := 100;
    has_fcs : boolean := true;
    min_frame_octets : natural := 64;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    protocol_checker : mii_protocol_checker_t := null_mii_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mii_monitor_t;

  -- Create a protocol checker. Violations of its checks are check failures
  -- on its checker.
  --
  -- link_rate_mbps is the rate of the link, 10 or 100, used to measure the IFG.
  -- The preamble, frame and IFG limits configure the checks; a maximum of 0
  -- disables that limit. Frame octets count from the destination address to
  -- the FCS; has_fcs = false is for frames observed without an FCS. The
  -- batching options are those of :vhdl:`mii_pkg.new_mii_monitor`.
  --
  -- The id, logger, actor, checker and unexpected_msg_type_policy are like
  -- those of :vhdl:`mii_pkg.new_mii_source`, with the id defaulting to
  -- awesome_vunit_vcs:mii_protocol_checker:<n>.
  impure function new_mii_protocol_checker(
    link_rate_mbps : positive := 100;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mii_protocol_checker_t;

  -- The id of a VC. The Python backend of the VC is the object vc in the
  -- session of this id: ``new_session(get_id(monitor))``.
  impure function get_id(source : mii_source_t) return id_t;
  impure function get_id(monitor : mii_monitor_t) return id_t;
  impure function get_id(protocol_checker : mii_protocol_checker_t) return id_t;

  -- The logger, actor and checker of a VC
  impure function get_logger(source : mii_source_t) return logger_t;
  impure function get_logger(monitor : mii_monitor_t) return logger_t;
  impure function get_logger(protocol_checker : mii_protocol_checker_t) return logger_t;
  impure function get_actor(source : mii_source_t) return actor_t;
  impure function get_actor(monitor : mii_monitor_t) return actor_t;
  impure function get_actor(protocol_checker : mii_protocol_checker_t) return actor_t;
  impure function get_checker(source : mii_source_t) return checker_t;
  impure function get_checker(monitor : mii_monitor_t) return checker_t;
  impure function get_checker(protocol_checker : mii_protocol_checker_t) return checker_t;

  -- The synchronization VCI of a VC
  impure function as_sync(source : mii_source_t) return sync_handle_t;
  impure function as_sync(monitor : mii_monitor_t) return sync_handle_t;
  impure function as_sync(protocol_checker : mii_protocol_checker_t) return sync_handle_t;

  -- The stream VCI of a VC. A source is a stream master: push_stream pushes
  -- one octet, and the octet with last ends a frame, transmitted with
  -- default_frame_options. A monitor is a stream slave: pop_stream pops the
  -- octets of the frames it receives, last with the last octet of a frame.
  impure function as_stream(source : mii_source_t) return stream_master_t;
  impure function as_stream(monitor : mii_monitor_t) return stream_slave_t;

  -- The Ethernet VCI of a VC
  impure function as_ethernet_source(source : mii_source_t) return ethernet_source_t;
  impure function as_ethernet_monitor(monitor : mii_monitor_t) return ethernet_monitor_t;
  impure function as_ethernet_protocol_checker(protocol_checker : mii_protocol_checker_t)
    return ethernet_protocol_checker_t;

  -- The protocol checker of a monitor, null_mii_protocol_checker when it has none
  function get_protocol_checker(monitor : mii_monitor_t) return mii_protocol_checker_t;

  -- The width of the data port of a VC
  impure function data_length(source : mii_source_t) return positive;
  impure function data_length(monitor : mii_monitor_t) return positive;
  impure function data_length(protocol_checker : mii_protocol_checker_t) return positive;

  -- The procedures of :vhdl:`ethernet_pkg.push_ethernet_frame`,
  -- :vhdl:`ethernet_pkg.push_ethernet_packet` and
  -- :vhdl:`ethernet_pkg.push_ethernet_sequence` for a MII source
  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : mii_source_t;
    data : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  );
  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : mii_source_t;
    destination : std_ulogic_vector;
    source_address : std_ulogic_vector;
    ethertype : std_ulogic_vector;
    payload : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  );
  procedure push_ethernet_packet(
    signal net : inout network_t;
    source : mii_source_t;
    function_name : string;
    arguments : string := "";
    options : ethernet_frame_options_t := default_frame_options
  );
  procedure push_ethernet_sequence(
    signal net : inout network_t;
    source : mii_source_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  );

  -- The monitor procedures of ethernet_pkg, such as
  -- :vhdl:`ethernet_pkg.pop_ethernet_frame`, :vhdl:`ethernet_pkg.check_ethernet_frame`
  -- and :vhdl:`ethernet_pkg.get_statistics`, for a MII monitor
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable reference : inout ethernet_reference_t
  );
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  );
  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  );
  procedure check_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    expected : std_ulogic_vector;
    msg : string := "";
    blocking : boolean := true
  );
  procedure check_ethernet_sequence(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  );
  procedure get_statistics(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_statistics(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable statistics : out ethernet_statistics_t
  );
  procedure get_frame_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_frame_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable count : out natural
  );
  procedure log_statistics(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    log_level : log_level_t := info
  );
  procedure start_capture(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    file_name : string;
    include_fcs : boolean := true;
    include_errored : boolean := true
  );
  procedure stop_capture(
    signal net : inout network_t;
    monitor : mii_monitor_t
  );

  -- The procedures of :vhdl:`ethernet_pkg.set_check_enabled` and
  -- :vhdl:`ethernet_pkg.get_check_count` for a MII protocol checker
  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t;
    check : ethernet_check_t;
    enabled : boolean := true
  );
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t;
    check : ethernet_check_t;
    variable count : out natural
  );

  -- The same procedures for a monitor, forwarded to the protocol checker it
  -- instantiates (:vhdl:`mii_pkg.get_protocol_checker`). A monitor without a
  -- protocol checker is a failure on the logger of the monitor.
  procedure set_check_enabled(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    check : ethernet_check_t;
    enabled : boolean := true
  );
  procedure get_check_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  );
  procedure get_check_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    check : ethernet_check_t;
    variable count : out natural
  );

  -- Recover a VC, see :vhdl:`ethernet_pkg.reset`
  procedure reset(
    signal net : inout network_t;
    source : mii_source_t
  );
  procedure reset(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    clear_statistics : boolean := false
  );
  procedure reset(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t
  );

  -- Private: the VC an entity implements
  impure function to_ethernet_vc(source : mii_source_t) return ethernet_vc_t;
  impure function to_ethernet_vc(monitor : mii_monitor_t) return ethernet_vc_t;
  impure function to_ethernet_vc(protocol_checker : mii_protocol_checker_t) return ethernet_vc_t;
end package;

package body mii_pkg is
  -- Reports configuration errors of the constructors
  constant mii_pkg_logger : logger_t := get_logger("awesome_vunit_vcs:mii_pkg");
  constant mii_pkg_checker : checker_t := new_checker(mii_pkg_logger);

  impure function cfg_data_length(cfg : ethernet_cfg_t) return positive is
  begin
    return 4;
  end;

  procedure check_link_rate(link_rate_mbps : positive) is
  begin
    check(
      mii_pkg_checker, link_rate_mbps = 10 or link_rate_mbps = 100,
      "MII link_rate_mbps is 10 or 100, got " & integer'image(link_rate_mbps)
    );
  end;

  impure function new_mii_source(
    link_rate_mbps : positive := 100;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mii_source_t is
    constant identity : ethernet_identity_t := new_ethernet_identity("mii_source", id, logger, actor, checker);
  begin
    check_link_rate(link_rate_mbps);
    return (
      p_id => identity.p_id,
      p_logger => identity.p_logger,
      p_actor => identity.p_actor,
      p_checker => identity.p_checker,
      p_unexpected_msg_type_policy => unexpected_msg_type_policy,
      p_cfg => new_ethernet_cfg(
        interface => mii,
        link_rate_mbps => link_rate_mbps
      )
    );
  end;

  impure function new_mii_protocol_checker(
    link_rate_mbps : positive := 100;
    min_preamble_octets : natural := 7;
    max_preamble_octets : natural := 7;
    min_frame_octets : natural := 64;
    max_frame_octets : natural := 1518;
    min_ifg_octets : natural := 12;
    has_fcs : boolean := true;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mii_protocol_checker_t is
    constant identity : ethernet_identity_t :=
      new_ethernet_identity("mii_protocol_checker", id, logger, actor, checker);
  begin
    check_link_rate(link_rate_mbps);
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
        interface => mii,
        link_rate_mbps => link_rate_mbps,
        min_preamble_octets => min_preamble_octets,
        max_preamble_octets => max_preamble_octets,
        min_frame_octets => min_frame_octets,
        max_frame_octets => max_frame_octets,
        min_ifg_octets => min_ifg_octets,
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
    protocol_checker : mii_protocol_checker_t;
    parent : id_t;
    monitor_cfg : ethernet_cfg_t
  ) return mii_protocol_checker_t is
    variable result : mii_protocol_checker_t := protocol_checker;
    variable identity : ethernet_identity_t;
  begin
    if protocol_checker.p_type = null_ethernet_component then
      return protocol_checker;
    elsif protocol_checker.p_type = default_ethernet_component then
      result.p_cfg := new_ethernet_cfg(
        interface => mii,
        link_rate_mbps => monitor_cfg.p_link_rate_mbps,
        min_ifg_octets => 12,
        min_frame_octets => monitor_cfg.p_min_frame_octets,
        has_fcs => monitor_cfg.p_has_fcs,
        batch_length => monitor_cfg.p_batch_length,
        flush_at_frame_end => monitor_cfg.p_flush_at_frame_end,
        delta_unit => monitor_cfg.p_delta_unit
      );
    else
      null;
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

  impure function new_mii_monitor(
    link_rate_mbps : positive := 100;
    has_fcs : boolean := true;
    min_frame_octets : natural := 64;
    batch_length : positive := 4096;
    flush_at_frame_end : boolean := true;
    delta_unit : time := 1 ps;
    log_frames : boolean := false;
    protocol_checker : mii_protocol_checker_t := null_mii_protocol_checker;
    id : id_t := null_id;
    logger : logger_t := null_logger;
    actor : actor_t := null_actor;
    checker : checker_t := null_checker;
    unexpected_msg_type_policy : unexpected_msg_type_policy_t := fail
  ) return mii_monitor_t is
    constant identity : ethernet_identity_t := new_ethernet_identity("mii_monitor", id, logger, actor, checker);
    constant cfg : ethernet_cfg_t := new_ethernet_cfg(
      interface => mii,
      link_rate_mbps => link_rate_mbps,
      has_fcs => has_fcs,
      min_frame_octets => min_frame_octets,
      batch_length => batch_length,
      flush_at_frame_end => flush_at_frame_end,
      delta_unit => delta_unit,
      log_frames => log_frames
    );
  begin
    check_link_rate(link_rate_mbps);
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

  impure function get_id(source : mii_source_t) return id_t is
  begin
    return source.p_id;
  end;

  impure function get_id(monitor : mii_monitor_t) return id_t is
  begin
    return monitor.p_id;
  end;

  impure function get_id(protocol_checker : mii_protocol_checker_t) return id_t is
  begin
    return protocol_checker.p_id;
  end;

  impure function get_logger(source : mii_source_t) return logger_t is
  begin
    return source.p_logger;
  end;

  impure function get_logger(monitor : mii_monitor_t) return logger_t is
  begin
    return monitor.p_logger;
  end;

  impure function get_logger(protocol_checker : mii_protocol_checker_t) return logger_t is
  begin
    return protocol_checker.p_logger;
  end;

  impure function get_actor(source : mii_source_t) return actor_t is
  begin
    return source.p_actor;
  end;

  impure function get_actor(monitor : mii_monitor_t) return actor_t is
  begin
    return monitor.p_actor;
  end;

  impure function get_actor(protocol_checker : mii_protocol_checker_t) return actor_t is
  begin
    return protocol_checker.p_actor;
  end;

  impure function get_checker(source : mii_source_t) return checker_t is
  begin
    return source.p_checker;
  end;

  impure function get_checker(monitor : mii_monitor_t) return checker_t is
  begin
    return monitor.p_checker;
  end;

  impure function get_checker(protocol_checker : mii_protocol_checker_t) return checker_t is
  begin
    return protocol_checker.p_checker;
  end;

  impure function as_sync(source : mii_source_t) return sync_handle_t is
  begin
    return source.p_actor;
  end;

  impure function as_sync(monitor : mii_monitor_t) return sync_handle_t is
  begin
    return monitor.p_actor;
  end;

  impure function as_sync(protocol_checker : mii_protocol_checker_t) return sync_handle_t is
  begin
    return protocol_checker.p_actor;
  end;

  impure function as_stream(source : mii_source_t) return stream_master_t is
  begin
    return (p_actor => source.p_actor);
  end;

  impure function as_stream(monitor : mii_monitor_t) return stream_slave_t is
  begin
    return (p_actor => monitor.p_actor);
  end;

  impure function as_ethernet_source(source : mii_source_t) return ethernet_source_t is
  begin
    return (p_actor => source.p_actor, p_checker => source.p_checker);
  end;

  impure function as_ethernet_monitor(monitor : mii_monitor_t) return ethernet_monitor_t is
  begin
    return (p_actor => monitor.p_actor, p_checker => monitor.p_checker);
  end;

  impure function as_ethernet_protocol_checker(protocol_checker : mii_protocol_checker_t)
    return ethernet_protocol_checker_t is
  begin
    return (p_actor => protocol_checker.p_actor, p_checker => protocol_checker.p_checker);
  end;

  function get_protocol_checker(monitor : mii_monitor_t) return mii_protocol_checker_t is
  begin
    return monitor.p_protocol_checker;
  end;

  impure function data_length(source : mii_source_t) return positive is
  begin
    return cfg_data_length(source.p_cfg);
  end;

  impure function data_length(monitor : mii_monitor_t) return positive is
  begin
    return cfg_data_length(monitor.p_cfg);
  end;

  impure function data_length(protocol_checker : mii_protocol_checker_t) return positive is
  begin
    return cfg_data_length(protocol_checker.p_cfg);
  end;

  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : mii_source_t;
    data : std_ulogic_vector;
    options : ethernet_frame_options_t := default_frame_options
  ) is
  begin
    push_ethernet_frame(net, as_ethernet_source(source), data, options);
  end;

  procedure push_ethernet_frame(
    signal net : inout network_t;
    source : mii_source_t;
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
    source : mii_source_t;
    function_name : string;
    arguments : string := "";
    options : ethernet_frame_options_t := default_frame_options
  ) is
  begin
    push_ethernet_packet(net, as_ethernet_source(source), function_name, arguments, options);
  end;

  procedure push_ethernet_sequence(
    signal net : inout network_t;
    source : mii_source_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  ) is
  begin
    push_ethernet_sequence(net, as_ethernet_source(source), function_name, arguments, count, seed);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    pop_ethernet_frame(net, as_ethernet_monitor(monitor), reference);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural;
    variable fcs_ok : out boolean
  ) is
  begin
    pop_ethernet_frame(net, as_ethernet_monitor(monitor), data, length, fcs_ok);
  end;

  procedure pop_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable data : out std_ulogic_vector;
    variable length : out natural
  ) is
  begin
    pop_ethernet_frame(net, as_ethernet_monitor(monitor), data, length);
  end;

  procedure check_ethernet_frame(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    expected : std_ulogic_vector;
    msg : string := "";
    blocking : boolean := true
  ) is
  begin
    check_ethernet_frame(net, as_ethernet_monitor(monitor), expected, msg, blocking);
  end;

  procedure check_ethernet_sequence(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    function_name : string;
    arguments : string := "";
    count : natural := 0;
    seed : string := ""
  ) is
  begin
    check_ethernet_sequence(net, as_ethernet_monitor(monitor), function_name, arguments, count, seed);
  end;

  procedure get_statistics(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    get_statistics(net, as_ethernet_monitor(monitor), reference);
  end;

  procedure get_statistics(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable statistics : out ethernet_statistics_t
  ) is
  begin
    get_statistics(net, as_ethernet_monitor(monitor), statistics);
  end;

  procedure get_frame_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    get_frame_count(net, as_ethernet_monitor(monitor), reference);
  end;

  procedure get_frame_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    variable count : out natural
  ) is
  begin
    get_frame_count(net, as_ethernet_monitor(monitor), count);
  end;

  procedure log_statistics(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    log_level : log_level_t := info
  ) is
  begin
    log_statistics(net, as_ethernet_monitor(monitor), log_level);
  end;

  procedure start_capture(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    file_name : string;
    include_fcs : boolean := true;
    include_errored : boolean := true
  ) is
  begin
    start_capture(net, as_ethernet_monitor(monitor), file_name, include_fcs, include_errored);
  end;

  procedure stop_capture(
    signal net : inout network_t;
    monitor : mii_monitor_t
  ) is
  begin
    stop_capture(net, as_ethernet_monitor(monitor));
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t;
    check : ethernet_check_t;
    enabled : boolean := true
  ) is
  begin
    set_check_enabled(net, as_ethernet_protocol_checker(protocol_checker), check, enabled);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    get_check_count(net, as_ethernet_protocol_checker(protocol_checker), check, reference);
  end;

  procedure get_check_count(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t;
    check : ethernet_check_t;
    variable count : out natural
  ) is
  begin
    get_check_count(net, as_ethernet_protocol_checker(protocol_checker), check, count);
  end;

  -- Fails on the logger of the monitor when it has no protocol checker to forward to
  impure function has_protocol_checker(monitor : mii_monitor_t; procedure_name : string) return boolean is
  begin
    if get_protocol_checker(monitor) = null_mii_protocol_checker then
      failure(
        get_logger(monitor),
        procedure_name & " needs a protocol checker, but the monitor has none. Create the monitor with " &
        "protocol_checker => new_mii_protocol_checker or default_mii_protocol_checker"
      );
      return false;
    end if;
    return true;
  end;

  procedure set_check_enabled(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    check : ethernet_check_t;
    enabled : boolean := true
  ) is
  begin
    if has_protocol_checker(monitor, "set_check_enabled") then
      set_check_enabled(net, get_protocol_checker(monitor), check, enabled);
    end if;
  end;

  procedure get_check_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    check : ethernet_check_t;
    variable reference : inout ethernet_reference_t
  ) is
  begin
    if has_protocol_checker(monitor, "get_check_count") then
      get_check_count(net, get_protocol_checker(monitor), check, reference);
    end if;
  end;

  procedure get_check_count(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    check : ethernet_check_t;
    variable count : out natural
  ) is
  begin
    if has_protocol_checker(monitor, "get_check_count") then
      get_check_count(net, get_protocol_checker(monitor), check, count);
    end if;
  end;

  procedure reset(
    signal net : inout network_t;
    source : mii_source_t
  ) is
  begin
    reset(net, as_ethernet_source(source));
  end;

  procedure reset(
    signal net : inout network_t;
    monitor : mii_monitor_t;
    clear_statistics : boolean := false
  ) is
  begin
    reset(net, as_ethernet_monitor(monitor), clear_statistics);
  end;

  procedure reset(
    signal net : inout network_t;
    protocol_checker : mii_protocol_checker_t
  ) is
  begin
    reset(net, as_ethernet_protocol_checker(protocol_checker));
  end;

  impure function to_ethernet_vc(source : mii_source_t) return ethernet_vc_t is
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

  impure function to_ethernet_vc(monitor : mii_monitor_t) return ethernet_vc_t is
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

  impure function to_ethernet_vc(protocol_checker : mii_protocol_checker_t) return ethernet_vc_t is
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
