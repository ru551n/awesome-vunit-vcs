-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- QSPI protocol checker verification component.
--
-- A passive observer of a QSPI bus. It measures the intervals between edges of
-- the pins the master drives, SCK, CS and the IO lanes the master drives, and
-- reports every interval shorter than the limit of its rule as a check failure
-- on its checker, with a message starting with the upper case check ID.
--
-- Only the obligations of the master are checked. The output delays of a
-- device (tCLQV, tSHQZ) are applied by the device, not checked here.
--
-- Two processes: main serves the messages of the testbench, monitor measures
-- the pins. They share the enables and counts of the rules.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;

  use work.qspi_pkg.all;
  use work.qspi_protocol_checker_pkg.all;

entity qspi_protocol_checker is
  generic (
    -- Created with :vhdl:`qspi_protocol_checker_pkg.new_qspi_protocol_checker`
    protocol_checker : qspi_protocol_checker_t);
  port (
    -- Clock, chip select and the IO drive of the master
    m2s : in  qspi_m2s_t;
    -- The IO drive of the device. Not checked.
    s2m : in  qspi_s2m_t := qspi_s2m_init
  );
end entity;

architecture a of qspi_protocol_checker is

  constant checker : checker_t := get_checker(protocol_checker);

  -- One element per rule, indexed by qspi_check_t'pos
  constant num_checks : positive := qspi_check_t'pos(qspi_check_t'high) + 1;
  constant enabled : integer_vector_ptr_t := new_integer_vector_ptr(num_checks, value => 1);
  constant counts : integer_vector_ptr_t := new_integer_vector_ptr(num_checks, value => 0);

  -- Toggled by main on a reset, so monitor forgets its timing history
  signal forget_history : boolean := false;

  -- A time in ns with up to three decimals ("7.519 ns"). to_string of a time
  -- uses the resolution of the simulator, which differs between simulators
  -- and is not the unit of a datasheet.
  function ns_image (value : delay_length) return string is

    constant value_ps : natural := value / 1 ps;
    constant whole : natural := value_ps / 1000;
    constant fraction : natural := value_ps mod 1000;
    constant digits : string(1 to 3) := (
      1 => character'val(character'pos('0') + fraction / 100),
      2 => character'val(character'pos('0') + (fraction / 10) mod 10),
      3 => character'val(character'pos('0') + fraction mod 10)
    );
  begin

    if fraction = 0 then
      return integer'image(whole) & " ns";
    elsif fraction mod 100 = 0 then
      return integer'image(whole) & "." & digits(1 to 1) & " ns";
    elsif fraction mod 10 = 0 then
      return integer'image(whole) & "." & digits(1 to 2) & " ns";
    end if;
    return integer'image(whole) & "." & digits & " ns";
  end;

  -- The message is only built on a violation: measured can be seconds (an
  -- erase between two commands), which does not fit an integer of
  -- picoseconds, but a violation is below a limit of nanoseconds
  procedure check_min (measured : time; check : qspi_check_t; what : string) is

    constant minimum : delay_length := limit(protocol_checker, check);
    constant idx : natural := qspi_check_t'pos(check);
  begin

    if minimum > 0 fs and measured < minimum and get(enabled, idx) = 1 then
      set(counts, idx, get(counts, idx) + 1);
      check_failed(
        checker,
        upper(qspi_check_t'image(check))
        & ": "
        & what
        & " "
        & ns_image(measured)
        & " is shorter than the "
        & ns_image(minimum)
        & " minimum"
      );
    end if;
  end;

begin

  main : process

    variable msg : msg_t;
    variable reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable idx : natural;

  begin

    loop

      receive(net, get_actor(protocol_checker), msg);
      msg_type := message_type(msg);

      handle_sync_message(net, msg_type, msg);

      if msg_type = set_qspi_protocol_checker_check_enabled_msg then
        idx := pop(msg);
        if pop_boolean(msg) then
          set(enabled, idx, 1);
        else
          set(enabled, idx, 0);
        end if;

      elsif msg_type = get_qspi_protocol_checker_check_count_msg then
        idx := pop(msg);
        reply_msg := new_msg(get_qspi_protocol_checker_check_count_reply_msg);
        push(reply_msg, get(counts, idx));
        reply(net, msg, reply_msg);

      elsif msg_type = reset_qspi_protocol_checker_msg then
        for check_idx in 0 to num_checks - 1 loop

          set(counts, check_idx, 0);
        end loop;

        forget_history <= not forget_history;
        -- monitor resumes in this delta too, so the history is gone before
        -- the caller can drive the next edge
        wait on forget_history;
        reply_msg := new_msg(reset_qspi_protocol_checker_reply_msg);
        reply(net, msg, reply_msg);
      else
        unexpected_msg_type(msg_type, protocol_checker);
      end if;
    end loop;

  end process;

  -- One process, since the rules relate edges of different pins: CS to SCK
  -- for t_slch and t_chsh, IO to SCK for data setup and hold
  monitor : process

    -- The last SCK edges, valid once the matching have_ flag is set so the
    -- first edge is not measured against time 0
    variable rise_time : time := 0 fs;
    variable fall_time : time := 0 fs;
    variable have_rise : boolean := false;
    variable have_fall : boolean := false;

    -- CS framing
    variable cs_fall_time : time := 0 fs;
    variable cs_rise_time : time := 0 fs;
    variable have_cs_rise : boolean := false;
    -- The next SCK rising edge is the first of the command, the end of t_slch
    variable awaiting_first_sck : boolean := false;
    -- The last SCK rising edge within the command, the start of t_chsh. A
    -- datasheet measures tCHSH from the rising edge, not from the falling
    -- edge that follows it in SPI mode 0.
    variable sck_rise_time : time := 0 fs;
    variable have_sck_rise : boolean := false;

    -- The last change of each IO lane, its value or whether the master drives
    -- it, and the lanes the master drove at the last sampling edge. A lane
    -- the master does not drive carries no data in, and so has no setup or
    -- hold.
    type time_vector_t is array (qspi_io_t'range) of time;

    variable lane_change_time : time_vector_t := (others => 0 fs);
    variable last_drive : qspi_drive_t := qspi_drive_init;
    variable latest_change : time;
    variable sampled_lanes : qspi_io_t := (others => '0');
    variable sample_time : time := 0 fs;
    variable hold_broken : boolean;

  begin

    loop

      wait on m2s, forget_history;

      if forget_history'event then
        have_rise := false;
        have_fall := false;
        have_cs_rise := false;
        awaiting_first_sck := false;
        have_sck_rise := false;
        lane_change_time := (others => 0 fs);
        sampled_lanes := (others => '0');
        last_drive := m2s.io;
      end if;

      -- SCK period, high and low time. Not gated on CS: an interval that
      -- spans an idle gap is longer than any limit.
      if rising_edge(m2s.sck) then
        if have_rise then
          check_min(now - rise_time, qspi_sck_period, "SCK period");
        end if;
        if have_fall then
          check_min(now - fall_time, qspi_sck_low, "SCK low time");
        end if;
        rise_time := now;
        have_rise := true;
      elsif falling_edge(m2s.sck) then
        if have_rise then
          check_min(now - rise_time, qspi_sck_high, "SCK high time");
        end if;
        fall_time := now;
        have_fall := true;
      end if;

      -- CS framing: t_shsl, t_chsh
      if falling_edge(m2s.cs_n) then
        if have_cs_rise then
          check_min(now - cs_rise_time, qspi_cs_deselect, "CS high time between commands");
        end if;
        cs_fall_time := now;
        awaiting_first_sck := true;
        -- The edges of the previous command say nothing about this one
        have_sck_rise := false;
        sampled_lanes := (others => '0');
      elsif rising_edge(m2s.cs_n) then
        if have_sck_rise then
          check_min(now - sck_rise_time, qspi_cs_hold, "last SCK rising edge to CS high");
        end if;
        cs_rise_time := now;
        have_cs_rise := true;
      end if;

      -- SCK rising edges while selected, after the CS branch so that an edge
      -- at the time CS falls belongs to the new command: t_slch ends at the
      -- first rising edge and t_chsh starts at the last one
      if m2s.cs_n = '0' and rising_edge(m2s.sck) then
        if awaiting_first_sck then
          check_min(now - cs_fall_time, qspi_cs_setup, "CS low to the first SCK rising edge");
          awaiting_first_sck := false;
        end if;
        sck_rise_time := now;
        have_sck_rise := true;
      end if;

      -- Data in around the rising edge the device samples on: t_dvch, t_chdx.
      -- The setup is measured from the latest change of a lane the master
      -- drives at the edge.
      if rising_edge(m2s.sck) and m2s.cs_n = '0' then
        sampled_lanes := m2s.io.enable;
        if sampled_lanes /= (sampled_lanes'range => '0') then
          latest_change := 0 fs;
          for lane in qspi_io_t'range loop

            if sampled_lanes(lane) = '1' and lane_change_time(lane) > latest_change then
              latest_change := lane_change_time(lane);
            end if;
          end loop;

          check_min(now - latest_change, qspi_data_setup, "data setup");
          sample_time := now;
        end if;
      end if;

      if m2s.io'event then
        hold_broken := false;
        for lane in qspi_io_t'range loop

          if m2s.io.value(lane) /= last_drive.value(lane) or m2s.io.enable(lane) /= last_drive.enable(lane) then
            lane_change_time(lane) := now;
            -- Releasing a driven lane early breaks the hold time like
            -- changing it
            if sampled_lanes(lane) = '1' then
              hold_broken := true;
            end if;
          end if;
        end loop;

        if hold_broken and m2s.cs_n = '0' then
          check_min(now - sample_time, qspi_data_hold, "data hold");
        end if;
        last_drive := m2s.io;
      end if;
    end loop;

  end process;

end architecture;
