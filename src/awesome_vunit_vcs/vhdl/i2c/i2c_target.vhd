-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- I2C target verification component.
--
-- The entity shifts bits in and out on open-drain SCL and SDA; its Python
-- backend (awesome_vunit_vcs.i2c.target and a device model) decides what they
-- mean. It calls the backend at every START and STOP and once per byte, never
-- per clock edge, and gets a directive back: whether to acknowledge the byte,
-- how long to stretch SCL before the acknowledge bit, and whether to receive,
-- transmit or ignore the next byte.
--
-- Two processes: main creates the backend and serves the messages of the
-- testbench; pins follows the bus. SDA changes t_hd_dat after SCL falls.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.sync_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.i2c_pkg.all;
  use work.i2c_target_pkg.all;
  use work.vc_python_pkg.all;

entity i2c_target is
  generic (
    -- Created with :vhdl:`i2c_target_pkg.new_i2c_target`
    target : i2c_target_t);
  port (
    -- The clock line: released 'Z', or driven '0' to stretch the clock
    scl : inout std_logic := 'Z';
    -- The data line: driven '0' or released 'Z'
    sda : inout std_logic := 'Z'
  );
end entity;

architecture a of i2c_target is

  constant logger : logger_t := get_logger(target);
  constant checker : checker_t := get_checker(target);
  constant session : python_session_t := new_vc_session(get_id(target), logger);

  -- Raised when the backend exists; pins must not call it before
  signal initialized : boolean := false;
  -- Changed by main when a reset asks pins to release the bus, and set to it
  -- by pins when it did
  signal reset_count : natural := 0;
  signal reset_done : natural := 0;

begin

  main : process

    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable address, num_bytes : natural;
    variable values : integer_array_t;
    variable reset_number : natural;

    procedure log_waiting (count : natural) is
    begin

      if count > 0 then
        log_reports(session, logger, checker);
      end if;
    end;

    impure function pop_bytes return integer_vector is

      constant count : natural := pop(msg);
      variable result : integer_vector(0 to count - 1);
    begin

      for idx in result'range loop

        result(idx) := pop(msg);
      end loop;

      return result;
    end;

  begin

    create_backend(session, "awesome_vunit_vcs.i2c.vunit_backend", "I2cTargetBackend", backend_arguments(target));
    backend_call(session, "set_arguments", model_arguments(target));
    log_waiting(backend_call_integer(session, "create_device", arg_text(model(target))));
    initialized <= true;

    loop

      receive(net, get_actor(target), msg);
      -- A STOP at this time, whose SDA edge is a delta cycle old, reaches
      -- the model first
      wait for 0 ns;
      msg_type := message_type(msg);
      handle_sync_message(net, msg_type, msg);

      if msg_type = set_i2c_target_stretch_msg then
        log_waiting(backend_call_integer(session, "set_stretch", arg_time(pop(msg))));
      elsif msg_type = inject_i2c_target_nack_msg then
        log_waiting(backend_call_integer(session, "inject_nack", arg(integer'(pop(msg)))));
      elsif msg_type = preload_i2c_target_memory_msg then
        address := pop(msg);
        log_waiting(backend_call_integer(session, "preload", arg(pop_bytes) & arg(address)));
      elsif msg_type = check_i2c_target_memory_msg then
        address := pop(msg);
        log_waiting(
          backend_call_integer(session, "check_memory", arg(pop_bytes) & arg(address) & arg_text(pop_string(msg)))
        );
      elsif msg_type = read_i2c_target_memory_msg then
        address := pop(msg);
        num_bytes := pop(msg);
        values := backend_call_integer_array(session, "read_memory", arg(address) & arg(num_bytes));
        log_waiting(backend_call_integer(session, "num_reports"));
        reply_msg := new_msg(read_i2c_target_memory_reply_msg);
        push(reply_msg, length(values));
        for idx in 0 to length(values) - 1 loop

          push(reply_msg, get(values, idx));
        end loop;

        deallocate(values);
        reply(net, msg, reply_msg);
      elsif msg_type = reset_i2c_target_msg then
        log_waiting(backend_call_integer(session, "reset"));
        reset_number := reset_count + 1;
        reset_count <= reset_number;
        wait until reset_done = reset_number;
        reply_msg := new_msg(reset_i2c_target_reply_msg);
        reply(net, msg, reply_msg);
      else
        unexpected_msg_type(msg_type, target);
      end if;
    end loop;

  end process;

  pins : process

    constant receive_action : natural := 0;
    constant transmit_action : natural := 1;

    type state_t is (idle, receiving, transmitting);

    variable state : state_t := idle;
    variable prev_scl : std_ulogic;
    variable prev_sda : std_ulogic;
    variable cur_scl : std_ulogic;
    variable cur_sda : std_ulogic;
    -- Rising SCL edges of the current byte, 9 with the acknowledge bit
    variable bit_count : natural := 0;
    variable byte : natural := 0;
    -- The last directive
    variable action : natural := 2;
    variable ack : boolean := false;
    variable byte_out : natural := 0;
    variable stretch : delay_length := 0 ns;

    -- 1 is a released line
    function drive (value : boolean) return std_logic is
    begin

      if value then
        return 'Z';
      end if;
      return '0';
    end;

    function bit_of (value : natural; idx : natural) return boolean is
    begin

      return (value / 2 ** idx) mod 2 = 1;
    end;

    procedure take (directive : integer_array_t) is

      variable local : integer_array_t := directive;
    begin

      action := get(local, 0);
      ack := get(local, 1) = 1;
      byte_out := get(local, 2);
      stretch := get(local, 3) * 1 ps;
      if get(local, 4) > 0 then
        log_reports(session, logger, checker);
      end if;
      deallocate(local);
    end;

    -- The acknowledge bit ended: start the next byte
    procedure next_byte is
    begin

      bit_count := 0;
      byte := 0;
      if action = receive_action then
        sda <= 'Z' after t_hd_dat(target);
        state := receiving;
      elsif action = transmit_action then
        sda <= drive(bit_of(byte_out, 7)) after t_hd_dat(target);
        state := transmitting;
      else
        sda <= 'Z' after t_hd_dat(target);
        state := idle;
      end if;
    end;

  begin

    if not initialized then
      wait until initialized;
    end if;
    prev_scl := to_x01(scl);
    prev_sda := to_x01(sda);

    loop

      wait on scl, sda, reset_count;
      cur_scl := to_x01(scl);
      cur_sda := to_x01(sda);

      if reset_count'event then
        sda <= 'Z';
        scl <= 'Z';
        state := idle;
        reset_done <= reset_count;
      elsif cur_scl = '1' and prev_scl = '1' and cur_sda /= prev_sda and cur_sda /= 'X' and prev_sda /= 'X' then
        -- SDA changed while SCL is high: a START or a STOP
        sda <= 'Z';
        if cur_sda = '0' then
          take(backend_call_integer_array(session, "start", arg_time(now)));
          state := receiving;
          bit_count := 0;
          byte := 0;
        else
          state := idle;
          if backend_call_integer(session, "stop", arg_time(now)) > 0 then
            log_reports(session, logger, checker);
          end if;
        end if;
      elsif prev_scl = '0' and cur_scl = '1' and state /= idle then
        bit_count := bit_count + 1;
        if state = receiving and bit_count <= 8 then
          if is_x(sda) then
            check_failed(checker, "Metavalue " & to_string(sda) & " on SDA at " & to_string(now));
          end if;
          byte := 2 * byte;
          if cur_sda = '1' then
            byte := byte + 1;
          end if;
          if bit_count = 8 then
            take(backend_call_integer_array(session, "received", arg(byte) & arg_time(now)));
          end if;
        elsif state = transmitting and bit_count = 9 then
          take(backend_call_integer_array(session, "transmitted", arg(cur_sda = '0') & arg_time(now)));
        end if;
      elsif prev_scl = '1' and cur_scl = '0' and state /= idle then
        if state = receiving and bit_count = 8 then
          -- The acknowledge bit, after stretching the clock
          if ack then
            sda <= '0' after t_hd_dat(target);
          end if;
          if ack and stretch > 0 ns then
            scl <= '0';
            wait for stretch;
            scl <= 'Z';
            cur_scl := '0';
            cur_sda := to_x01(sda);
          end if;
        elsif bit_count = 9 then
          next_byte;
        elsif state = transmitting and bit_count < 8 then
          sda <= drive(bit_of(byte_out, 7 - bit_count)) after t_hd_dat(target);
        elsif state = transmitting then
          -- The master acknowledges
          sda <= 'Z' after t_hd_dat(target);
        end if;
      end if;
      prev_scl := cur_scl;
      prev_sda := cur_sda;
    end loop;

  end process;

end architecture;
