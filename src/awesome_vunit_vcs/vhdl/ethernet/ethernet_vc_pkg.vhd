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
  -- The process of a monitor of an interface carrying one symbol per clock
  -- cycle with valid and error signals (GMII, MII). data, dv and er are
  -- sampled on the rising edge of clk. A sample is recorded when valid is
  -- asserted or the sample word changes, so a long idle period costs one
  -- sample. Sample words (see awesome_vunit_vcs/ethernet/phy/common.py):
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
    monitor : ethernet_monitor_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal dv : in std_ulogic;
    signal er : in std_ulogic
  );

  -- The process of a source of an interface carrying one symbol per clock
  -- cycle with valid and error signals (GMII, MII). The sample words the
  -- backend returns for a frame are driven one per rising edge of clk.
  -- Never returns.
  procedure drive_symbol_interface(
    signal net : inout network_t;
    source : ethernet_source_t;
    signal clk : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal dv : out std_ulogic;
    signal er : out std_ulogic
  );
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
      call("vc.expect_mac_octets", arg(to_octets(pop_std_ulogic_vector(request_msg))), session => session);

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
  procedure monitor_symbol_interface(
    signal net : inout network_t;
    monitor : ethernet_monitor_t;
    signal clk : in std_ulogic;
    signal data : in std_ulogic_vector;
    signal dv : in std_ulogic;
    signal er : in std_ulogic
  ) is
    constant session : python_session_t := new_vc_session(get_id(monitor));
    constant actor : actor_t := as_sync(monitor);
    -- wait_until_idle requests waiting for the end of a frame
    constant idle_requests : queue_t := new_queue;

    subtype sample_word_t is natural range 0 to 2 ** 12 - 1;
    constant valid_bit : sample_word_t := 2 ** 8;
    constant error_bit : sample_word_t := 2 ** 9;
    constant data_metavalue_bit : sample_word_t := 2 ** 10;
    constant control_metavalue_bit : sample_word_t := 2 ** 11;

    variable batch : sample_batch_t;
    variable word : sample_word_t;
    variable previous_word : integer := -1;
    variable in_frame : boolean := false;
    variable finished : boolean := false;
    variable msg : msg_t;

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
    create_backend(session, ethernet_backend_module, ethernet_monitor_backend_class, backend_arguments(monitor));
    batch := new_sample_batch(
      session, get_logger(monitor), get_checker(monitor), monitor.p_batch_length, monitor.p_delta_unit
    );

    while not finished loop
      wait on clk, net, runner;

      if rising_edge(clk) then
        word := sample_word;
        if is_valid(word) or word /= previous_word or word >= error_bit then
          record_sample(batch, word);
        end if;

        if in_frame and not is_valid(word) then
          end_monitor_frame(net, monitor, batch, idle_requests);
        end if;

        in_frame := is_valid(word);
        previous_word := word;
      end if;

      while has_message(actor) loop
        receive(net, actor, msg);
        handle_monitor_message(net, monitor, session, batch, idle_requests, in_frame, msg);
      end loop;

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        finish_monitor(monitor, session, batch);
        finished := true;
      end if;
    end loop;

    wait;
  end;

  procedure drive_symbol_interface(
    signal net : inout network_t;
    source : ethernet_source_t;
    signal clk : in std_ulogic;
    signal data : out std_ulogic_vector;
    signal dv : out std_ulogic;
    signal er : out std_ulogic
  ) is
    constant session : python_session_t := new_vc_session(get_id(source));
    constant actor : actor_t := as_sync(source);

    variable msg : msg_t;
    variable msg_type : msg_type_t;
    variable symbols : integer_array_t;
    variable word : natural range 0 to 2 ** 10 - 1;
    variable valid : boolean := false;
  begin
    create_backend(session, ethernet_backend_module, ethernet_source_backend_class, backend_arguments(source));

    loop
      receive(net, actor, msg);
      msg_type := message_type(msg);

      handle_sync_message(net, msg_type, msg);

      if msg_type = ethernet_send_frame_msg or msg_type = ethernet_send_packet_msg then
        symbols := backend_integer_array(session, transmit_expression(msg_type, msg));
        for idx in 0 to length(symbols) - 1 loop
          wait until rising_edge(clk);
          word := get(symbols, idx);
          data <= std_ulogic_vector(to_unsigned(word mod 2 ** data'length, data'length));
          valid := word / 2 ** 8 mod 2 = 1;
          dv <= '1' when valid else '0';
          er <= '1' when word / 2 ** 9 mod 2 = 1 else '0';
        end loop;
        deallocate(symbols);

        -- A frame without IFG is followed by the next frame if there is one
        if valid and not has_message(actor) then
          wait until rising_edge(clk);
          data <= (data'range => '0');
          dv <= '0';
          er <= '0';
          valid := false;
        end if;
      else
        unexpected_msg_type(msg_type, source.p_std_cfg);
      end if;
    end loop;
  end;
end package body;
