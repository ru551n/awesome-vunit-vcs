-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The part of the Ethernet verification component entities that does not
-- depend on the PHY: the messages of a monitor, answering wait_until_idle at
-- the end of a frame, the final checks of a monitor and the backend
-- expression a source transmits for a frame. Testbenches use ethernet_pkg;
-- this package is for the entities.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;
use vunit_lib.integer_array_pkg.all;

library python_bridge;
context python_bridge.python_context;

use work.ethernet_pkg.all;
use work.vcs_python_pkg.all;

package ethernet_vc_pkg is
  -- Handle a message sent to a monitor. Everything sampled so far reaches the
  -- backend first. A wait_until_idle request is answered at once unless
  -- in_frame, in which case it waits in idle_requests for the end of the frame.
  procedure handle_monitor_message(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    session : python_session_t;
    variable batch : inout sample_batch_t;
    idle_requests : queue_t;
    in_frame : boolean;
    variable request_msg : inout msg_t
  );

  -- A frame ended: send the samples to the backend when the monitor flushes
  -- at frame ends or someone waits for the frame, then answer the waiting
  -- wait_until_idle requests
  procedure end_monitor_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable batch : inout sample_batch_t;
    idle_requests : queue_t
  );

  -- The final checks of a monitor when the test ends
  procedure finish_monitor(
    monitor : ethernet_monitor_t;
    session : python_session_t;
    variable batch : inout sample_batch_t
  );

  -- The expression of the source backend that returns the sample words of an
  -- ethernet_send_frame_msg or ethernet_send_packet_msg
  impure function transmit_expression(msg_type : msg_type_t; msg : msg_t) return string;

  -- The octets of a vector, leftmost octet first
  function to_octets(value : std_ulogic_vector) return integer_vector;
end package;

package body ethernet_vc_pkg is
  procedure reply_idle(signal net : inout network_t; variable request_msg : inout msg_t) is
    variable reply_msg : msg_t := new_msg(wait_until_idle_reply_msg);
  begin
    reply(net, request_msg, reply_msg);
  end;

  procedure reply_integer(signal net : inout network_t; variable request_msg : inout msg_t; value : integer) is
    variable reply_msg : msg_t := new_msg(ethernet_reply_msg);
  begin
    push(reply_msg, value);
    reply(net, request_msg, reply_msg);
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

  procedure handle_monitor_message(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    session : python_session_t;
    variable batch : inout sample_batch_t;
    idle_requests : queue_t;
    in_frame : boolean;
    variable request_msg : inout msg_t
  ) is
    constant msg_type : msg_type_t := message_type(request_msg);
    variable check : ethernet_check_t;
    variable enabled : boolean;
    variable level : log_level_t;
    variable values : integer_array_t;
    variable statistics_reply_msg : msg_t;

    procedure start_capture is
      constant file_name : string := pop_string(request_msg);
      constant include_fcs : boolean := pop(request_msg);
      constant include_errored : boolean := pop(request_msg);
    begin
      backend_exec(
        session,
        "start_capture(" & py_str(file_name) &
        ", include_fcs=" & py_bool(include_fcs) &
        ", include_errored=" & py_bool(include_errored) & ")"
      );
    end;
  begin
    flush_samples(batch);

    if msg_type = wait_until_idle_msg then
      if in_frame then
        push(idle_requests, request_msg);
      else
        reply_idle(net, request_msg);
      end if;

    elsif msg_type = ethernet_set_check_enabled_msg then
      check := ethernet_check_t'val(integer'(pop(request_msg)));
      enabled := pop(request_msg);
      backend_exec(
        session,
        "set_check_enabled(" & py_str(ethernet_check_t'image(check)) & ", " & py_bool(enabled) & ")"
      );

    elsif msg_type = ethernet_get_check_count_msg then
      check := ethernet_check_t'val(integer'(pop(request_msg)));
      reply_integer(
        net, request_msg, backend_integer(session, "check_count(" & py_str(ethernet_check_t'image(check)) & ")")
      );

    elsif msg_type = ethernet_get_frame_count_msg then
      reply_integer(net, request_msg, backend_integer(session, "frame_count()"));

    elsif msg_type = ethernet_get_statistics_msg then
      values := backend_integer_array(session, "statistics_values()");
      statistics_reply_msg := new_msg(ethernet_reply_msg);
      for idx in 0 to length(values) - 1 loop
        push(statistics_reply_msg, get(values, idx));
      end loop;
      deallocate(values);
      reply(net, request_msg, statistics_reply_msg);

    elsif msg_type = ethernet_log_statistics_msg then
      level := log_level_t'val(integer'(pop(request_msg)));
      log(get_logger(monitor), backend_string(session, "statistics_summary()"), level);

    elsif msg_type = ethernet_expect_frame_msg then
      call("vc.expect_payload", arg(to_octets(pop_std_ulogic_vector(request_msg))), session => session);

    elsif msg_type = ethernet_start_capture_msg then
      start_capture;

    elsif msg_type = ethernet_stop_capture_msg then
      backend_exec(session, "stop_captures()");

    else
      unexpected_msg_type(msg_type, monitor.p_std_cfg);
    end if;
  end;

  procedure end_monitor_frame(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    variable batch : inout sample_batch_t;
    idle_requests : queue_t
  ) is
    variable request_msg : msg_t;
  begin
    if monitor.p_flush_at_frame_end or not is_empty(idle_requests) then
      flush_samples(batch);
    end if;
    while not is_empty(idle_requests) loop
      request_msg := pop(idle_requests);
      reply_idle(net, request_msg);
    end loop;
  end;

  procedure finish_monitor(
    monitor : ethernet_monitor_t;
    session : python_session_t;
    variable batch : inout sample_batch_t
  ) is
  begin
    flush_samples(batch);
    if backend_integer(session, "finish()") > 0 then
      log_reports(session, get_logger(monitor), get_checker(monitor));
    end if;
  end;

  impure function transmit_expression(msg_type : msg_type_t; msg : msg_t) return string is
    impure function frame_expression return string is
      constant frame : std_ulogic_vector := pop_std_ulogic_vector(msg);
    begin
      return "symbols(" & py_int_list(to_octets(frame)) & ", " & pop_transmit_options(msg) & ")";
    end;

    impure function packet_expression return string is
      constant scapy_expression : string := pop_string(msg);
    begin
      return "packet_symbols(" & py_str(scapy_expression) & ", " & pop_transmit_options(msg) & ")";
    end;
  begin
    if msg_type = ethernet_send_frame_msg then
      return frame_expression;
    end if;
    assert msg_type = ethernet_send_packet_msg
      report "transmit_expression of a message that is not a frame or packet" severity failure;
    return packet_expression;
  end;
end package body;
