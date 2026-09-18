-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- I2C protocol checker verification component. It records every change of
-- SCL and SDA with its time and never drives them; its Python backend
-- (awesome_vunit_vcs.i2c.checker) checks the timing and the protocol and
-- reports violations as check failures on the checker of the component.
--
-- The samples are flushed to Python at every potential STOP, when a line
-- has been low for the stuck-low time, and before a message is handled. A
-- line stuck low produces no edges, so the component records a sample of its
-- own after the stuck-low time without a change.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.i2c_pkg.all;
  use work.i2c_protocol_checker_pkg.all;
  use work.vc_python_pkg.all;

entity i2c_protocol_checker is
  generic (
    -- Created with :vhdl:`i2c_protocol_checker_pkg.new_i2c_protocol_checker`
    protocol_checker : i2c_protocol_checker_t);
  port (
    -- The clock line, read with to_x01
    scl : in  std_ulogic;
    -- The data line, read with to_x01
    sda : in  std_ulogic
  );
end entity;

architecture a of i2c_protocol_checker is

begin

  main : process

    constant logger : logger_t := get_logger(protocol_checker);
    constant checker : checker_t := get_checker(protocol_checker);
    constant actor : actor_t := get_actor(protocol_checker);
    constant stuck_time : delay_length := t_stuck(protocol_checker);
    variable session : python_session_t;
    variable batch : sample_batch_t;
    variable word : natural;
    variable previous_word : natural;
    variable last_change : time := 0 ns;
    variable resume_time : time := 0 ns;
    variable timeout : time;
    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable check : i2c_check_t;
    variable enabled : boolean;

    procedure log_waiting (count : natural) is
    begin

      if count > 0 then
        log_reports(session, logger, checker);
      end if;
    end;

  begin

    session := new_vc_session(get_id(protocol_checker), logger);
    create_backend(
      session,
      "awesome_vunit_vcs.i2c.vunit_backend",
      "I2cProtocolCheckerBackend",
      backend_arguments(protocol_checker)
    );
    log_waiting(backend_call_integer(session, "num_reports"));
    batch := new_sample_batch(session, logger, checker, batch_length => 4096);
    previous_word := i2c_sample_word(scl, sda);
    record_sample(batch, previous_word);

    loop

      -- A line low: wake up after the stuck-low time without a change; and
      -- when a wait_for_time ends
      timeout := time'high;
      if stuck_time > 0 ns and previous_word mod 4 /= 3 then
        timeout := stuck_time - (now - last_change) + 1 ps;
      end if;
      if resume_time > now and resume_time - now < timeout then
        timeout := resume_time - now;
      end if;
      if timeout = time'high then
        wait on scl, sda, net, runner;
      else
        wait on scl, sda, net, runner for timeout;
      end if;

      word := i2c_sample_word(scl, sda);
      if word /= previous_word then
        record_sample(batch, word);
        -- SDA rose while SCL is high: a STOP ends a transaction
        if word mod 4 = 3 and previous_word mod 4 = 1 then
          flush_samples(batch);
        end if;
        previous_word := word;
        last_change := now;
      elsif stuck_time > 0 ns and previous_word mod 4 /= 3 and now - last_change > stuck_time then
        record_sample(batch, word);
        flush_samples(batch);
        last_change := now;
      end if;

      while now >= resume_time and has_message(actor) loop

        receive(net, actor, msg);
        msg_type := message_type(msg);
        flush_samples(batch);
        if msg_type = wait_until_idle_msg then
          handle_message(msg_type);
          reply_msg := new_msg(wait_until_idle_reply_msg);
          reply(net, msg, reply_msg);
        elsif msg_type = wait_for_time_msg then
          handle_message(msg_type);
          resume_time := now + pop_time(msg);
          delete(msg);
        elsif msg_type = set_i2c_check_enabled_msg then
          check := i2c_check_t'val(integer'(pop(msg)));
          enabled := pop(msg);
          log_waiting(
            backend_call_integer(session, "set_check_enabled", arg_text(i2c_check_t'image(check)) & arg(enabled))
          );
        elsif msg_type = get_i2c_check_count_msg then
          check := i2c_check_t'val(integer'(pop(msg)));
          reply_msg := new_msg(get_i2c_check_count_reply_msg);
          push(reply_msg, backend_call_integer(session, "check_count", arg_text(i2c_check_t'image(check))));
          log_waiting(backend_call_integer(session, "num_reports"));
          reply(net, msg, reply_msg);
        elsif msg_type = reset_i2c_protocol_checker_msg then
          log_waiting(backend_call_integer(session, "reset"));
          record_sample(batch, previous_word);
          last_change := now;
          reply_msg := new_msg(reset_i2c_protocol_checker_reply_msg);
          reply(net, msg, reply_msg);
        else
          unexpected_msg_type(msg_type, protocol_checker);
        end if;
      end loop;

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        flush_samples(batch);
        log_waiting(backend_call_integer(session, "finish", arg_time(now)));
        exit;
      end if;
    end loop;

    wait;
  end process;

end architecture;
