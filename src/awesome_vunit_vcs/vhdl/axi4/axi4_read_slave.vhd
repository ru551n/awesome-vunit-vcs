-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- AXI4 read slave on an axi4_memory_t, the counterpart of VUnit's
-- axi_read_slave. It accepts bursts on the read address channel and returns
-- their data on the read data channel. The data of a whole burst, its lanes and
-- its responses come from Python in one bridge call at the AR handshake
-- (awesome_vunit_vcs.axi4.slave); this entity drives the handshakes and the
-- timing.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;
  use vunit_lib.queue_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.axi4_pkg.all;
  use work.axi4_memory_pkg.all;
  use work.axi4_slave_pkg.all;
  use work.vc_python_pkg.all;

entity axi4_read_slave is
  generic (
    -- Created with :vhdl:`axi4_slave_pkg.new_axi4_slave`
    axi_slave : axi4_slave_t);
  port (
    -- The clock; the slave samples and drives at its rising edges
    aclk : in  std_ulogic;
    -- The active low reset, 1 when left open. At 0 the slave drops its bursts
    -- and deasserts ARREADY and RVALID.
    aresetn : in  std_ulogic := '1';
    -- The read address channel. ARLEN is 8 bits for AXI4 and 4 for AXI3.
    arvalid : in  std_ulogic;
    arready : out std_ulogic := '0';
    arid : in  std_ulogic_vector(id_length(get_bus(axi_slave)) - 1 downto 0) := (others => '0');
    araddr : in  std_ulogic_vector(address_length(get_bus(axi_slave)) - 1 downto 0);
    arlen : in  std_ulogic_vector;
    arsize : in  std_ulogic_vector(2 downto 0) := full_size(get_bus(axi_slave));
    arburst : in  std_ulogic_vector(1 downto 0) := "01";
    -- The read data channel
    rvalid : out std_ulogic := '0';
    rready : in  std_ulogic;
    rid : out std_ulogic_vector(id_length(get_bus(axi_slave)) - 1 downto 0);
    rdata : out std_ulogic_vector(data_length(get_bus(axi_slave)) - 1 downto 0);
    rresp : out std_ulogic_vector(1 downto 0);
    rlast : out std_ulogic
  );
end entity;

architecture a of axi4_read_slave is

  constant config : axi4_slave_config_t := get_config(axi_slave);
  constant data_bytes : positive := byte_lanes(get_bus(axi_slave));
  signal well_behaved_check : boolean := false;

begin

  main : process

    variable session : python_session_t;
    variable port_index : natural;
    variable state : axi4_slave_state_t := new_axi4_slave_state(axi_slave);
    variable random : axi4_slave_random_t := new_axi4_slave_random(axi_slave, 0);
    -- The bursts accepted and not started: their ID and data, and the time
    -- their data may start
    variable bursts : queue_t := new_queue;
    variable times : queue_t := new_queue;
    -- The burst in progress: [reports, index, then RRESP and the lanes of each beat]
    variable burst : integer_array_t := null_integer_array;
    variable burst_id : natural;
    variable total_beats : natural := 0;
    -- The beats of the burst in progress not accepted yet
    variable beats : natural := 0;
    variable response_time : time;
    variable has_response_time : boolean := false;
    variable stall : boolean;
    variable latency : delay_length;

    procedure drive_r_invalid is
    begin

      if config.drive_invalid then
        rid <= (rid'range => config.drive_invalid_val);
        rdata <= (rdata'range => config.drive_invalid_val);
        rresp <= (rresp'range => config.drive_invalid_val);
        rlast <= config.drive_invalid_val;
      end if;
    end;

    procedure drop_bursts is

      variable dropped : integer_array_t;
    begin

      while not is_empty(bursts) loop

        burst_id := pop(bursts);
        dropped := pop_integer_array_t_ref(bursts);
        deallocate(dropped);
      end loop;

      while not is_empty(times) loop

        response_time := pop(times);
      end loop;

      deallocate(burst);
      beats := 0;
      has_response_time := false;
      state.queued_bursts := 0;
      state.reset_requested := false;
      rvalid <= '0';
      arready <= '0';
      drive_r_invalid;
    end;

    procedure accept_burst is

      variable values : integer_array_t;
    begin

      values := backend_call_integer_array(
        session,
        "read_burst",
        arg(port_index)
        & arg(natural'(known(arid)))
        & arg_unsigned(known(araddr))
        & arg(natural'(known(arlen)))
        & arg(natural'(known(arsize)))
        & arg(natural'(known(arburst)))
        & arg(is_x(arid & araddr & arlen & arsize & arburst))
      );
      log_slave_reports(axi_slave, port_index, get(values, 0));
      push(bursts, natural'(known(arid)));
      push_integer_array_t_ref(bursts, values);
      draw_latency(random, state.min_response_latency, state.max_response_latency, latency);
      push(times, now + latency);
      state.queued_bursts := state.queued_bursts + 1;
    end;

    procedure drive_beat is

      -- The RRESP and the lanes of the beat
      constant first : natural := 2 + (total_beats - beats) * (1 + data_bytes);
      variable value : integer;
    begin

      rvalid <= '1';
      rid <= std_ulogic_vector(to_unsigned(burst_id, rid'length));
      rresp <= std_ulogic_vector(to_unsigned(get(burst, first), 2));
      for lane in 0 to data_bytes - 1 loop

        value := get(burst, first + 1 + lane);
        if value >= 0 then
          rdata(8 * lane + 7 downto 8 * lane) <= std_ulogic_vector(to_unsigned(value, 8));
        elsif config.drive_invalid then
          rdata(8 * lane + 7 downto 8 * lane) <= (others => config.drive_invalid_val);
        end if;
      end loop;

      if beats = 1 then
        rlast <= '1';
      else
        rlast <= '0';
      end if;
    end;

    -- One rising edge of ACLK, in the order of VUnit's axi_read_slave
    procedure cycle is
    begin

      if to_x01(rready and rvalid) = '1' then
        rvalid <= '0';
        drive_r_invalid;
        beats := beats - 1;
      end if;

      if to_x01(arvalid and arready) = '1' then
        accept_burst;
      end if;

      if state.queued_bursts > 0 and beats = 0 then
        if not has_response_time then
          has_response_time := true;
          response_time := pop(times);
        end if;
        if response_time <= now then
          has_response_time := false;
          deallocate(burst);
          burst_id := pop(bursts);
          burst := pop_integer_array_t_ref(bursts);
          total_beats := (length(burst) - 2) / (1 + data_bytes);
          beats := total_beats;
          state.queued_bursts := state.queued_bursts - 1;
        end if;
      end if;

      if beats > 0 and (rvalid = '0' or to_x01(rready) = '1') then
        draw_stall(random, state.data_stall_probability, stall);
        if not stall then
          drive_beat;
        end if;
      end if;

      draw_stall(random, state.address_stall_probability, stall);
      if stall or state.queued_bursts >= state.address_fifo_depth then
        arready <= '0';
      else
        arready <= '1';
      end if;
    end;

  begin

    drive_r_invalid;
    session := memory_session(get_memory(axi_slave));
    port_index := attach_axi4_slave(axi_slave, is_write => false);
    assert arlen'length = 4 or arlen'length = 8
      report "ARLEN is 4 bits (AXI3) or 8 bits (AXI4), not " & integer'image(arlen'length)
      severity failure;
    -- Before the first edge, as VUnit's slave
    cycle;

    loop

      if rising_edge(aclk) then
        if to_x01(aresetn) = '0' then
          drop_bursts;
        else
          cycle;
        end if;
      end if;

      handle_axi4_slave_messages(net, axi_slave, port_index, state, idle => state.queued_bursts = 0 and beats = 0);
      if state.reset_requested then
        drop_bursts;
      end if;
      well_behaved_check <= state.well_behaved_check;

      if state.resume_time > now then
        wait on aclk, net for state.resume_time - now;
      else
        wait on aclk, net;
      end if;
    end loop;

  end process;

  -- VUnit's check that bursts are well behaved, with its messages
  well_behaved : process

    constant checker : checker_t := get_checker(axi_slave);
    variable size, len : natural;
    variable num_beats : integer := 0;
    variable num_beats_now : integer;

  begin

    wait until rising_edge(aclk);
    num_beats_now := num_beats;
    if to_x01(arvalid) = '1' then
      len := known(arlen);
      num_beats_now := num_beats + len + 1;
    end if;

    -- Always count the beats, so the check can be enabled at any time
    if to_x01(arvalid and arready) = '1' then
      size := 2 ** natural'(known(arsize));
      num_beats := num_beats_now;
      if well_behaved_check and size /= data_bytes and len /= 0 then
        check_failed(
          checker,
          "Burst not well behaved, axi size = "
          & to_string(size)
          & " but bus data width allows "
          & to_string(data_bytes)
        );
      end if;
    end if;

    if well_behaved_check and num_beats_now > 0 and to_x01(rready) /= '1' then
      check_failed(checker, "Burst not well behaved, rready was not high during active burst");
    end if;

    if to_x01(rready and rvalid) = '1' then
      num_beats := -1;
    end if;
  end process;

end architecture;
