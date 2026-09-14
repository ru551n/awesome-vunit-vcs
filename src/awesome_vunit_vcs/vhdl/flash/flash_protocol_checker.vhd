-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Pin timing checker of the flash verification component.
--
-- A passive observer of the controller driven half of a QSPI bus. It measures
-- the intervals between edges of the pins the controller owns, SCK, CS and the
-- IO drive of the controller, and reports every interval shorter than the
-- minimum in the flash handle as a check failure on the checker of the flash.
--
-- Only the obligations of the controller are checked. t_clqv and t_shqz are
-- delays of the device's own output, which flash.vhd applies; checking them
-- here would make the component fail on its own output.
--
-- A minimum of 0 ns is not checked, and a handle created with
-- protocol_checks = false removes the checker.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;

use work.qspi_pkg.all;
use work.flash_pkg.all;

entity flash_protocol_checker is
  generic (
    -- The handle of the flash: its checker and its pin timing minimums
    flash : flash_t
  );
  port (
    -- The controller driven half of the bus, never driven here
    m2s : in qspi_m2s_t
  );
end entity;

architecture a of flash_protocol_checker is
  constant checker : checker_t := get_checker(flash);

  -- A time in ns with up to three decimals ("7.519 ns"). to_string of a time
  -- uses the resolution of the simulator, which differs between simulators
  -- and is not the unit of a datasheet.
  function ns_image(value : delay_length) return string is
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
  -- picoseconds, but a violation is below a minimum of nanoseconds
  procedure check_min(measured : time; minimum : delay_length; what : string) is
  begin
    if minimum > 0 fs and measured < minimum then
      check_failed(
        checker,
        "flash protocol: " & what & " " & ns_image(measured) & " is shorter than the " & ns_image(minimum) &
        " minimum"
      );
    end if;
  end;
begin
  enabled_gen : if flash.p_protocol_checks generate
    -- One process, since the checks relate edges of different pins: CS to
    -- SCK for t_slch and t_chsh, IO to SCK for data-in setup and hold
    main : process
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
      -- The last SCK edge within the command, the start of t_chsh
      variable sck_edge_time : time := 0 fs;
      variable have_sck_edge : boolean := false;

      -- The last sampling edge at which the controller drove the IOs. A read
      -- or dummy beat carries no data in, and so has no setup or hold.
      variable io_change_time : time := 0 fs;
      variable sample_time : time := 0 fs;
      variable have_sample : boolean := false;

      impure function controller_driving return boolean is
      begin
        return m2s.io.enable /= (m2s.io.enable'range => '0');
      end;
    begin
      loop
        wait on m2s;

        -- SCK period, high and low time. Not gated on CS: an interval that
        -- spans an idle gap is longer than any minimum.
        if rising_edge(m2s.sck) then
          if have_rise then
            check_min(now - rise_time, flash.p_t_sck_min, "SCK period");
          end if;
          if have_fall then
            check_min(now - fall_time, flash.p_t_sck_low_min, "SCK low time");
          end if;
          rise_time := now;
          have_rise := true;
        elsif falling_edge(m2s.sck) then
          if have_rise then
            check_min(now - rise_time, flash.p_t_sck_high_min, "SCK high time");
          end if;
          fall_time := now;
          have_fall := true;
        end if;

        -- CS framing: t_shsl, t_chsh
        if falling_edge(m2s.cs_n) then
          if have_cs_rise then
            check_min(now - cs_rise_time, flash.p_t_shsl, "CS high time between commands");
          end if;
          cs_fall_time := now;
          awaiting_first_sck := true;
          -- The edges of the previous command say nothing about this one
          have_sck_edge := false;
          have_sample := false;
        elsif rising_edge(m2s.cs_n) then
          if have_sck_edge then
            check_min(now - sck_edge_time, flash.p_t_chsh, "last SCK edge to CS high");
          end if;
          cs_rise_time := now;
          have_cs_rise := true;
        end if;

        -- SCK edges while selected, after the CS branch so that an SCK edge at
        -- the time CS falls belongs to the new command: t_slch
        if m2s.cs_n = '0' and (rising_edge(m2s.sck) or falling_edge(m2s.sck)) then
          if awaiting_first_sck and rising_edge(m2s.sck) then
            check_min(now - cs_fall_time, flash.p_t_slch, "CS low to the first SCK rising edge");
            awaiting_first_sck := false;
          end if;
          sck_edge_time := now;
          have_sck_edge := true;
        end if;

        -- Data in around the rising edge the device samples on: t_dvch, t_chdx
        if rising_edge(m2s.sck) and m2s.cs_n = '0' and controller_driving then
          check_min(now - io_change_time, flash.p_t_dvch, "data-in setup");
          sample_time := now;
          have_sample := true;
        end if;

        if m2s.io'event then
          if have_sample and m2s.cs_n = '0' then
            check_min(now - sample_time, flash.p_t_chdx, "data-in hold");
          end if;
          -- Releasing a lane early violates the hold time like changing it
          io_change_time := now;
        end if;
      end loop;
    end process;
  end generate;
end architecture;
