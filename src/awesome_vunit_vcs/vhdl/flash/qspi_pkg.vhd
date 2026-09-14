-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Shared, direction-neutral types and helpers for a QSPI (quad SPI) bus.
--
-- This package is the common vocabulary of the two ends of the bus: the QSPI
-- master verification component (qspi_master.vhd) and the flash device model
-- (flash.vhd). It therefore contains nothing that is specific to either end,
-- and in particular nothing at all about flash commands -- no opcodes, no
-- address widths, no status registers. Those live in qspi_flash_cmd_pkg (the
-- master's thin JEDEC layer) and in the device model respectively.
--
-- Pin model. A real QSPI bus has four bidirectional IO wires, so both ends must
-- be able to tri-state. Rather than rely on a resolved signal -- which would
-- force std_logic and make "who drove this?" invisible in a waveform -- each
-- side drives its own unresolved record carrying a value and a per-lane output
-- enable, and qspi_io_value resolves the pair into what a probe on the wire
-- would see (including 'X' for bus contention). The master drives qspi_m2s_t
-- (clock, chip select and its IO drive), the slave drives qspi_s2m_t (its IO
-- drive only).
--
-- Lane model. A bus phase uses 1, 2 or 4 IO lanes; 3 is never valid, which a
-- 'positive range 1 to 4' subtype cannot express, so qspi_is_valid_lane_count
-- exists and every helper asserts on it. Bytes are always serialized MSB first,
-- qspi_beats_per_byte(lanes) beats per byte, and within a beat the most
-- significant bit of the group sits on the highest-numbered lane of the group.
--
-- Lane numbering is asymmetric for single-lane (classic SPI) phases only: the
-- master drives MOSI on IO0 while the slave drives MISO on IO1. Dual and quad
-- phases use IO(lanes-1 downto 0) in both directions. qspi_lane_base and
-- qspi_lane_mask are the single place that knows this, which is why they take
-- a qspi_side_t saying which end is driving.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package qspi_pkg is
  ---------------------------------------------------------------------------
  -- Pins
  ---------------------------------------------------------------------------

  constant qspi_io_width : positive := 4;

  subtype qspi_io_t is std_ulogic_vector(qspi_io_width - 1 downto 0);

  -- One end's drive of the four IO wires. enable is per lane so that a
  -- single-lane phase leaves the other three wires to the far end.
  type qspi_drive_t is record
    value : qspi_io_t;
    enable : qspi_io_t;
  end record;

  constant qspi_drive_init : qspi_drive_t := (
    value => (others => '0'),
    enable => (others => '0')
  );

  -- Master to slave: the clock, the chip select and the master's IO drive.
  type qspi_m2s_t is record
    sck : std_ulogic;
    cs_n : std_ulogic;
    io : qspi_drive_t;
  end record;

  constant qspi_m2s_init : qspi_m2s_t := (
    sck => '0',
    cs_n => '1',
    io => qspi_drive_init
  );

  -- Slave to master: the slave's IO drive. The slave never drives sck or cs_n.
  type qspi_s2m_t is record
    io : qspi_drive_t;
  end record;

  constant qspi_s2m_init : qspi_s2m_t := (io => qspi_drive_init);

  -- What a probe on the four wires would see, given both ends' drive.
  -- Undriven lanes read 'Z'; lanes driven by both ends read 'X'.
  function qspi_io_value(m2s : qspi_m2s_t; s2m : qspi_s2m_t) return qspi_io_t;

  ---------------------------------------------------------------------------
  -- Lanes
  ---------------------------------------------------------------------------

  -- Number of IO lanes a phase uses. Only 1, 2 and 4 are legal values; the
  -- subtype cannot exclude 3, so use qspi_is_valid_lane_count when the value
  -- comes from outside (a generic, a Python directive, a testbench).
  subtype lane_count_t is positive range 1 to qspi_io_width;

  -- Which end of the bus is driving a phase. Only single-lane phases care.
  type qspi_side_t is (qspi_master_side, qspi_slave_side);

  -- IO0 is MOSI and IO1 is MISO for a single-lane (classic SPI) phase.
  constant qspi_mosi_lane : natural := 0;
  constant qspi_miso_lane : natural := 1;

  function qspi_is_valid_lane_count(lanes : lane_count_t) return boolean;

  -- SCK cycles needed to move one byte over lanes lanes.
  function qspi_beats_per_byte(lanes : lane_count_t) return positive;

  -- Lowest IO lane used by a phase of the given width driven by the given side.
  function qspi_lane_base(lanes : lane_count_t; driver : qspi_side_t) return natural;

  -- Output-enable mask for a phase of the given width driven by the given side.
  function qspi_lane_mask(lanes : lane_count_t; driver : qspi_side_t) return qspi_io_t;

  ---------------------------------------------------------------------------
  -- Byte serialization, MSB first
  ---------------------------------------------------------------------------

  -- The lanes bits of data that go out in beat number beat (0 first),
  -- returned as a (lanes-1 downto 0) slice that maps straight onto the IO lanes
  -- of the phase: the most significant bit of the group on the highest lane.
  function qspi_byte_beat(
    data : std_ulogic_vector(7 downto 0);
    lanes : lane_count_t;
    beat : natural
  ) return std_ulogic_vector;

  -- The inverse: fold a received beat back into the byte under construction.
  function qspi_byte_insert(
    data : std_ulogic_vector(7 downto 0);
    lanes : lane_count_t;
    beat : natural;
    value : std_ulogic_vector
  ) return std_ulogic_vector;

  -- Beat beat of data as a ready-to-apply drive record for the given side.
  function qspi_drive_beat(
    data : std_ulogic_vector(7 downto 0);
    lanes : lane_count_t;
    beat : natural;
    driver : qspi_side_t
  ) return qspi_drive_t;

  -- The lanes of a bus value that carry a phase of the given width driven by
  -- the given side, normalized to (lanes-1 downto 0).
  function qspi_sample_beat(
    io : qspi_io_t;
    lanes : lane_count_t;
    driver : qspi_side_t
  ) return std_ulogic_vector;

  ---------------------------------------------------------------------------
  -- Byte conversion
  ---------------------------------------------------------------------------

  function qspi_to_byte(value : natural) return std_ulogic_vector;
  function qspi_to_natural(data : std_ulogic_vector) return natural;
end package;

package body qspi_pkg is
  function qspi_io_value(m2s : qspi_m2s_t; s2m : qspi_s2m_t) return qspi_io_t is
    variable result : qspi_io_t := (others => 'Z');
  begin
    for lane in result'range loop
      if m2s.io.enable(lane) = '1' and s2m.io.enable(lane) = '1' then
        -- Bus contention. Deliberately visible rather than silently resolved.
        result(lane) := 'X';
      elsif m2s.io.enable(lane) = '1' then
        result(lane) := m2s.io.value(lane);
      elsif s2m.io.enable(lane) = '1' then
        result(lane) := s2m.io.value(lane);
      end if;
    end loop;

    return result;
  end;

  function qspi_is_valid_lane_count(lanes : lane_count_t) return boolean is
  begin
    return lanes = 1 or lanes = 2 or lanes = 4;
  end;

  function qspi_beats_per_byte(lanes : lane_count_t) return positive is
  begin
    assert qspi_is_valid_lane_count(lanes)
      report "QSPI lane count must be 1, 2 or 4, got " & integer'image(lanes)
      severity failure;

    return 8 / lanes;
  end;

  function qspi_lane_base(lanes : lane_count_t; driver : qspi_side_t) return natural is
  begin
    assert qspi_is_valid_lane_count(lanes)
      report "QSPI lane count must be 1, 2 or 4, got " & integer'image(lanes)
      severity failure;

    if lanes = 1 and driver = qspi_slave_side then
      return qspi_miso_lane;
    end if;

    return qspi_mosi_lane;
  end;

  function qspi_lane_mask(lanes : lane_count_t; driver : qspi_side_t) return qspi_io_t is
    constant base : natural := qspi_lane_base(lanes, driver);
    variable result : qspi_io_t := (others => '0');
  begin
    result(base + lanes - 1 downto base) := (others => '1');

    return result;
  end;

  function qspi_byte_beat(
    data : std_ulogic_vector(7 downto 0);
    lanes : lane_count_t;
    beat : natural
  ) return std_ulogic_vector is
    constant high : natural := 7 - beat * lanes;
  begin
    assert beat < qspi_beats_per_byte(lanes)
      report "QSPI beat " & integer'image(beat) & " out of range for " & integer'image(lanes) & " lanes"
      severity failure;

    return data(high downto high - lanes + 1);
  end;

  function qspi_byte_insert(
    data : std_ulogic_vector(7 downto 0);
    lanes : lane_count_t;
    beat : natural;
    value : std_ulogic_vector
  ) return std_ulogic_vector is
    constant high : natural := 7 - beat * lanes;
    variable result : std_ulogic_vector(7 downto 0) := data;
  begin
    assert beat < qspi_beats_per_byte(lanes)
      report "QSPI beat " & integer'image(beat) & " out of range for " & integer'image(lanes) & " lanes"
      severity failure;
    assert value'length = lanes
      report "QSPI beat value is " & integer'image(value'length) & " bits, expected " & integer'image(lanes)
      severity failure;

    result(high downto high - lanes + 1) := value;

    return result;
  end;

  function qspi_drive_beat(
    data : std_ulogic_vector(7 downto 0);
    lanes : lane_count_t;
    beat : natural;
    driver : qspi_side_t
  ) return qspi_drive_t is
    constant base : natural := qspi_lane_base(lanes, driver);
    variable result : qspi_drive_t := qspi_drive_init;
  begin
    result.value(base + lanes - 1 downto base) := qspi_byte_beat(data, lanes, beat);
    result.enable := qspi_lane_mask(lanes, driver);

    return result;
  end;

  function qspi_sample_beat(
    io : qspi_io_t;
    lanes : lane_count_t;
    driver : qspi_side_t
  ) return std_ulogic_vector is
    constant base : natural := qspi_lane_base(lanes, driver);
    variable result : std_ulogic_vector(lanes - 1 downto 0);
  begin
    result := io(base + lanes - 1 downto base);

    return result;
  end;

  function qspi_to_byte(value : natural) return std_ulogic_vector is
  begin
    assert value < 256
      report "QSPI byte value " & integer'image(value) & " does not fit in 8 bits"
      severity failure;

    return std_ulogic_vector(to_unsigned(value, 8));
  end;

  -- Weak values map to '0' rather than blowing up in numeric_std: a VC that
  -- samples an undriven wire should report that through its own checker, with
  -- a message naming the phase, not through a cryptic conversion error.
  function qspi_to_natural(data : std_ulogic_vector) return natural is
    variable normalized : std_ulogic_vector(data'length - 1 downto 0) := data;
    variable result : natural := 0;
  begin
    for index in normalized'high downto 0 loop
      result := 2 * result;
      if normalized(index) = '1' then
        result := result + 1;
      end if;
    end loop;

    return result;
  end;
end package body;
