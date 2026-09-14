-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Protocol-generic QSPI master verification component.
--
-- Drives the clock, the chip select and the master half of the four IO wires
-- for the transactions queued through qspi_master_pkg, and knows nothing
-- beyond that: no opcodes, no address widths, no flash state. Which bytes go
-- out, on how many lanes, with how many dummy cycles in between and how many
-- bytes come back is entirely the caller's business -- see qspi_master_pkg for
-- the transaction shape and qspi_flash_cmd_pkg for the JEDEC layer built on
-- top of it.
--
-- SPI mode 0 (CPOL = 0, CPHA = 0). Within a transaction each SCK cycle is
-- driven as
--
--   apply the master's drive -> wait half a period -> SCK high (both ends
--   sample here) -> wait half a period -> SCK low
--
-- so master outputs change on the falling edge and are stable for a full half
-- period before the rising edge on which the far end samples them. A read beat
-- is the same cycle with the master's output enables cleared, sampling the
-- resolved bus immediately before driving SCK high; the far end is expected to
-- have driven the beat on the preceding falling edge. Dummy cycles are read
-- beats whose sample is discarded, so the master is tri-stated throughout
-- them, which is what makes a lane turnaround between an x1 address phase and
-- an x4 data phase safe.
--
-- Chip select framing belongs to the VC: CS falls half a period before the
-- first rising edge, rises half a period after the last falling edge, and
-- stays high for the longer of one period and the configured CS deselect time
-- before the next transaction may start.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

use work.qspi_pkg.all;
use work.qspi_master_pkg.all;

entity qspi_master is
  generic (
    -- Created with new_qspi_master
    qspi_master : qspi_master_t
  );
  port (
    -- Clock, chip select and the master's IO drive. Read back by the VC when
    -- it resolves the bus during a read beat.
    m2s : out qspi_m2s_t := qspi_m2s_init;
    -- The slave's IO drive
    s2m : in qspi_s2m_t
  );
end entity;

architecture a of qspi_master is
begin
  main : process
    constant actor : actor_t := get_actor(qspi_master);
    constant logger : logger_t := get_logger(qspi_master);
    constant checker : checker_t := get_checker(qspi_master);
    constant deselect_time : delay_length := cs_deselect_time(qspi_master);

    variable period : delay_length := sck_period(qspi_master);

    -- One SCK cycle. sample is the resolved bus immediately before the
    -- rising edge, which is what the far end presented for this beat.
    procedure sck_cycle(variable sample : out qspi_io_t) is
    begin
      wait for period / 2;
      sample := qspi_io_value(m2s, s2m);
      m2s.sck <= '1';
      wait for period / 2;
      m2s.sck <= '0';
    end;

    procedure write_phase(bytes : integer_array_t; lanes : lane_count_t; phase_name : string) is
      variable byte : std_ulogic_vector(7 downto 0);
      variable sample : qspi_io_t;
    begin
      if is_null(bytes) or length(bytes) = 0 then
        return;
      end if;

      debug(
        logger,
        "Sending " & integer'image(length(bytes)) & " " & phase_name & " byte(s) on " & integer'image(lanes) &
        " lane(s)"
      );

      for index in 0 to length(bytes) - 1 loop
        byte := qspi_to_byte(get(bytes, index));
        for beat in 0 to qspi_beats_per_byte(lanes) - 1 loop
          m2s.io <= qspi_drive_beat(byte, lanes, beat, qspi_master_side);
          sck_cycle(sample);
        end loop;
      end loop;
    end;

    procedure dummy_phase(cycles : natural) is
      variable sample : qspi_io_t;
    begin
      if cycles = 0 then
        return;
      end if;

      debug(logger, "Clocking " & integer'image(cycles) & " dummy cycle(s)");

      -- Tri-state before the first dummy cycle, i.e. on the falling edge that
      -- ends the last write beat, so the whole dummy phase is a turnaround.
      m2s.io.enable <= (others => '0');
      for cycle in 1 to cycles loop
        sck_cycle(sample);
      end loop;
    end;

    procedure read_phase(bytes : integer_array_t; lanes : lane_count_t) is
      variable byte : std_ulogic_vector(7 downto 0);
      variable sample : qspi_io_t;
      variable slice : std_ulogic_vector(lanes - 1 downto 0);
    begin
      if length(bytes) = 0 then
        return;
      end if;

      debug(
        logger,
        "Receiving " & integer'image(length(bytes)) & " byte(s) on " & integer'image(lanes) & " lane(s)"
      );

      m2s.io.enable <= (others => '0');

      for index in 0 to length(bytes) - 1 loop
        byte := (others => '0');
        for beat in 0 to qspi_beats_per_byte(lanes) - 1 loop
          sck_cycle(sample);
          slice := qspi_sample_beat(sample, lanes, qspi_slave_side);
          check_false(
            checker,
            is_x(slice),
            "Read byte " & integer'image(index) & " beat " & integer'image(beat) & ": the far end drove " &
            to_string(slice) & " on the data lanes"
          );
          byte := qspi_byte_insert(byte, lanes, beat, to_x01(slice));
        end loop;
        set(bytes, index, qspi_to_natural(byte));
      end loop;
    end;

    -- One complete transaction, CS framing included.
    procedure run_transfer(
      cmd : integer_array_t;
      cmd_lanes : lane_count_t;
      addr : integer_array_t;
      addr_lanes : lane_count_t;
      wr_data : integer_array_t;
      wr_lanes : lane_count_t;
      dummy_cycles : natural;
      rd_data : integer_array_t;
      read_lanes : lane_count_t
    ) is
    begin
      m2s.cs_n <= '0';

      write_phase(cmd, cmd_lanes, "command");
      write_phase(addr, addr_lanes, "address");
      write_phase(wr_data, wr_lanes, "write-data");
      dummy_phase(dummy_cycles);
      read_phase(rd_data, read_lanes);

      -- Last falling edge to CS high, then the mandatory CS-high gap before
      -- the next transaction.
      m2s.io.enable <= (others => '0');
      wait for period / 2;
      m2s.cs_n <= '1';
      -- The CS-high gap is the device's tSHSL, not one bus period. Waiting only
      -- one period here violated the flash model's default 30 ns tSHSL at the
      -- default 20 ns bus speed -- a real bug, found by the flash VC's own
      -- protocol checker, and invisible on the wire until something checked it.
      wait for maximum(period, deselect_time);
    end;

    -- Pop one byte phase, in the order qspi_master_pkg pushed it.
    procedure pop_byte_phase(msg : msg_t; variable bytes : out integer_array_t; variable lanes : out lane_count_t) is
      variable count : natural;
      variable phase_lanes : lane_count_t;
      variable phase_bytes : integer_array_t;
    begin
      count := pop_integer(msg);
      phase_lanes := pop_integer(msg);
      phase_bytes := new_1d(length => count, bit_width => 8, is_signed => false);
      for index in 0 to count - 1 loop
        set(phase_bytes, index, pop_integer(msg));
      end loop;

      bytes := phase_bytes;
      lanes := phase_lanes;
    end;

    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;

    variable cmd, addr, wr_data, rd_data : integer_array_t;
    variable cmd_lanes, addr_lanes, wr_lanes, read_lanes : lane_count_t;
    variable dummy_cycles, num_read_bytes : natural;
  begin
    loop
      receive(net, actor, msg);
      msg_type := message_type(msg);

      handle_sync_message(net, msg_type, msg);

      if msg_type = qspi_transfer_msg then
        pop_byte_phase(msg, cmd, cmd_lanes);
        pop_byte_phase(msg, addr, addr_lanes);
        pop_byte_phase(msg, wr_data, wr_lanes);
        dummy_cycles := pop_integer(msg);
        num_read_bytes := pop_integer(msg);
        read_lanes := pop_integer(msg);

        rd_data := new_1d(length => num_read_bytes, bit_width => 8, is_signed => false);

        run_transfer(
          cmd => cmd,
          cmd_lanes => cmd_lanes,
          addr => addr,
          addr_lanes => addr_lanes,
          wr_data => wr_data,
          wr_lanes => wr_lanes,
          dummy_cycles => dummy_cycles,
          rd_data => rd_data,
          read_lanes => read_lanes
        );

        deallocate(cmd);
        deallocate(addr);
        deallocate(wr_data);

        -- Ownership of the read data moves to the caller, which redeems it with
        -- await_qspi_transfer_reply.
        reply_msg := new_msg(qspi_transfer_reply_msg);
        push_ref(reply_msg, rd_data);
        reply(net, msg, reply_msg);

      elsif msg_type = qspi_master_set_sck_period_msg then
        period := pop_time(msg);
        debug(logger, "SCK period set to " & to_string(period));
        acknowledge(net, msg, true);

      else
        unexpected_msg_type(msg_type, qspi_master.p_std_cfg);
      end if;
    end loop;
  end process;
end architecture;
