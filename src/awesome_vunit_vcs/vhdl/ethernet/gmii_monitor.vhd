-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive GMII monitor: samples one direction of a GMII interface on the
-- rising edge of its clock and never drives it. Frame reconstruction,
-- protocol checks, statistics and capture happen in the Python backend.
--
-- A sample is recorded when valid is asserted or the sample word changes, so
-- a long idle period costs one sample. Sample words (see
-- awesome_vunit_vcs/ethernet/phy/common.py):
--
--   bit 0-7  data
--   bit 8    dv
--   bit 9    er
--   bit 10   metavalue on data while dv is asserted
--   bit 11   metavalue on dv or er

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

use work.ethernet_pkg.all;
use work.vcs_python_pkg.all;

entity gmii_monitor is
  generic (
    monitor : ethernet_monitor_t
  );
  port (
    -- GTX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : in std_ulogic_vector(7 downto 0);
    -- TX_EN or RX_DV
    dv : in std_ulogic;
    -- TX_ER or RX_ER
    er : in std_ulogic := '0'
  );
end entity;

architecture a of gmii_monitor is
begin
  main : process
    constant session : python_session_t := new_vc_session(get_id(monitor));
    constant logger : logger_t := get_logger(monitor);
    constant checker : checker_t := get_checker(monitor);
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
    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;

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

    procedure reply_idle(variable request_msg : inout msg_t) is
      variable idle_reply_msg : msg_t := new_msg(wait_until_idle_reply_msg);
    begin
      reply(net, request_msg, idle_reply_msg);
    end;

    procedure reply_integer(variable request_msg : inout msg_t; value : integer) is
      variable integer_reply_msg : msg_t := new_msg(ethernet_reply_msg);
    begin
      push(integer_reply_msg, value);
      reply(net, request_msg, integer_reply_msg);
    end;

    procedure expect_frame(frame : std_ulogic_vector) is
      alias octets : std_ulogic_vector(0 to frame'length - 1) is frame;
      variable values : integer_vector(0 to frame'length / 8 - 1);
    begin
      for idx in values'range loop
        values(idx) := to_integer(to_01(unsigned(octets(8 * idx to 8 * idx + 7))));
      end loop;
      call("vc.expect_payload", arg(values), session => session);
    end;

    procedure start_capture_from(variable request_msg : inout msg_t) is
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

    procedure handle_message(variable request_msg : inout msg_t) is
      variable check : ethernet_check_t;
      variable enabled : boolean;
      variable level : log_level_t;
      variable values : integer_array_t;
      variable statistics_reply_msg : msg_t;
    begin
      msg_type := message_type(request_msg);

      -- Whatever the message is, it acts on everything sampled so far
      flush_samples(batch);

      if msg_type = wait_until_idle_msg then
        if in_frame then
          push(idle_requests, request_msg);
        else
          reply_idle(request_msg);
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
          request_msg, backend_integer(session, "check_count(" & py_str(ethernet_check_t'image(check)) & ")")
        );

      elsif msg_type = ethernet_get_frame_count_msg then
        reply_integer(request_msg, backend_integer(session, "frame_count()"));

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
        log(logger, backend_string(session, "statistics_summary()"), level);

      elsif msg_type = ethernet_expect_frame_msg then
        expect_frame(pop_std_ulogic_vector(request_msg));

      elsif msg_type = ethernet_start_capture_msg then
        start_capture_from(request_msg);

      elsif msg_type = ethernet_stop_capture_msg then
        backend_exec(session, "stop_captures()");

      else
        unexpected_msg_type(msg_type, monitor.p_std_cfg);
      end if;
    end;
  begin
    create_backend(session, ethernet_backend_module, ethernet_monitor_backend_class, backend_arguments(monitor));
    batch := new_sample_batch(session, logger, checker, monitor.p_batch_length, monitor.p_delta_unit);

    while not finished loop
      wait on clk, net, runner;

      if rising_edge(clk) then
        word := sample_word;
        if is_valid(word) or word /= previous_word or word >= error_bit then
          record_sample(batch, word);
        end if;

        if in_frame and not is_valid(word) then
          if monitor.p_flush_at_frame_end or not is_empty(idle_requests) then
            flush_samples(batch);
          end if;
          while not is_empty(idle_requests) loop
            msg := pop(idle_requests);
            reply_idle(msg);
          end loop;
        end if;

        in_frame := is_valid(word);
        previous_word := word;
      end if;

      while has_message(actor) loop
        receive(net, actor, msg);
        handle_message(msg);
      end loop;

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        flush_samples(batch);
        if backend_integer(session, "finish()") > 0 then
          log_reports(session, logger, checker);
        end if;
        finished := true;
      end if;
    end loop;

    wait;
  end process;
end architecture;
