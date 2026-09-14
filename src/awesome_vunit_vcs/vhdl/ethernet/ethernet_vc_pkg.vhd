-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The implementation of the Ethernet verification component entities that
-- does not depend on the PHY handle types: the processes of sources, monitors
-- and protocol checkers of interfaces carrying one symbol per clock cycle
-- (GMII, MII) and of interfaces carrying columns of lanes (XGMII), and the
-- message handling they share. Testbenches use ethernet_pkg and the PHY
-- packages; this package is for the entities.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.textio.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.stream_master_pkg.all;
use vunit_lib.stream_slave_pkg.all;
use vunit_lib.vc_pkg.all;
use vunit_lib.integer_array_pkg.all;
use vunit_lib.dict_pkg.all;

library python_bridge;
context python_bridge.python_context;

use work.ethernet_pkg.all;
use work.vc_python_pkg.all;
use work.xgmii_pkg.all;

package ethernet_vc_pkg is
  -- The Python session of a VC, see :vhdl:`vc_python_pkg.new_vc_session`
  impure function new_vc_session(vc : ethernet_vc_t) return python_session_t;

  -- Handle a message type no handler took, following the unexpected message
  -- type policy of the VC like vc_pkg.unexpected_msg_type of VUnit: a check
  -- failure on the checker of the VC unless the policy is ignore or the
  -- message was already handled
  procedure unexpected_msg_type(msg_type : msg_type_t; vc : ethernet_vc_t);

  -- The octets of a vector, leftmost octet first
  function to_octets(value : std_ulogic_vector) return integer_vector;

  -- The process of a monitor or protocol checker of an interface carrying one
  -- symbol per clock cycle with valid and error signals (GMII, MII, RMII, and
  -- RGMII after its two clock edges are combined). data, dv and er are sampled
  -- on the rising edge of clk, and on every 10th rising edge for RMII at 10
  -- Mbit/s. A sample is recorded when valid is asserted or the sample word
  -- changes, so a long idle period costs one sample. RMII frames end when
  -- CRS_DV is low for two samples in a row, since CRS_DV toggles while a PHY
  -- still delivers data after the carrier ends; both samples are recorded.
  -- Sample words (see awesome_vunit_vcs/ethernet/phy/common.py):
  --
  --   bit 0-7  data (the low data'length bits)
  --   bit 8    dv
  --   bit 9    er
  --   bit 10   metavalue on data while dv is asserted
  --   bit 11   metavalue on dv or er
  --
  -- Never returns.
  procedure monitor_symbol_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal dv : in std_ulogic;
    signal er : in std_ulogic
  );

  -- The process of a monitor or protocol checker of an XGMII-family interface.
  -- A column (the lanes of one clock edge) is recorded as one sample word per
  -- lane, lane 0 first, unless it is an Idle column like the one before it.
  -- Sample words (see awesome_vunit_vcs/ethernet/phy/xgmii.py):
  --
  --   bit 0-7  lane data
  --   bit 8    lane control
  --   bit 10   metavalue on the lane data
  --   bit 11   metavalue on the lane control
  --
  -- Never returns.
  procedure monitor_column_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal ctrl : in std_ulogic_vector
  );

  -- The process of a source of an interface carrying one symbol per clock
  -- cycle with valid and error signals (GMII, MII, RMII, and RGMII before its
  -- two clock edges are split). The sample words the backend returns for a
  -- frame are driven one per rising edge of clk, and held for 10 rising edges
  -- for RMII at 10 Mbit/s.
  -- Never returns.
  procedure drive_symbol_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal dv : out std_ulogic;
    signal er : out std_ulogic
  );

  -- Combine the two clock edges of an RGMII line into the symbols of
  -- monitor_symbol_interface: data holds the lower bits of an octet at the
  -- rising edge of clk and the upper bits at the falling edge (at 1000
  -- Mbit/s), ctl the valid signal at the rising edge and valid xor error at the
  -- falling edge. octet, dv and er change on every falling edge of clk. Never
  -- returns.
  procedure combine_double_edges(
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal ctl : in std_ulogic;
    signal octet : out std_ulogic_vector;
    signal dv : out std_ulogic;
    signal er : out std_ulogic
  );

  -- Split the symbols drive_symbol_interface drives on the rising edges of
  -- clk into the two clock edges of an RGMII line, the inverse of
  -- combine_double_edges. Centered data changes on the edge opposite to the one
  -- it is sampled on, edge aligned data on that edge. Never returns.
  procedure split_double_edges(
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal octet : in std_ulogic_vector;
    signal dv : in std_ulogic;
    signal er : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal ctl : out std_ulogic
  );

  -- The process of a source of an XGMII-family interface: a column on every
  -- rising clock edge, or on both edges, Idle columns when there is nothing
  -- to transmit. Never returns.
  procedure drive_column_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal ctrl : out std_ulogic_vector
  );
  -- The process of a monitor or protocol checker of an AXI-Stream MAC client
  -- interface. Every clock edge where tvalid is high or the bus changed is
  -- recorded as one sample word per octet lane, lane 0 first. Sample words (see
  -- awesome_vunit_vcs/ethernet/phy/axis.py):
  --
  --   bit 0-7  tdata of the lane
  --   bit 8    tkeep of the lane
  --   bit 9    tuser(0)
  --   bit 10   metavalue on the data of a kept lane while tvalid is high
  --   bit 11   metavalue on tvalid or tready, or on tlast, tkeep or tuser while tvalid is high
  --   bit 13   tvalid
  --   bit 14   tready
  --   bit 15   tlast
  --
  -- Never returns.
  procedure monitor_axis_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal tdata : in std_ulogic_vector;
    signal tkeep : in std_ulogic_vector;
    signal tvalid : in std_ulogic;
    signal tready : in std_ulogic;
    signal tlast : in std_ulogic;
    signal tuser : in std_ulogic_vector
  );

  -- The process of a source of an AXI-Stream MAC client interface: the beats
  -- the backend returns for a frame, each held until tready accepts it, and
  -- tvalid low when there is nothing to transmit. Never returns.
  procedure drive_axis_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal tdata : out std_ulogic_vector;
    signal tkeep : out std_ulogic_vector;
    signal tvalid : out std_ulogic;
    signal tready : in std_ulogic;
    signal tlast : out std_ulogic;
    signal tuser : out std_ulogic_vector
  );
end package;

package body ethernet_vc_pkg is
  constant backend_module : string := "awesome_vunit_vcs.ethernet.vunit_backend";

  impure function new_vc_session(vc : ethernet_vc_t) return python_session_t is
  begin
    return new_vc_session(vc.p_id, vc.p_logger);
  end;

  procedure unexpected_msg_type(msg_type : msg_type_t; vc : ethernet_vc_t) is
  begin
    if is_already_handled(msg_type) or vc.p_unexpected_msg_type_policy = ignore then
      null;
    else
      check_failed(vc.p_checker, "Got unexpected message " & name(msg_type));
    end if;
  end;

  function to_octets(value : std_ulogic_vector) return integer_vector is
    alias octets : std_ulogic_vector(0 to value'length - 1) is value;
    variable result : integer_vector(0 to value'length / 8 - 1);
  begin
    for idx in result'range loop
      result(idx) := to_integer(to_01(unsigned(octets(8 * idx to 8 * idx + 7))));
    end loop;
    return result;
  end;

  -- The options of the Python PHY decoder or encoder that the interface has
  impure function phy_options(vc : ethernet_vc_t) return arg_t is
    constant cfg : ethernet_cfg_t := vc.p_cfg;
  begin
    if cfg.p_interface = axis then
      if vc.p_kind = source_vc then
        return kwarg("lanes", cfg.p_lanes) & kwarg("has_fcs", cfg.p_has_fcs) &
          kwarg("valid_low_percent", cfg.p_valid_low_percent) & kwarg("seed", cfg.p_seed);
      end if;
      return kwarg("lanes", cfg.p_lanes);
    elsif cfg.p_interface = rmii and vc.p_kind = source_vc then
      return kwarg("crs_dv_toggle_octets", cfg.p_crs_dv_toggle_octets);
    elsif cfg.p_interface /= xgmii then
      return null_arg;
    elsif vc.p_kind = source_vc then
      return kwarg("lanes", cfg.p_lanes) & kwarg("deficit_idle", cfg.p_deficit_idle);
    end if;
    return kwarg("lanes", cfg.p_lanes) & kwarg("allow_lane4_start", cfg.p_allow_lane4_start);
  end;

  -- The clock cycles of a symbol: RMII at 10 Mbit/s holds every dibit for 10
  -- cycles of its 50 MHz reference clock, every other interface 1
  function symbol_cycles(vc : ethernet_vc_t) return positive is
  begin
    if vc.p_cfg.p_interface = rmii and vc.p_cfg.p_link_rate_mbps = 10 then
      return 10;
    end if;
    return 1;
  end;

  -- A limit of 0 disables it
  function max_limit(value : natural) return natural is
  begin
    if value = 0 then
      return integer'high;
    end if;
    return value;
  end;

  procedure create_backend(vc : ethernet_vc_t; session : python_session_t) is
    constant cfg : ethernet_cfg_t := vc.p_cfg;
    constant common : arg_t :=
      arg(full_name(vc.p_id)) & arg(ethernet_interface_t'image(cfg.p_interface)) &
      kwarg("link_rate_mbps", cfg.p_link_rate_mbps) & phy_options(vc);
  begin
    case vc.p_kind is
      when source_vc =>
        create_backend(session, backend_module, "SourceBackend", common);
      when monitor_vc =>
        create_backend(
          session, backend_module, "MonitorBackend",
          common &
          kwarg("checks", false) &
          kwarg("min_frame_octets", cfg.p_min_frame_octets) &
          kwarg("has_fcs", cfg.p_has_fcs) &
          kwarg("log_frames", cfg.p_log_frames)
        );
      when protocol_checker_vc =>
        create_backend(
          session, backend_module, "ProtocolCheckerBackend",
          common &
          kwarg("min_preamble_octets", cfg.p_min_preamble_octets) &
          kwarg("max_preamble_octets", max_limit(cfg.p_max_preamble_octets)) &
          kwarg("min_frame_octets", cfg.p_min_frame_octets) &
          kwarg("max_frame_octets", max_limit(cfg.p_max_frame_octets)) &
          kwarg("min_ifg_octets", cfg.p_min_ifg_octets) &
          kwarg("has_fcs", cfg.p_has_fcs)
        );
    end case;
  end;

  impure function has_subscribers(actor : actor_t) return boolean is
    variable state : actor_state_t := get_actor_state(actor);
    variable result : boolean;
  begin
    result := state.subscribers /= null;
    if result then
      result := state.subscribers.all'length > 0;
    end if;
    deallocate(state);
    return result;
  end;

  ---------------------------------------------------------------------------
  -- Monitors and protocol checkers
  ---------------------------------------------------------------------------

  type monitor_state_t is record
    session : python_session_t;
    batch : sample_batch_t;
    -- wait_until_idle requests waiting for the end of a frame or of pending requests
    idle_requests : queue_t;
    -- pop requests (stream_pop_msg, pop_ethernet_frame_msg) in arrival order
    pop_requests : queue_t;
    has_pop_request : boolean;
    pop_request : msg_t;
    -- blocking check requests and the number of expected frames including theirs
    check_requests : queue_t;
    check_numbers : queue_t;
    has_check_request : boolean;
    check_request : msg_t;
    check_number : natural;
    expected_frames : natural;
    -- Frames received while a pop was pending, as pop_ethernet_frame_reply_msg
    frames : queue_t;
    -- The frame pop_stream reads
    stream_octets : integer_vector_ptr_t;
    stream_length : natural;
    stream_index : natural;
    -- Whether the backend collects received frames
    collecting : boolean;
    -- Messages are not handled before this time (wait_for_time)
    resume_time : time;
    -- The rest of a frame in progress at a reset is not recorded
    discard_frame : boolean;
  end record;

  procedure init_monitor(vc : ethernet_vc_t; variable state : inout monitor_state_t) is
  begin
    state.session := new_vc_session(vc);
    create_backend(vc, state.session);
    state.batch := new_sample_batch(
      state.session, vc.p_logger, vc.p_checker, vc.p_cfg.p_batch_length, vc.p_cfg.p_delta_unit
    );
    state.idle_requests := new_queue;
    state.pop_requests := new_queue;
    state.has_pop_request := false;
    state.check_requests := new_queue;
    state.check_numbers := new_queue;
    state.has_check_request := false;
    state.check_number := 0;
    state.expected_frames := 0;
    state.frames := new_queue;
    state.stream_octets := null_integer_vector_ptr;
    state.stream_length := 0;
    state.stream_index := 0;
    state.collecting := false;
    state.resume_time := 0 fs;
    state.discard_frame := false;
  end;

  impure function pops_pending(state : monitor_state_t) return boolean is
  begin
    return state.has_pop_request or not is_empty(state.pop_requests);
  end;

  impure function checks_pending(state : monitor_state_t) return boolean is
  begin
    return state.has_check_request or not is_empty(state.check_requests);
  end;

  -- The backend collects frames while someone subscribes to them or a pop is pending
  procedure update_collecting(vc : ethernet_vc_t; variable state : inout monitor_state_t) is
    variable collecting : boolean := false;
  begin
    if vc.p_kind /= monitor_vc then
      return;
    end if;
    collecting := pops_pending(state) or has_subscribers(vc.p_actor);
    if collecting /= state.collecting then
      backend_call(state.session, "set_collect_frames", arg(collecting));
      state.collecting := collecting;
    end if;
  end;

  -- Move the frames the backend collected to the subscribers and the frame queue
  procedure take_frames(signal net : inout network_t; vc : ethernet_vc_t; variable state : inout monitor_state_t) is
    variable values : integer_array_t;
    variable idx : natural := 0;
    variable octets : natural;
    variable fcs_ok : boolean;
    variable frame_msg, publish_msg : msg_t;
    variable subscribed : boolean;

    impure function frame_data(first, num_octets : natural) return std_ulogic_vector is
      variable result : std_ulogic_vector(0 to 8 * num_octets - 1);
    begin
      for octet in 0 to num_octets - 1 loop
        result(8 * octet to 8 * octet + 7) := std_ulogic_vector(to_unsigned(get(values, first + octet), 8));
      end loop;
      return result;
    end;
  begin
    if not state.collecting then
      return;
    end if;
    values := backend_call_integer_array(state.session, "take_frames");
    if length(values) > 0 then
      subscribed := has_subscribers(vc.p_actor);
    end if;
    while idx < length(values) loop
      octets := get(values, idx);
      fcs_ok := get(values, idx + 1) = 1;
      if subscribed then
        publish_msg := new_msg(ethernet_frame_msg);
        push(publish_msg, octets);
        push(publish_msg, fcs_ok);
        push(publish_msg, frame_data(idx + 2, octets));
        publish(net, vc.p_actor, publish_msg);
      end if;
      if pops_pending(state) then
        frame_msg := new_msg(pop_ethernet_frame_reply_msg);
        push(frame_msg, octets);
        push(frame_msg, fcs_ok);
        push(frame_msg, frame_data(idx + 2, octets));
        push(state.frames, frame_msg);
      end if;
      idx := idx + 2 + octets;
    end loop;
    deallocate(values);
  end;

  -- Answer the pending pops that the queued frames can answer, in order
  procedure serve_pops(signal net : inout network_t; variable state : inout monitor_state_t) is
    variable frame_msg, reply_msg : msg_t;
    variable octets : natural;
    variable fcs_ok : boolean;

    procedure load_stream_octets(frame : std_ulogic_vector) is
      constant values : integer_vector := to_octets(frame);
    begin
      for octet in values'range loop
        set(state.stream_octets, octet, values(octet));
      end loop;
    end;
  begin
    loop
      if not state.has_pop_request then
        exit when is_empty(state.pop_requests);
        state.pop_request := pop(state.pop_requests);
        state.has_pop_request := true;
      end if;

      if message_type(state.pop_request) = stream_pop_msg then
        if state.stream_length = 0 then
          exit when is_empty(state.frames);
          frame_msg := pop(state.frames);
          octets := pop(frame_msg);
          fcs_ok := pop(frame_msg);
          if octets = 0 then
            delete(frame_msg);
            next;
          end if;
          state.stream_octets := new_integer_vector_ptr(octets);
          load_stream_octets(pop_std_ulogic_vector(frame_msg));
          delete(frame_msg);
          state.stream_length := octets;
          state.stream_index := 0;
        end if;

        reply_msg := new_msg;
        push_std_ulogic_vector(
          reply_msg, std_ulogic_vector(to_unsigned(get(state.stream_octets, state.stream_index), 8))
        );
        state.stream_index := state.stream_index + 1;
        push_boolean(reply_msg, state.stream_index = state.stream_length);
        if state.stream_index = state.stream_length then
          deallocate(state.stream_octets);
          state.stream_length := 0;
        end if;
        reply(net, state.pop_request, reply_msg);
      else
        exit when is_empty(state.frames);
        reply_msg := pop(state.frames);
        reply(net, state.pop_request, reply_msg);
      end if;
      state.has_pop_request := false;
    end loop;
  end;

  -- Answer the blocking checks of the expected frames the backend has compared
  procedure serve_checks(signal net : inout network_t; variable state : inout monitor_state_t) is
    variable compared : natural;
    variable reply_msg : msg_t;
  begin
    if not checks_pending(state) then
      return;
    end if;
    compared := backend_call_integer(state.session, "compared_count");
    loop
      if not state.has_check_request then
        exit when is_empty(state.check_requests);
        state.check_request := pop(state.check_requests);
        state.check_number := pop(state.check_numbers);
        state.has_check_request := true;
      end if;
      exit when state.check_number > compared;
      reply_msg := new_msg(check_ethernet_frame_reply_msg);
      reply(net, state.check_request, reply_msg);
      state.has_check_request := false;
    end loop;
  end;

  procedure serve_idle_requests(
    signal net : inout network_t;
    variable state : inout monitor_state_t;
    in_frame : boolean
  ) is
    variable request_msg, reply_msg : msg_t;
  begin
    if in_frame or pops_pending(state) or checks_pending(state) then
      return;
    end if;
    while not is_empty(state.idle_requests) loop
      request_msg := pop(state.idle_requests);
      reply_msg := new_msg(wait_until_idle_reply_msg);
      reply(net, request_msg, reply_msg);
    end loop;
  end;

  -- Everything that waits on the backend being up to date
  procedure serve(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout monitor_state_t;
    in_frame : boolean
  ) is
  begin
    flush_samples(state.batch);
    take_frames(net, vc, state);
    serve_pops(net, state);
    serve_checks(net, state);
    update_collecting(vc, state);
    serve_idle_requests(net, state, in_frame);
  end;

  -- A frame ended
  procedure end_monitor_frame(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout monitor_state_t
  ) is
  begin
    update_collecting(vc, state);
    if vc.p_cfg.p_flush_at_frame_end or state.collecting or not is_empty(state.idle_requests) or
      checks_pending(state) then
      serve(net, vc, state, in_frame => false);
    end if;
  end;

  -- Recover a monitor or protocol checker (reset_ethernet_monitor_msg,
  -- reset_ethernet_protocol_checker_msg)
  procedure reset_monitor(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout monitor_state_t;
    clear_statistics : boolean
  ) is
    variable msg : msg_t;
  begin
    flush_samples(state.batch);
    if vc.p_kind = monitor_vc then
      if backend_call_integer(state.session, "reset", arg(clear_statistics)) > 0 then
        log_reports(state.session, vc.p_logger, vc.p_checker);
      end if;
    elsif backend_call_integer(state.session, "reset") > 0 then
      log_reports(state.session, vc.p_logger, vc.p_checker);
    end if;

    while not is_empty(state.frames) loop
      msg := pop(state.frames);
      delete(msg);
    end loop;
    if state.stream_length > 0 then
      deallocate(state.stream_octets);
      state.stream_length := 0;
    end if;

    -- Pending pops are cancelled
    if state.has_pop_request then
      delete(state.pop_request);
      state.has_pop_request := false;
    end if;
    while not is_empty(state.pop_requests) loop
      msg := pop(state.pop_requests);
      delete(msg);
    end loop;

    -- Blocking checks of expected frames the reset forgot return
    if state.has_check_request then
      msg := new_msg(check_ethernet_frame_reply_msg);
      reply(net, state.check_request, msg);
      state.has_check_request := false;
    end if;
    while not is_empty(state.check_requests) loop
      state.check_request := pop(state.check_requests);
      state.check_number := pop(state.check_numbers);
      msg := new_msg(check_ethernet_frame_reply_msg);
      reply(net, state.check_request, msg);
    end loop;
    state.expected_frames := 0;

    state.discard_frame := true;
    update_collecting(vc, state);
    serve_idle_requests(net, state, in_frame => false);
  end;

  procedure handle_monitor_message(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout monitor_state_t;
    in_frame : boolean;
    variable request_msg : inout msg_t
  ) is
    variable msg_type : msg_type_t := message_type(request_msg);
    constant is_monitor : boolean := vc.p_kind = monitor_vc;
    constant is_protocol_checker : boolean := vc.p_kind = protocol_checker_vc;
    variable check : ethernet_check_t;
    variable enabled : boolean;
    variable level : log_level_t;
    variable values : integer_array_t;
    variable reply_msg : msg_t;

    procedure start_capture is
      constant file_name : string := pop_string(request_msg);
      constant include_fcs : boolean := pop(request_msg);
      constant include_errored : boolean := pop(request_msg);
    begin
      backend_call(
        state.session, "start_capture",
        arg_text(file_name) & kwarg("include_fcs", include_fcs) & kwarg("include_errored", include_errored)
      );
    end;

    procedure check_sequence is
      constant function_name : string := pop_string(request_msg);
      constant arguments : arg_t := pop_arg(request_msg);
      constant count : natural := pop(request_msg);
      constant seed : string := pop_string(request_msg);
    begin
      backend_call(state.session, "set_arguments", arguments);
      state.expected_frames := backend_call_integer(
        state.session, "check_sequence", arg(function_name) & kwarg("count", count) & kwarg_text("seed", seed)
      );
    end;

    procedure check_frame is
      constant expected : std_ulogic_vector := pop_std_ulogic_vector(request_msg);
      constant text : string := pop_string(request_msg);
      constant blocking : boolean := pop(request_msg);
    begin
      state.expected_frames := backend_call_integer(
        state.session, "check_mac_octets", arg(to_octets(expected)) & arg_text(text)
      );
      if blocking then
        push(state.check_requests, request_msg);
        push(state.check_numbers, state.expected_frames);
      end if;
    end;
  begin
    flush_samples(state.batch);

    if msg_type = wait_until_idle_msg then
      handle_message(msg_type);
      push(state.idle_requests, request_msg);
      serve(net, vc, state, in_frame);

    elsif msg_type = wait_for_time_msg then
      handle_message(msg_type);
      state.resume_time := now + pop_time(request_msg);
      delete(request_msg);

    elsif is_monitor and (msg_type = pop_ethernet_frame_msg or msg_type = stream_pop_msg) then
      push(state.pop_requests, request_msg);
      update_collecting(vc, state);
      serve_pops(net, state);

    elsif is_monitor and msg_type = check_ethernet_frame_msg then
      check_frame;

    elsif is_monitor and msg_type = check_ethernet_sequence_msg then
      check_sequence;

    elsif is_monitor and msg_type = get_ethernet_statistics_msg then
      values := backend_call_integer_array(state.session, "statistics_values");
      reply_msg := new_msg(get_ethernet_statistics_reply_msg);
      for idx in 0 to length(values) - 1 loop
        push(reply_msg, get(values, idx));
      end loop;
      deallocate(values);
      reply(net, request_msg, reply_msg);

    elsif is_monitor and msg_type = get_ethernet_frame_count_msg then
      reply_msg := new_msg(get_ethernet_frame_count_reply_msg);
      push(reply_msg, backend_call_integer(state.session, "frame_count"));
      reply(net, request_msg, reply_msg);

    elsif is_monitor and msg_type = log_ethernet_statistics_msg then
      level := log_level_t'val(integer'(pop(request_msg)));
      log(vc.p_logger, backend_call_string(state.session, "statistics_summary"), level);

    elsif is_monitor and msg_type = start_ethernet_capture_msg then
      start_capture;

    elsif is_monitor and msg_type = stop_ethernet_capture_msg then
      backend_call(state.session, "stop_captures");

    elsif is_monitor and msg_type = reset_ethernet_monitor_msg then
      reset_monitor(net, vc, state, clear_statistics => pop(request_msg));
      reply_msg := new_msg(reset_ethernet_monitor_reply_msg);
      reply(net, request_msg, reply_msg);

    elsif is_protocol_checker and msg_type = reset_ethernet_protocol_checker_msg then
      reset_monitor(net, vc, state, clear_statistics => false);
      reply_msg := new_msg(reset_ethernet_protocol_checker_reply_msg);
      reply(net, request_msg, reply_msg);

    elsif is_protocol_checker and msg_type = set_ethernet_check_enabled_msg then
      check := ethernet_check_t'val(integer'(pop(request_msg)));
      enabled := pop(request_msg);
      backend_call(state.session, "set_check_enabled", arg(ethernet_check_t'image(check)) & arg(enabled));

    elsif is_protocol_checker and msg_type = get_ethernet_check_count_msg then
      check := ethernet_check_t'val(integer'(pop(request_msg)));
      reply_msg := new_msg(get_ethernet_check_count_reply_msg);
      push(reply_msg, backend_call_integer(state.session, "check_count", arg(ethernet_check_t'image(check))));
      reply(net, request_msg, reply_msg);

    else
      unexpected_msg_type(msg_type, vc);
    end if;
  end;

  procedure handle_monitor_messages(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout monitor_state_t;
    in_frame : boolean
  ) is
    variable msg : msg_t;
  begin
    while now >= state.resume_time and has_message(vc.p_actor) loop
      receive(net, vc.p_actor, msg);
      handle_monitor_message(net, vc, state, in_frame, msg);
    end loop;
  end;

  procedure finish_monitor(vc : ethernet_vc_t; variable state : inout monitor_state_t) is
  begin
    flush_samples(state.batch);
    if backend_call_integer(state.session, "finish") > 0 then
      log_reports(state.session, vc.p_logger, vc.p_checker);
    end if;
  end;

  procedure monitor_symbol_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal dv : in std_ulogic;
    signal er : in std_ulogic
  ) is
    subtype sample_word_t is natural range 0 to 2 ** 12 - 1;
    constant valid_bit : sample_word_t := 2 ** 8;
    constant error_bit : sample_word_t := 2 ** 9;
    constant data_metavalue_bit : sample_word_t := 2 ** 10;
    constant control_metavalue_bit : sample_word_t := 2 ** 11;

    variable state : monitor_state_t;
    variable word : sample_word_t;
    variable previous_word : integer := -1;
    variable in_frame : boolean := false;
    variable finished : boolean := false;

    constant is_rmii : boolean := vc.p_cfg.p_interface = rmii;
    -- RMII at 10 Mbit/s holds every dibit for 10 clock cycles
    constant cycles_per_sample : positive := symbol_cycles(vc);
    -- Sample on the first rising edge, so the line is seen idle before a frame
    variable phase : natural := cycles_per_sample - 1;
    -- Consecutive samples without valid in a frame
    variable idle_samples : natural := 0;

    impure function sample_word return sample_word_t is
      variable result : sample_word_t := to_integer(to_01(unsigned(data)));
    begin
      if to_x01(dv) = '1' then
        result := result + valid_bit;
        if is_x(data) then
          result := result + data_metavalue_bit;
        end if;
      end if;
      if to_x01(er) = '1' then
        result := result + error_bit;
      end if;
      if is_x(dv) or is_x(er) then
        result := result + control_metavalue_bit;
      end if;
      return result;
    end;

    function is_valid(sample : sample_word_t) return boolean is
    begin
      return sample / valid_bit mod 2 = 1;
    end;
  begin
    assert data'length <= 8 report "At most 8 data bits per symbol" severity failure;
    init_monitor(vc, state);

    while not finished loop
      if state.resume_time > now then
        wait on clk, net, runner for state.resume_time - now;
      else
        wait on clk, net, runner;
      end if;

      if rising_edge(clk) then
        phase := (phase + 1) mod cycles_per_sample;
      end if;

      if rising_edge(clk) and phase = 0 then
        word := sample_word;
        if state.discard_frame and not is_valid(word) then
          state.discard_frame := false;
        end if;
        if state.discard_frame then
          null;
        elsif is_valid(word) or word /= previous_word or word >= error_bit or (is_rmii and in_frame) then
          record_sample(state.batch, word);
        end if;

        if is_valid(word) then
          in_frame := true;
          idle_samples := 0;
        elsif in_frame then
          idle_samples := idle_samples + 1;
          if not is_rmii or idle_samples = 2 then
            end_monitor_frame(net, vc, state);
            in_frame := false;
            idle_samples := 0;
          end if;
        end if;
        previous_word := word;
      end if;

      handle_monitor_messages(net, vc, state, in_frame);

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        finish_monitor(vc, state);
        finished := true;
      end if;
    end loop;

    wait;
  end;

  procedure monitor_column_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal ctrl : in std_ulogic_vector
  ) is
    constant lanes : positive := ctrl'length;
    alias data_bits : std_ulogic_vector(8 * lanes - 1 downto 0) is data;
    alias ctrl_bits : std_ulogic_vector(lanes - 1 downto 0) is ctrl;

    subtype sample_word_t is natural range 0 to 2 ** 12 - 1;
    type column_t is array (0 to lanes - 1) of sample_word_t;
    constant control_bit : sample_word_t := 2 ** 8;
    constant data_metavalue_bit : sample_word_t := 2 ** 10;
    constant control_metavalue_bit : sample_word_t := 2 ** 11;
    constant idle_column : column_t := (others => control_bit + 16#07#);

    variable state : monitor_state_t;
    variable column : column_t;
    variable previous_column : column_t := idle_column;
    variable in_frame : boolean := false;
    variable finished : boolean := false;

    impure function sample_column return column_t is
      variable lane_data : std_ulogic_vector(7 downto 0);
      variable result : column_t;
    begin
      for lane in result'range loop
        lane_data := data_bits(8 * lane + 7 downto 8 * lane);
        result(lane) := to_integer(to_01(unsigned(lane_data)));
        if to_x01(ctrl_bits(lane)) = '1' then
          result(lane) := result(lane) + control_bit;
        end if;
        if is_x(lane_data) then
          result(lane) := result(lane) + data_metavalue_bit;
        end if;
        if is_x(ctrl_bits(lane)) then
          result(lane) := result(lane) + control_metavalue_bit;
        end if;
      end loop;
      return result;
    end;
  begin
    assert data'length = 8 * lanes report "XGMII data must have 8 bits per lane" severity failure;
    init_monitor(vc, state);

    while not finished loop
      if state.resume_time > now then
        wait on clk, net, runner for state.resume_time - now;
      else
        wait on clk, net, runner;
      end if;

      if rising_edge(clk) or (vc.p_cfg.p_both_edges and falling_edge(clk)) then
        column := sample_column;
        if state.discard_frame and column = idle_column then
          state.discard_frame := false;
        end if;
        if state.discard_frame then
          null;
        elsif column /= idle_column or column /= previous_column then
          for lane in column'range loop
            record_sample(state.batch, column(lane));
          end loop;
        end if;

        -- Anything but an Idle column is traffic: a frame, an ordered set or
        -- a violation the backend reports
        if in_frame and column = idle_column then
          end_monitor_frame(net, vc, state);
        end if;

        in_frame := column /= idle_column;
        previous_column := column;
      end if;

      handle_monitor_messages(net, vc, state, in_frame);

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        finish_monitor(vc, state);
        finished := true;
      end if;
    end loop;

    wait;
  end;

  ---------------------------------------------------------------------------
  -- Sources
  ---------------------------------------------------------------------------

  type source_state_t is record
    session : python_session_t;
    -- Octets pushed with push_stream since the last one with last
    stream_octets : queue_t;
    stream_length : natural;
    -- The backend sequence a push_ethernet_sequence transmits
    sequence_active : boolean;
    sequence_id : natural;
    -- Messages received while transmitting, handled after the transmission
    pending : queue_t;
    -- A reset request received while transmitting
    has_reset : boolean;
    reset_request : msg_t;
  end record;

  procedure init_source(vc : ethernet_vc_t; variable state : inout source_state_t) is
  begin
    state.session := new_vc_session(vc);
    create_backend(vc, state.session);
    state.stream_octets := new_queue;
    state.stream_length := 0;
    state.sequence_active := false;
    state.sequence_id := 0;
    state.pending := new_queue;
    state.has_reset := false;
  end;

  -- The next message of a source: those received while transmitting first
  procedure next_source_message(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout source_state_t;
    variable msg : inout msg_t
  ) is
  begin
    if is_empty(state.pending) then
      receive(net, vc.p_actor, msg);
    else
      msg := pop(state.pending);
    end if;
  end;

  procedure answer_reset(signal net : inout network_t; variable state : inout source_state_t) is
    variable reply_msg : msg_t := new_msg(reset_ethernet_source_reply_msg);
  begin
    reply(net, state.reset_request, reply_msg);
    state.has_reset := false;
  end;

  -- Forget what a reset drops: the messages received before it, answering
  -- wait_until_idle, octets pushed without last and a sequence in progress
  procedure drop_for_reset(signal net : inout network_t; variable state : inout source_state_t) is
    variable msg, reply_msg : msg_t;
  begin
    while not is_empty(state.pending) loop
      msg := pop(state.pending);
      if message_type(msg) = wait_until_idle_msg then
        reply_msg := new_msg(wait_until_idle_reply_msg);
        reply(net, msg, reply_msg);
      else
        delete(msg);
      end if;
    end loop;
    flush(state.stream_octets);
    state.stream_length := 0;
    state.sequence_active := false;
  end;

  -- Receive the messages that arrived while transmitting. A reset is kept in
  -- reset_request, the others wait in pending.
  procedure receive_during_transmit(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout source_state_t
  ) is
    variable msg : msg_t;
  begin
    while has_message(vc.p_actor) loop
      receive(net, vc.p_actor, msg);
      if message_type(msg) = reset_ethernet_source_msg then
        drop_for_reset(net, state);
        if state.has_reset then
          answer_reset(net, state);
        end if;
        state.reset_request := msg;
        state.has_reset := true;
      else
        push(state.pending, msg);
      end if;
    end loop;
  end;

  -- A call of the backend returning the sample words to transmit, kept until
  -- the source transmits them. A method of null means there is none.
  type symbols_call_t is record
    method : line;
    arg_name : line;
    arg_value : line;
  end record;

  procedure clear(variable call : inout symbols_call_t) is
  begin
    deallocate(call.method);
    deallocate(call.arg_name);
    deallocate(call.arg_value);
  end;

  procedure set(variable call : inout symbols_call_t; method : string; args : arg_t := null_arg) is
  begin
    clear(call);
    call.method := new string'(method);
    call.arg_name := new string'(args.name);
    call.arg_value := new string'(args.value);
  end;

  procedure get_symbols(
    session : python_session_t; variable call : in symbols_call_t; variable symbols : out integer_array_t
  ) is
  begin
    symbols := backend_call_integer_array(
      session, call.method.all, arg_t'(name => call.arg_name.all, value => call.arg_value.all)
    );
  end;

  -- Handle the messages every source handles. symbols_call is set to the
  -- backend call returning the sample words to transmit, if any.
  procedure handle_source_message(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    variable state : inout source_state_t;
    variable msg_type : inout msg_type_t;
    variable msg : inout msg_t;
    variable symbols_call : inout symbols_call_t
  ) is
    impure function stream_octets return integer_vector is
      variable octets : integer_vector(0 to state.stream_length - 1);
    begin
      for idx in octets'range loop
        octets(idx) := pop(state.stream_octets);
      end loop;
      state.stream_length := 0;
      return octets;
    end;

    procedure push_packet is
      constant function_name : string := pop_string(msg);
      constant arguments : arg_t := pop_arg(msg);
    begin
      -- The arguments of the user's function are given separately, so they
      -- never collide with the transmission options
      backend_call(state.session, "set_arguments", arguments);
      set(symbols_call, "function_symbols", arg(function_name) & pop_transmit_options(msg));
    end;

    procedure push_sequence is
      constant function_name : string := pop_string(msg);
      constant arguments : arg_t := pop_arg(msg);
      constant count : natural := pop(msg);
      constant seed : string := pop_string(msg);
    begin
      backend_call(state.session, "set_arguments", arguments);
      state.sequence_id := backend_call_integer(
        state.session, "start_sequence", arg(function_name) & kwarg("count", count) & kwarg_text("seed", seed)
      );
      state.sequence_active := true;
      set(symbols_call, "sequence_symbols", arg(state.sequence_id));
    end;

    procedure push_stream_octet is
      constant octet : std_ulogic_vector := pop_std_ulogic_vector(msg);
      constant last : boolean := pop_boolean(msg);
    begin
      if octet'length /= 8 then
        check_failed(
          vc.p_checker,
          "push_stream data of an Ethernet source is one octet, got " & integer'image(octet'length) & " bits"
        );
      else
        push(state.stream_octets, to_integer(to_01(unsigned(octet))));
        state.stream_length := state.stream_length + 1;
      end if;
      if last and state.stream_length > 0 then
        set(symbols_call, "symbols", arg(stream_octets));
      end if;
    end;
  begin
    clear(symbols_call);

    if msg_type = push_ethernet_frame_msg then
      handle_message(msg_type);
      set(symbols_call, "symbols", arg(to_octets(pop_std_ulogic_vector(msg))) & pop_transmit_options(msg));

    elsif msg_type = push_ethernet_packet_msg then
      handle_message(msg_type);
      push_packet;

    elsif msg_type = push_ethernet_sequence_msg then
      handle_message(msg_type);
      push_sequence;

    elsif msg_type = stream_push_msg then
      handle_message(msg_type);
      push_stream_octet;

    elsif msg_type = wait_until_idle_msg and state.stream_length > 0 then
      check_failed(
        vc.p_checker,
        integer'image(state.stream_length) & " octets were pushed with push_stream without last"
      );
      flush(state.stream_octets);
      state.stream_length := 0;
    end if;
  end;

  -- Whether a message transmits, so the line is not returned to idle before it
  function is_transmit_msg_type(msg_type : msg_type_t) return boolean is
  begin
    return msg_type = push_ethernet_frame_msg or msg_type = push_ethernet_packet_msg or
      msg_type = push_ethernet_sequence_msg or msg_type = stream_push_msg or msg_type = push_xgmii_columns_msg or msg_type = push_xgmii_link_fault_msg;
  end;

  procedure drive_symbol_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal dv : out std_ulogic;
    signal er : out std_ulogic
  ) is
    variable state : source_state_t;
    variable msg : msg_t;
    variable msg_type : msg_type_t;
    variable symbols_call : symbols_call_t;
    variable symbols : integer_array_t;
    variable word : natural range 0 to 2 ** 10 - 1;
    variable valid : boolean := false;
    -- RMII at 10 Mbit/s holds every dibit for 10 clock cycles
    constant cycles_per_symbol : positive := symbol_cycles(vc);

    -- Wait for the next rising edge, or for a reset, which may arrive while
    -- the clock is stopped
    procedure wait_for_edge is
    begin
      loop
        receive_during_transmit(net, vc, state);
        exit when state.has_reset;
        wait on clk, net until rising_edge(clk) or has_message(vc.p_actor);
        if rising_edge(clk) then
          receive_during_transmit(net, vc, state);
          exit;
        end if;
      end loop;
    end;

    procedure drive_idle is
    begin
      data <= (data'range => '0');
      dv <= '0';
      er <= '0';
      valid := false;
    end;

    -- Deassert valid at once, which ends a frame in progress at a symbol boundary
    procedure abort_for_reset is
    begin
      drive_idle;
      clear(symbols_call);
      answer_reset(net, state);
    end;
  begin
    init_source(vc, state);

    loop
      next_source_message(net, vc, state, msg);
      msg_type := message_type(msg);

      if msg_type = reset_ethernet_source_msg then
        handle_message(msg_type);
        drop_for_reset(net, state);
        state.reset_request := msg;
        abort_for_reset;
      else
        handle_source_message(net, vc, state, msg_type, msg, symbols_call);
        handle_sync_message(net, msg_type, msg);
      end if;

      -- A frame, or the batches of a sequence until it is exhausted
      while symbols_call.method /= null loop
        get_symbols(state.session, symbols_call, symbols);
        if length(symbols) = 0 or not state.sequence_active then
          clear(symbols_call);
        end if;
        for idx in 0 to length(symbols) - 1 loop
          wait_for_edge;
          exit when state.has_reset;
          word := get(symbols, idx);
          data <= std_ulogic_vector(to_unsigned(word mod 2 ** data'length, data'length));
          valid := word / 2 ** 8 mod 2 = 1;
          dv <= '1' when valid else '0';
          er <= '1' when word / 2 ** 9 mod 2 = 1 else '0';
          for hold in 2 to cycles_per_symbol loop
            wait_for_edge;
            exit when state.has_reset;
          end loop;
          exit when state.has_reset;
        end loop;
        deallocate(symbols);
        if state.has_reset then
          abort_for_reset;
        end if;
      end loop;
      state.sequence_active := false;

      -- A frame without IFG is followed by the next frame if there is one
      if valid and is_empty(state.pending) and not has_message(vc.p_actor) then
        wait_for_edge;
        if state.has_reset then
          abort_for_reset;
        else
          drive_idle;
        end if;
      end if;

      unexpected_msg_type(msg_type, vc);
    end loop;
  end;

  procedure combine_double_edges(
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal ctl : in std_ulogic;
    signal octet : out std_ulogic_vector;
    signal dv : out std_ulogic;
    signal er : out std_ulogic
  ) is
    constant gigabit : boolean := vc.p_cfg.p_link_rate_mbps = 1000;
    variable low : std_ulogic_vector(data'length - 1 downto 0) := (others => '0');
    variable rising_ctl : std_ulogic := '0';
  begin
    loop
      wait on clk;
      if rising_edge(clk) then
        low := data;
        rising_ctl := ctl;
      elsif falling_edge(clk) then
        -- At 10 and 100 Mbit/s the falling edge may repeat the nibble; only the
        -- rising edge carries it
        if gigabit then
          octet <= data & low;
        else
          octet <= (octet'length - 1 downto low'length => '0') & low;
        end if;
        dv <= rising_ctl;
        er <= rising_ctl xor ctl;
      end if;
    end loop;
  end;

  procedure split_double_edges(
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal octet : in std_ulogic_vector;
    signal dv : in std_ulogic;
    signal er : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal ctl : out std_ulogic
  ) is
    constant gigabit : boolean := vc.p_cfg.p_link_rate_mbps = 1000;
    constant edge_aligned : boolean := vc.p_cfg.p_edge_aligned;
    -- The symbol of a clock cycle, taken at its first half so both halves match
    variable symbol : std_ulogic_vector(octet'length - 1 downto 0) := (others => '0');
    variable symbol_dv, symbol_er : std_ulogic := '0';
  begin
    loop
      wait on clk;
      -- The rising edge half: the lower bits and valid
      if (rising_edge(clk) and edge_aligned) or (falling_edge(clk) and not edge_aligned) then
        symbol := octet;
        symbol_dv := dv;
        symbol_er := er;
        data <= symbol(data'length - 1 downto 0);
        ctl <= symbol_dv;
      -- The falling edge half: the upper bits and valid xor error
      elsif (falling_edge(clk) and edge_aligned) or (rising_edge(clk) and not edge_aligned) then
        if gigabit then
          data <= symbol(2 * data'length - 1 downto data'length);
        else
          data <= symbol(data'length - 1 downto 0);
        end if;
        ctl <= symbol_dv xor symbol_er;
      end if;
    end loop;
  end;

  procedure drive_column_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal ctrl : out std_ulogic_vector
  ) is
    constant lanes : positive := ctrl'length;
    constant idle_character : std_ulogic_vector(7 downto 0) := x"07";
    constant error_character : std_ulogic_vector(7 downto 0) := x"FE";

    variable state : source_state_t;
    variable msg : msg_t;
    variable msg_type : msg_type_t;
    variable symbols_call : symbols_call_t;
    variable idle : boolean := true;
    variable transmitted : boolean;

    -- Wait for the next column edge, or for a reset, which may arrive while
    -- the clock is stopped
    procedure wait_for_edge is
    begin
      loop
        receive_during_transmit(net, vc, state);
        exit when state.has_reset;
        wait on clk, net until rising_edge(clk) or (vc.p_cfg.p_both_edges and falling_edge(clk)) or
          has_message(vc.p_actor);
        if rising_edge(clk) or (vc.p_cfg.p_both_edges and falling_edge(clk)) then
          receive_during_transmit(net, vc, state);
          exit;
        end if;
      end loop;
    end;

    procedure drive_column(character : std_ulogic_vector(7 downto 0)) is
      variable column_data : std_ulogic_vector(8 * lanes - 1 downto 0);
    begin
      for lane in 0 to lanes - 1 loop
        column_data(8 * lane + 7 downto 8 * lane) := character;
      end loop;
      data <= column_data;
      ctrl <= (ctrl'range => '1');
    end;

    procedure drive_idle is
    begin
      drive_column(idle_character);
      idle := true;
    end;

    -- An Error column at once ends a frame in progress, Idle follows
    procedure abort_for_reset is
    begin
      drive_column(error_character);
      idle := false;
      clear(symbols_call);
      answer_reset(net, state);
      wait_for_edge;
      if state.has_reset then
        answer_reset(net, state);
      end if;
      drive_idle;
    end;

    procedure drive(symbols : integer_array_t) is
      variable word : natural range 0 to 2 ** 9 - 1;
      variable column_data : std_ulogic_vector(8 * lanes - 1 downto 0);
      variable column_ctrl : std_ulogic_vector(lanes - 1 downto 0);
    begin
      for column in 0 to length(symbols) / lanes - 1 loop
        wait_for_edge;
        exit when state.has_reset;
        idle := true;
        for lane in 0 to lanes - 1 loop
          word := get(symbols, column * lanes + lane);
          column_data(8 * lane + 7 downto 8 * lane) := std_ulogic_vector(to_unsigned(word mod 2 ** 8, 8));
          column_ctrl(lane) := '1' when word / 2 ** 8 = 1 else '0';
          if word /= 2 ** 8 + 16#07# then
            idle := false;
          end if;
        end loop;
        data <= column_data;
        ctrl <= column_ctrl;
      end loop;

      if state.has_reset then
        abort_for_reset;
      -- Columns that do not end in Idle are followed by the next transmit
      -- request, or by Idle when there is none
      elsif not idle and is_empty(state.pending) and not has_message(vc.p_actor) then
        wait_for_edge;
        if state.has_reset then
          abort_for_reset;
        else
          drive_idle;
        end if;
      end if;
    end;

    -- Transmit what the backend call returns; transmitted is false when that is nothing
    procedure transmit(variable call : in symbols_call_t; variable transmitted : out boolean) is
      variable symbols : integer_array_t;
    begin
      get_symbols(state.session, call, symbols);
      transmitted := length(symbols) > 0;
      drive(symbols);
      deallocate(symbols);
    end;

    procedure set_columns_call(variable call : inout symbols_call_t; request_msg : msg_t) is
      constant column_data : std_ulogic_vector := pop_std_ulogic_vector(request_msg);
      constant column_control : std_ulogic_vector := pop_std_ulogic_vector(request_msg);
      alias control_bits : std_ulogic_vector(0 to column_control'length - 1) is column_control;
      variable control_values : integer_vector(control_bits'range);
    begin
      for idx in control_bits'range loop
        control_values(idx) := 1 when to_x01(control_bits(idx)) = '1' else 0;
      end loop;
      set(call, "column_symbols", arg(to_octets(column_data)) & arg(control_values));
    end;

    procedure set_link_fault_call(variable call : inout symbols_call_t; request_msg : msg_t) is
      -- The ordered set value of local fault is 1, of remote fault 2
      constant fault : xgmii_link_fault_t := xgmii_link_fault_t'val(integer'(pop(request_msg)));
      constant columns : positive := pop(request_msg);
    begin
      set(call, "ordered_set_symbols", arg(xgmii_link_fault_t'pos(fault) + 1) & arg(columns));
    end;
  begin
    assert data'length = 8 * lanes report "XGMII data must have 8 bits per lane" severity failure;
    init_source(vc, state);
    drive_idle;

    loop
      next_source_message(net, vc, state, msg);
      msg_type := message_type(msg);

      if msg_type = reset_ethernet_source_msg then
        handle_message(msg_type);
        drop_for_reset(net, state);
        state.reset_request := msg;
        if idle then
          answer_reset(net, state);
        else
          abort_for_reset;
        end if;
      else
        -- Any other request, such as wait_until_idle, finds the line Idle, and
        -- monitors have sampled the last transmitted column when it is handled
        if not idle and not is_transmit_msg_type(msg_type) then
          wait_for_edge;
          if state.has_reset then
            abort_for_reset;
          else
            drive_idle;
          end if;
        end if;

        if msg_type = push_xgmii_columns_msg then
          handle_message(msg_type);
          set_columns_call(symbols_call, msg);
          transmit(symbols_call, transmitted);
          clear(symbols_call);
        elsif msg_type = push_xgmii_link_fault_msg then
          handle_message(msg_type);
          set_link_fault_call(symbols_call, msg);
          transmit(symbols_call, transmitted);
          clear(symbols_call);
        else
          handle_source_message(net, vc, state, msg_type, msg, symbols_call);
          handle_sync_message(net, msg_type, msg);
          -- A frame, or the batches of a sequence until it is exhausted
          while symbols_call.method /= null loop
            transmit(symbols_call, transmitted);
            if not transmitted or not state.sequence_active then
              clear(symbols_call);
            end if;
          end loop;
          state.sequence_active := false;
        end if;
      end if;

      unexpected_msg_type(msg_type, vc);
    end loop;
  end;
  procedure monitor_axis_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal tdata : in std_ulogic_vector;
    signal tkeep : in std_ulogic_vector;
    signal tvalid : in std_ulogic;
    signal tready : in std_ulogic;
    signal tlast : in std_ulogic;
    signal tuser : in std_ulogic_vector
  ) is
    constant lanes : positive := tkeep'length;
    alias data_bits : std_ulogic_vector(8 * lanes - 1 downto 0) is tdata;
    alias keep_bits : std_ulogic_vector(lanes - 1 downto 0) is tkeep;
    alias user_bits : std_ulogic_vector(tuser'length - 1 downto 0) is tuser;

    subtype sample_word_t is natural range 0 to 2 ** 16 - 1;
    type column_t is array (0 to lanes - 1) of sample_word_t;
    constant keep_bit : sample_word_t := 2 ** 8;
    constant user_bit : sample_word_t := 2 ** 9;
    constant data_metavalue_bit : sample_word_t := 2 ** 10;
    constant control_metavalue_bit : sample_word_t := 2 ** 11;
    constant valid_bit : sample_word_t := 2 ** 13;
    constant ready_bit : sample_word_t := 2 ** 14;
    constant last_bit : sample_word_t := 2 ** 15;

    variable state : monitor_state_t;
    variable column : column_t;
    variable previous_column : column_t := (others => 0);
    variable recorded : boolean := false;
    variable valid, handshake, last : boolean;
    variable in_frame : boolean := false;
    variable finished : boolean := false;

    impure function sample_column return column_t is
      variable control : sample_word_t := 0;
      variable lane_data : std_ulogic_vector(7 downto 0);
      variable result : column_t;
      variable sampled_valid : boolean;
    begin
      sampled_valid := to_x01(tvalid) = '1';
      if sampled_valid then
        control := control + valid_bit;
      end if;
      if to_x01(tready) = '1' then
        control := control + ready_bit;
      end if;
      if sampled_valid and to_x01(tlast) = '1' then
        control := control + last_bit;
      end if;
      if sampled_valid and to_x01(user_bits(0)) = '1' then
        control := control + user_bit;
      end if;
      if is_x(tvalid) or is_x(tready) or (sampled_valid and (is_x(tlast) or is_x(keep_bits) or is_x(user_bits))) then
        control := control + control_metavalue_bit;
      end if;
      for lane in result'range loop
        result(lane) := control;
        if sampled_valid then
          lane_data := data_bits(8 * lane + 7 downto 8 * lane);
          result(lane) := result(lane) + to_integer(to_01(unsigned(lane_data)));
          if to_x01(keep_bits(lane)) = '1' then
            result(lane) := result(lane) + keep_bit;
            if is_x(lane_data) then
              result(lane) := result(lane) + data_metavalue_bit;
            end if;
          end if;
        end if;
      end loop;
      return result;
    end;
  begin
    assert tdata'length = 8 * lanes report "AXI-Stream tdata must have 8 bits per tkeep bit" severity failure;
    init_monitor(vc, state);

    while not finished loop
      if state.resume_time > now then
        wait on clk, net, runner for state.resume_time - now;
      else
        wait on clk, net, runner;
      end if;

      if rising_edge(clk) then
        column := sample_column;
        valid := column(0) / valid_bit mod 2 = 1;
        handshake := valid and column(0) / ready_bit mod 2 = 1;
        last := handshake and column(0) / last_bit mod 2 = 1;
        if state.discard_frame then
          -- The rest of a frame in progress when the monitor was reset: until
          -- tlast, or until tvalid is low, as a source that was reset leaves it
          if last or not valid then
            state.discard_frame := false;
          end if;
        elsif valid or column /= previous_column or not recorded then
          for lane in column'range loop
            record_sample(state.batch, column(lane));
          end loop;
          recorded := true;
        end if;

        if last then
          end_monitor_frame(net, vc, state);
        end if;
        if handshake then
          in_frame := not last;
        end if;
        previous_column := column;
      end if;

      handle_monitor_messages(net, vc, state, in_frame);
      -- A reset forgets the frame in progress
      if state.discard_frame then
        in_frame := false;
      end if;

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        finish_monitor(vc, state);
        finished := true;
      end if;
    end loop;

    wait;
  end;

  procedure drive_axis_interface(
    signal net : inout network_t;
    vc : ethernet_vc_t;
    signal clk : in std_ulogic;
    signal tdata : out std_ulogic_vector;
    signal tkeep : out std_ulogic_vector;
    signal tvalid : out std_ulogic;
    signal tready : in std_ulogic;
    signal tlast : out std_ulogic;
    signal tuser : out std_ulogic_vector
  ) is
    constant lanes : positive := tkeep'length;

    variable state : source_state_t;
    variable msg : msg_t;
    variable msg_type : msg_type_t;
    variable symbols_call : symbols_call_t;
    variable symbols : integer_array_t;
    variable word : natural;
    variable valid : boolean;
    variable column_data : std_ulogic_vector(8 * lanes - 1 downto 0);
    variable column_keep : std_ulogic_vector(lanes - 1 downto 0);
    variable column_user : std_ulogic_vector(tuser'length - 1 downto 0);

    -- Wait for the next rising edge, or for a reset, which may arrive while
    -- the clock is stopped
    procedure wait_for_edge is
    begin
      loop
        receive_during_transmit(net, vc, state);
        exit when state.has_reset;
        wait on clk, net until rising_edge(clk) or has_message(vc.p_actor);
        if rising_edge(clk) then
          receive_during_transmit(net, vc, state);
          exit;
        end if;
      end loop;
    end;

    procedure drive_idle is
    begin
      tdata <= (tdata'range => '0');
      tkeep <= (tkeep'range => '0');
      tvalid <= '0';
      tlast <= '0';
      tuser <= (tuser'range => '0');
    end;

    -- Deassert tvalid at once, which abandons a frame in progress, and keep it
    -- low for a clock edge, so monitors see the frame end before the next one
    procedure abort_for_reset is
    begin
      drive_idle;
      clear(symbols_call);
      answer_reset(net, state);
      wait_for_edge;
      if state.has_reset then
        answer_reset(net, state);
      end if;
    end;

    -- Drive one beat, or a clock with tvalid low, and wait until it is accepted
    procedure drive_column(column : natural) is
    begin
      word := get(symbols, column * lanes);
      valid := word / 2 ** 13 mod 2 = 1;
      if valid then
        for lane in 0 to lanes - 1 loop
          word := get(symbols, column * lanes + lane);
          column_data(8 * lane + 7 downto 8 * lane) := std_ulogic_vector(to_unsigned(word mod 2 ** 8, 8));
          column_keep(lane) := '1' when word / 2 ** 8 mod 2 = 1 else '0';
        end loop;
        word := get(symbols, column * lanes);
        column_user := (others => '0');
        column_user(0) := '1' when word / 2 ** 9 mod 2 = 1 else '0';
        tdata <= column_data;
        tkeep <= column_keep;
        tlast <= '1' when word / 2 ** 15 mod 2 = 1 else '0';
        tuser <= column_user;
        tvalid <= '1';
      else
        drive_idle;
      end if;
      loop
        wait_for_edge;
        exit when state.has_reset or not valid or to_x01(tready) = '1';
      end loop;
    end;
  begin
    assert tdata'length = 8 * lanes report "AXI-Stream tdata must have 8 bits per tkeep bit" severity failure;
    init_source(vc, state);

    loop
      next_source_message(net, vc, state, msg);
      msg_type := message_type(msg);

      if msg_type = reset_ethernet_source_msg then
        handle_message(msg_type);
        drop_for_reset(net, state);
        state.reset_request := msg;
        abort_for_reset;
      else
        handle_source_message(net, vc, state, msg_type, msg, symbols_call);
        handle_sync_message(net, msg_type, msg);
      end if;

      -- A frame, or the batches of a sequence until it is exhausted
      while symbols_call.method /= null loop
        get_symbols(state.session, symbols_call, symbols);
        if length(symbols) = 0 or not state.sequence_active then
          clear(symbols_call);
        end if;
        for column in 0 to length(symbols) / lanes - 1 loop
          drive_column(column);
          exit when state.has_reset;
        end loop;
        deallocate(symbols);
        if state.has_reset then
          abort_for_reset;
        else
          drive_idle;
        end if;
      end loop;
      state.sequence_active := false;

      unexpected_msg_type(msg_type, vc);
    end loop;
  end;
end package body;
