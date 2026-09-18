-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- I2C master verification component.
--
-- The component clocks out the operations its Python backend
-- (awesome_vunit_vcs.i2c.master) compiles for a transfer, one bit at a time,
-- on open-drain SCL and SDA: it drives '0' or releases a line with 'Z'. It
-- makes two bridge calls per transfer, one for the operations and one for the
-- result, and none per bit.
--
-- * Clock stretching: after releasing SCL the master waits for SCL to rise.
-- * Clock synchronization: the high period ends early when another master
--   pulls SCL low.
-- * Arbitration: a 1 the master writes that reads back as 0 loses
--   arbitration; the master releases the bus and the transfer ends.
-- * The bus is free after a STOP and tBUF; a START waits for it.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.sync_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.i2c_pkg.all;
  use work.i2c_master_pkg.all;
  use work.vc_python_pkg.all;

entity i2c_master is
  generic (
    -- Created with :vhdl:`i2c_master_pkg.new_i2c_master`
    master : i2c_master_t);
  port (
    -- The clock line: driven '0' or released 'Z'; the testbench pulls it up with 'H'
    scl : inout std_logic := 'Z';
    -- The data line: driven '0' or released 'Z'; the testbench pulls it up with 'H'
    sda : inout std_logic := 'Z'
  );
end entity;

architecture a of i2c_master is

  -- A START was seen and no STOP after it, by any master
  signal bus_busy : boolean := false;
  -- The time of the last STOP, and whether there was one
  signal stop_time : time := 0 ns;
  signal stop_seen : boolean := false;
  -- Changed by main when a reset forgets a transaction without a STOP
  signal forget_bus : natural := 0;

begin

  bus_state : process
  begin

    wait on sda, forget_bus;
    if forget_bus'event then
      bus_busy <= false;
    elsif to_x01(scl) = '1' and not scl'event and to_x01(sda) /= to_x01(sda'last_value) then
      if to_x01(sda) = '0' then
        bus_busy <= true;
      elsif to_x01(sda) = '1' then
        bus_busy <= false;
        stop_time <= now;
        stop_seen <= true;
      end if;
    end if;
  end process;

  main : process

    constant logger : logger_t := get_logger(master);
    constant checker : checker_t := get_checker(master);
    constant actor : actor_t := get_actor(master);
    constant session : python_session_t := new_vc_session(get_id(master), logger);
    constant start_op : natural := 0;
    constant write_op : natural := 1;
    constant read_op : natural := 2;
    constant stop_op : natural := 3;
    constant bits_op : natural := 4;
    constant not_executed : integer := -1;
    constant lost : integer := -2;
    constant timed_out : integer := -3;

    variable t_low : delay_length;
    variable t_high : delay_length;
    variable t_hd_dat : delay_length;
    variable t_su_sta : delay_length;
    variable t_hd_sta : delay_length;
    variable t_su_sto : delay_length;
    variable t_buf : delay_length;
    -- The master holds SCL low after a START, and when it pulled it low
    variable holding : boolean := false;
    variable fall_time : time := 0 ns;
    -- The master left its transaction without a STOP
    variable open_transaction : boolean := false;
    -- The bit sampled at the last rising edge of SCL, and whether the master
    -- lost the bus
    variable sampled : std_ulogic;
    variable aborted : boolean;
    -- The result of the operation that aborted: lost or timed_out
    variable abort_code : integer;

    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable values : integer_array_t;
    variable ops : integer_array_t;
    variable results : integer_array_t;

    procedure log_waiting (count : natural) is
    begin

      if count > 0 then
        log_reports(session, logger, checker);
      end if;
    end;

    procedure wait_after_fall (delay : delay_length) is
    begin

      if fall_time + delay > now then
        wait for fall_time + delay - now;
      end if;
    end;

    procedure release_bus is
    begin

      sda <= 'Z';
      scl <= 'Z';
      holding := false;
      open_transaction := false;
    end;

    -- Release SCL and wait for it to rise, which a target stretching the clock
    -- delays; then sample SDA
    procedure clock_rise is
    begin

      scl <= 'Z';
      wait until to_x01(scl) = '1' for stretch_timeout(master);
      if to_x01(scl) /= '1' then
        check_failed(
          checker,
          "SCL still low " & to_string(stretch_timeout(master)) & " after it was released, at " & to_string(now)
        );
        release_bus;
        aborted := true;
        abort_code := timed_out;
        return;
      end if;
      sampled := to_x01(sda);
      if is_x(sda) then
        check_failed(checker, "Metavalue " & to_string(sda) & " on SDA at " & to_string(now));
      end if;
    end;

    -- The high period ends early when another master pulls SCL low
    procedure clock_fall is
    begin

      if to_x01(scl) = '1' then
        wait until to_x01(scl) = '0' for t_high;
      end if;
      scl <= '0';
      fall_time := now;
    end;

    -- One bit; a 1 the master writes is a released SDA, and reading it back as
    -- 0 loses arbitration
    procedure clock_bit (value : std_ulogic; write : boolean) is
    begin

      wait_after_fall(t_hd_dat);
      if write and value = '0' then
        sda <= '0';
      else
        sda <= 'Z';
      end if;
      wait_after_fall(t_low);
      clock_rise;
      if aborted then
        return;
      end if;
      if write and value = '1' and sampled = '0' then
        release_bus;
        aborted := true;
        return;
      end if;
      clock_fall;
    end;

    procedure start_condition is
    begin

      if holding then
        -- A repeated START
        wait_after_fall(t_hd_dat);
        sda <= 'Z';
        wait_after_fall(t_low);
        clock_rise;
        if aborted then
          return;
        end if;
        wait for t_su_sta;
      elsif not open_transaction then
        -- Wait for a free bus: no transaction, tBUF after a STOP, both lines high
        loop

          if bus_busy then
            wait until not bus_busy;
          elsif stop_seen and stop_time + t_buf > now then
            wait for stop_time + t_buf - now;
          elsif to_x01(scl) /= '1' or to_x01(sda) /= '1' then
            wait until to_x01(scl) = '1' and to_x01(sda) = '1';
          else
            exit;
          end if;
        end loop;

      end if;
      -- After a transaction left without a STOP, SCL may have just risen
      if not holding and scl'last_event < t_su_sta then
        wait for t_su_sta - scl'last_event;
      end if;
      if to_x01(sda) /= '1' then
        -- Another master holds SDA low
        release_bus;
        aborted := true;
        return;
      end if;
      sda <= '0';
      wait for t_hd_sta;
      scl <= '0';
      fall_time := now;
      holding := true;
      open_transaction := true;
    end;

    procedure stop_condition is
    begin

      wait_after_fall(t_hd_dat);
      sda <= '0';
      wait_after_fall(t_low);
      clock_rise;
      if aborted then
        return;
      end if;
      wait for t_su_sto;
      sda <= 'Z';
      holding := false;
      open_transaction := false;
    end;

    -- The result of an operation that lost the bus, or its value
    impure function result_of (value : integer) return integer is
    begin

      if aborted then
        return abort_code;
      end if;
      return value;
    end;

    procedure write_byte (value : natural; num_bits : positive; idx : natural) is

      variable bits : std_ulogic_vector(7 downto 0);
    begin

      bits := std_ulogic_vector(to_unsigned(value, 8));
      for bit_idx in num_bits - 1 downto 0 loop

        clock_bit(bits(bit_idx), write => true);
        if aborted then
          set(results, idx, abort_code);
          return;
        end if;
      end loop;

      set(results, idx, 0);
    end;

    -- Clock out the operations; results holds one result per operation
    procedure run_ops is

      variable op : natural;
      variable kind : natural;
      variable value : natural;
      variable flag : boolean;
      variable byte : natural;
      variable idx : natural := 0;
    begin

      aborted := false;
      abort_code := lost;
      results := new_1d(length(ops), bit_width => 32, is_signed => true);
      for op_idx in 0 to length(ops) - 1 loop

        set(results, op_idx, not_executed);
      end loop;

      while idx < length(ops) loop

        op := get(ops, idx);
        value := op mod 256;
        kind := (op / 256) mod 8;
        flag := (op / 2048) mod 2 = 1;

        case kind is
          when start_op =>

            start_condition;
            set(results, idx, result_of(0));
          when write_op =>

            write_byte(value, 8, idx);
            if not aborted then
              clock_bit('1', write => false);
              if not aborted then
                if sampled = '0' then
                  set(results, idx, 0);
                else
                  set(results, idx, 1);
                end if;
                -- A NACK ends a transfer with its STOP
                if flag and sampled /= '0' then
                  idx := length(ops) - 1;
                  if (get(ops, idx) / 256) mod 8 /= stop_op then
                    exit;
                  end if;
                  next;
                end if;
              end if;
            end if;
          when read_op =>

            byte := 0;
            for bit_idx in 7 downto 0 loop

              clock_bit('1', write => false);
              exit when aborted;
              byte := 2 * byte;
              if sampled = '1' then
                byte := byte + 1;
              end if;
            end loop;

            if not aborted and flag then
              clock_bit('0', write => true);
            elsif not aborted then
              clock_bit('1', write => true);
            end if;
            set(results, idx, result_of(byte));
          when stop_op =>

            stop_condition;
            set(results, idx, result_of(0));
          when others =>

            write_byte(value, (op / 4096) mod 16, idx);
        end case;

        exit when aborted;
        idx := idx + 1;
      end loop;

      -- Without a STOP, the master leaves its transaction open and releases the bus
      if holding and not aborted then
        wait_after_fall(t_hd_dat);
        sda <= 'Z';
        wait_after_fall(t_low);
        clock_rise;
        holding := false;
      end if;
    end;

    procedure run_transfer is

      constant want_reply : boolean := pop(msg);
      constant is_ops : boolean := pop(msg);
      variable address : natural;
      variable num_write : natural;
      variable num_read : natural;
      variable ten_bit : boolean;
      variable pec : boolean;
      variable stop : boolean;
      variable expect_ack : boolean;
      variable idx : natural;
    begin

      if is_ops then
        ops := backend_call_integer_array(session, "transfer_ops", arg_text(pop_string(msg)));
      else
        address := pop(msg);
        num_write := pop(msg);
        values := new_1d(num_write);
        for byte_idx in 0 to num_write - 1 loop

          set(values, byte_idx, integer'(pop(msg)));
        end loop;

        num_read := pop(msg);
        ten_bit := pop(msg);
        pec := pop(msg);
        stop := pop(msg);
        expect_ack := pop(msg);
        ops := backend_call_integer_array(
          session,
          "transfer",
          arg(address)
          & arg(values)
          & arg(num_read)
          & kwarg("ten_bit", ten_bit)
          & kwarg("pec", pec)
          & kwarg("stop", stop)
          & kwarg("expect_ack", expect_ack)
        );
        deallocate(values);
      end if;

      run_ops;
      values := backend_call_integer_array(session, "complete", arg(results));
      deallocate(results);
      deallocate(ops);
      log_waiting(get(values, 1));

      if want_reply then
        reply_msg := new_msg(run_i2c_transfer_reply_msg);
        push(reply_msg, get(values, 0));
        -- The bytes read and the acknowledge bits
        idx := 2;
        for part in 1 to 2 loop

          push(reply_msg, get(values, idx));
          for value_idx in 1 to get(values, idx) loop

            push(reply_msg, get(values, idx + value_idx));
          end loop;

          idx := idx + 1 + get(values, idx);
        end loop;

        reply(net, msg, reply_msg);
      else
        delete(msg);
      end if;
      deallocate(values);
    end;

  begin

    create_backend(session, "awesome_vunit_vcs.i2c.vunit_backend", "I2cMasterBackend", backend_arguments(master));
    values := backend_call_integer_array(session, "timing");
    t_low := get(values, 0) * 1 ps;
    t_high := get(values, 1) * 1 ps;
    t_hd_dat := get(values, 2) * 1 ps;
    t_su_sta := get(values, 3) * 1 ps;
    t_hd_sta := get(values, 4) * 1 ps;
    t_su_sto := get(values, 5) * 1 ps;
    t_buf := get(values, 6) * 1 ps;
    deallocate(values);
    log_waiting(backend_call_integer(session, "num_reports"));

    loop

      receive(net, actor, msg);
      msg_type := message_type(msg);
      handle_sync_message(net, msg_type, msg);

      if msg_type = run_i2c_transfer_msg then
        run_transfer;
      elsif msg_type = reset_i2c_master_msg then
        release_bus;
        forget_bus <= forget_bus + 1;
        reply_msg := new_msg(reset_i2c_master_reply_msg);
        reply(net, msg, reply_msg);
      else
        unexpected_msg_type(msg_type, master);
      end if;
    end loop;

  end process;

end architecture;
