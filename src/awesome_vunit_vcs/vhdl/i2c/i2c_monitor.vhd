-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive I2C monitor: records every change of SCL and SDA with its time and
-- never drives them. Transfers, the scoreboard and statistics are the work of
-- its Python backend (awesome_vunit_vcs.i2c.monitor). The samples go to Python
-- at every potential STOP and before a message is handled. With a protocol
-- checker in its handle, the monitor instantiates an i2c_protocol_checker on
-- the same pins.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.queue_pkg.all;
  use vunit_lib.sync_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.i2c_pkg.all;
  use work.i2c_monitor_pkg.all;
  use work.i2c_protocol_checker_pkg.all;
  use work.vc_python_pkg.all;

entity i2c_monitor is
  generic (
    -- Created with :vhdl:`i2c_monitor_pkg.new_i2c_monitor`
    monitor : i2c_monitor_t);
  port (
    -- The clock line, read with to_x01
    scl : in  std_ulogic;
    -- The data line, read with to_x01
    sda : in  std_ulogic
  );
end entity;

architecture a of i2c_monitor is

begin

  main : process

    constant logger : logger_t := get_logger(monitor);
    constant checker : checker_t := get_checker(monitor);
    constant actor : actor_t := get_actor(monitor);
    variable session : python_session_t;
    variable batch : sample_batch_t;
    variable word, previous_word : natural;
    variable resume_time : time := 0 ns;
    variable publishing : boolean := false;
    variable pop_requests : queue_t := new_queue;
    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable values : integer_array_t;

    procedure log_waiting (count : natural) is
    begin

      if count > 0 then
        log_reports(session, logger, checker);
      end if;
    end;

    impure function has_subscribers return boolean is

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

    -- The transfers of values from index first on, as messages of msg_type
    procedure push_transfer (transfer_msg : msg_t; first : natural) is
    begin

      push(transfer_msg, get(values, first));
      push(transfer_msg, get(values, first + 1));
      push(transfer_msg, get(values, first + 2));
      push(transfer_msg, i2c_time(get(values, first + 3), get(values, first + 4)));
      push(transfer_msg, get(values, first + 5));
      for idx in 0 to get(values, first + 5) - 1 loop

        push(transfer_msg, get(values, first + 6 + idx));
      end loop;

    end;

    -- Everything that waits for Python to be up to date
    procedure serve is

      variable idx : natural;
      variable publish_msg : msg_t;
      variable request_msg : msg_t;
    begin

      flush_samples(batch);
      if publishing then
        values := backend_call_integer_array(session, "take_published");
        idx := 0;
        while idx < length(values) loop

          publish_msg := new_msg(i2c_transfer_msg);
          push_transfer(publish_msg, idx);
          publish(net, actor, publish_msg);
          idx := idx + 6 + get(values, idx + 5);
        end loop;

        deallocate(values);
      end if;
      if publishing /= has_subscribers then
        publishing := not publishing;
        backend_call(session, "set_publish", arg(publishing));
      end if;

      while not is_empty(pop_requests) loop

        values := backend_call_integer_array(session, "pop_transfer");
        if length(values) = 0 then
          deallocate(values);
          exit;
        end if;
        request_msg := pop(pop_requests);
        reply_msg := new_msg(pop_i2c_transfer_reply_msg);
        push_transfer(reply_msg, 0);
        deallocate(values);
        reply(net, request_msg, reply_msg);
      end loop;

    end;

    procedure check_transfer (request_msg : msg_t) is

      constant address : natural := pop(request_msg);
      constant is_read : boolean := pop(request_msg);
      constant num_bytes : natural := pop(request_msg);
      variable data : integer_vector(0 to num_bytes - 1);
    begin

      for idx in data'range loop

        data(idx) := pop(request_msg);
      end loop;

      backend_call(
        session,
        "check_transfer",
        arg(address) & arg(is_read) & arg(data) & arg_text(pop_string(request_msg))
      );
    end;

  begin

    session := new_vc_session(get_id(monitor), logger);
    create_backend(
      session,
      "awesome_vunit_vcs.i2c.vunit_backend",
      "I2cMonitorBackend",
      arg_text(full_name(get_id(monitor)))
      & kwarg("report_metavalues", protocol_checker(monitor) = null_i2c_protocol_checker)
    );
    batch := new_sample_batch(session, logger, checker, batch_length => 4096);
    previous_word := i2c_sample_word(scl, sda);
    record_sample(batch, previous_word);

    loop

      if resume_time > now then
        wait on scl, sda, net, runner for resume_time - now;
      else
        wait on scl, sda, net, runner;
      end if;

      word := i2c_sample_word(scl, sda);
      if word /= previous_word then
        record_sample(batch, word);
        -- SDA rose while SCL is high: a STOP ends a transaction
        if word mod 4 = 3 and previous_word mod 4 = 1 then
          serve;
        end if;
        previous_word := word;
      end if;

      while now >= resume_time and has_message(actor) loop

        receive(net, actor, msg);
        msg_type := message_type(msg);
        flush_samples(batch);
        if msg_type = wait_until_idle_msg then
          handle_message(msg_type);
          serve;
          reply_msg := new_msg(wait_until_idle_reply_msg);
          reply(net, msg, reply_msg);
        elsif msg_type = wait_for_time_msg then
          handle_message(msg_type);
          resume_time := now + pop_time(msg);
          delete(msg);
        elsif msg_type = pop_i2c_transfer_msg then
          push(pop_requests, msg);
          serve;
        elsif msg_type = check_i2c_transfer_msg then
          check_transfer(msg);
        elsif msg_type = get_i2c_statistics_msg then
          values := backend_call_integer_array(session, "statistics_values", arg_time(now));
          reply_msg := new_msg(get_i2c_statistics_reply_msg);
          for idx in 0 to 10 loop

            push(reply_msg, get(values, idx));
          end loop;

          push(reply_msg, i2c_time(get(values, 11), get(values, 12)));
          push(reply_msg, i2c_time(get(values, 13), get(values, 14)));
          push(reply_msg, get(values, 15));
          deallocate(values);
          reply(net, msg, reply_msg);
        elsif msg_type = reset_i2c_monitor_msg then
          log_waiting(backend_call_integer(session, "reset", arg(boolean'(pop(msg)))));
          -- Pending pops are cancelled
          while not is_empty(pop_requests) loop

            reply_msg := pop(pop_requests);
            delete(reply_msg);
          end loop;

          record_sample(batch, previous_word);
          reply_msg := new_msg(reset_i2c_monitor_reply_msg);
          reply(net, msg, reply_msg);
        else
          unexpected_msg_type(msg_type, monitor);
        end if;
        log_waiting(backend_call_integer(session, "num_reports"));
      end loop;

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        serve;
        log_waiting(backend_call_integer(session, "finish"));
        exit;
      end if;
    end loop;

    wait;
  end process;

  protocol_checker_gen : if protocol_checker(monitor) /= null_i2c_protocol_checker generate
    protocol_checker_inst : entity work.i2c_protocol_checker
      generic map (
        protocol_checker => protocol_checker(monitor)
      )
      port map (
        scl => scl,
        sda => sda
      );

  end generate protocol_checker_gen;

end architecture;
