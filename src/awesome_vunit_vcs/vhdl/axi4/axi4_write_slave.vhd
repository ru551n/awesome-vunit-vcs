-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- AXI4 write slave on an axi4_memory_t, the counterpart of VUnit's
-- axi_write_slave. It accepts bursts on the write address channel, their data
-- on the write data channel, and responds on the write response channel. Python
-- (awesome_vunit_vcs.axi4.slave) accepts a burst in one bridge call at its AW
-- handshake, and checks and writes its data in one call right before its write
-- response; this entity drives the handshakes and the timing.

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

entity axi4_write_slave is
  generic (
    -- Created with :vhdl:`axi4_slave_pkg.new_axi4_slave`
    axi_slave : axi4_slave_t);
  port (
    -- The clock; the slave samples and drives at its rising edges
    aclk : in  std_ulogic;
    -- The active low reset, 1 when left open. At 0 the slave drops its bursts
    -- and deasserts AWREADY, WREADY and BVALID.
    aresetn : in  std_ulogic := '1';
    -- The write address channel. AWLEN is 8 bits for AXI4 and 4 for AXI3.
    awvalid : in  std_ulogic;
    awready : out std_ulogic := '0';
    awid : in  std_ulogic_vector(id_length(get_bus(axi_slave)) - 1 downto 0) := (others => '0');
    awaddr : in  std_ulogic_vector(address_length(get_bus(axi_slave)) - 1 downto 0);
    awlen : in  std_ulogic_vector;
    awsize : in  std_ulogic_vector(2 downto 0) := full_size(get_bus(axi_slave));
    awburst : in  std_ulogic_vector(1 downto 0) := "01";
    -- The write data channel
    wvalid : in  std_ulogic;
    wready : out std_ulogic := '0';
    wdata : in  std_ulogic_vector(data_length(get_bus(axi_slave)) - 1 downto 0);
    wstrb : in  std_ulogic_vector(byte_lanes(get_bus(axi_slave)) - 1 downto 0) := (others => '1');
    wlast : in  std_ulogic := '1';
    -- The write response channel
    bvalid : out std_ulogic := '0';
    bready : in  std_ulogic;
    bid : out std_ulogic_vector(id_length(get_bus(axi_slave)) - 1 downto 0);
    bresp : out std_ulogic_vector(1 downto 0)
  );
end entity;

architecture a of axi4_write_slave is

  constant config : axi4_slave_config_t := get_config(axi_slave);
  constant data_bytes : positive := byte_lanes(get_bus(axi_slave));
  signal well_behaved_check : boolean := false;

begin

  main : process

    constant checker : checker_t := get_checker(axi_slave);
    variable session : python_session_t;
    variable port_index : natural;
    variable state : axi4_slave_state_t := new_axi4_slave_state(axi_slave);
    variable random : axi4_slave_random_t := new_axi4_slave_random(axi_slave, 1);
    -- The bursts accepted and not started: ID, index, beats and address for messages
    variable bursts : queue_t := new_queue;
    -- The bursts whose data is complete: ID and data, and the time of their response
    variable responses : queue_t := new_queue;
    variable times : queue_t := new_queue;
    -- The burst receiving data, and its beats not received yet
    variable burst_id : natural;
    variable burst_index : natural;
    variable burst_length : natural;
    variable burst_address : u_unsigned(63 downto 0);
    variable beats : natural := 0;
    -- Per beat and lane: the byte, bit 8 WSTRB, bit 9 a metavalue in the byte
    variable data : integer_array_t := null_integer_array;
    variable response_time : time;
    variable has_response_time : boolean := false;
    variable stall : boolean;
    variable latency : delay_length;

    procedure drive_b_invalid is
    begin

      if config.drive_invalid then
        bid <= (bid'range => config.drive_invalid_val);
        bresp <= (bresp'range => config.drive_invalid_val);
      end if;
    end;

    procedure drop_bursts is

      variable dropped : integer_array_t;
    begin

      while not is_empty(bursts) loop

        burst_id := pop(bursts);
        burst_index := pop(bursts);
        burst_length := pop(bursts);
        burst_address := u_unsigned(pop_std_ulogic_vector(bursts));
      end loop;

      while not is_empty(responses) loop

        burst_id := pop(responses);
        dropped := pop_integer_array_t_ref(responses);
        deallocate(dropped);
      end loop;

      while not is_empty(times) loop

        response_time := pop(times);
      end loop;

      deallocate(data);
      beats := 0;
      has_response_time := false;
      state.queued_bursts := 0;
      state.queued_responses := 0;
      state.reset_requested := false;
      awready <= '0';
      wready <= '0';
      bvalid <= '0';
      drive_b_invalid;
    end;

    procedure accept_burst is

      variable values : integer_array_t;
    begin

      values := backend_call_integer_array(
        session,
        "accept_write",
        arg(port_index)
        & arg(natural'(known(awid)))
        & arg_unsigned(known(awaddr))
        & arg(natural'(known(awlen)))
        & arg(natural'(known(awsize)))
        & arg(natural'(known(awburst)))
        & arg(is_x(awid & awaddr & awlen & awsize & awburst))
      );
      log_slave_reports(axi_slave, port_index, get(values, 0));
      push(bursts, natural'(known(awid)));
      push(bursts, get(values, 1));
      push(bursts, natural'(known(awlen)) + 1);
      push_std_ulogic_vector(bursts, std_ulogic_vector(resize(u_unsigned'(known(awaddr)), 64)));
      deallocate(values);
      state.queued_bursts := state.queued_bursts + 1;
    end;

    procedure receive_beat is

      variable value : natural;
    begin

      if (to_x01(wlast) = '1') /= (beats = 1) then
        check_failed(
          checker,
          "Expected wlast='1' on last beat of burst #"
          & to_string(burst_index)
          & " for id "
          & to_string(burst_id)
          & " with length "
          & to_string(burst_length)
          & " starting at address "
          & to_decimal(burst_address)
        );
      end if;
      for lane in 0 to data_bytes - 1 loop

        value := 0;
        if to_x01(wstrb(lane)) = '1' then
          value := 256 + known(wdata(8 * lane + 7 downto 8 * lane));
          if is_x(wdata(8 * lane + 7 downto 8 * lane)) then
            value := value + 512;
          end if;
        end if;
        append(data, value);
      end loop;

      beats := beats - 1;
      if beats = 0 then
        draw_latency(random, state.min_response_latency, state.max_response_latency, latency);
        push(times, now + latency);
        push(responses, burst_id);
        push_integer_array_t_ref(responses, data);
        state.queued_responses := state.queued_responses + 1;
      end if;
    end;

    procedure respond is

      variable values, burst_data : integer_array_t;
      variable response_id : natural;
    begin

      response_id := pop(responses);
      burst_data := pop_integer_array_t_ref(responses);
      state.queued_responses := state.queued_responses - 1;
      values := backend_call_integer_array(session, "write_burst", arg(port_index) & arg(burst_data));
      deallocate(burst_data);
      log_slave_reports(axi_slave, port_index, get(values, 0));
      bvalid <= '1';
      bid <= std_ulogic_vector(to_unsigned(response_id, bid'length));
      bresp <= std_ulogic_vector(to_unsigned(get(values, 1), 2));
      deallocate(values);
    end;

    -- One rising edge of ACLK, in the order of VUnit's axi_write_slave
    procedure cycle is
    begin

      if to_x01(bready) = '1' then
        bvalid <= '0';
        drive_b_invalid;
      end if;

      if to_x01(awvalid and awready) = '1' then
        accept_burst;
      end if;

      if to_x01(wvalid and wready) = '1' then
        receive_beat;
      end if;

      if state.queued_bursts > 0 and beats = 0 then
        burst_id := pop(bursts);
        burst_index := pop(bursts);
        burst_length := pop(bursts);
        burst_address := u_unsigned(pop_std_ulogic_vector(bursts));
        beats := burst_length;
        data := new_1d(length => 0, bit_width => 16, is_signed => false);
        state.queued_bursts := state.queued_bursts - 1;
      end if;

      if state.queued_responses > 0 and (bvalid = '0' or to_x01(bready) = '1') then
        draw_stall(random, state.write_response_stall_probability, stall);
        if not stall then
          if not has_response_time then
            has_response_time := true;
            response_time := pop(times);
          end if;
          if response_time <= now then
            has_response_time := false;
            respond;
          end if;
        end if;
      end if;

      draw_stall(random, state.data_stall_probability, stall);
      if beats > 0 and not (beats = 1 and state.queued_responses >= state.write_response_fifo_depth) and not stall then
        wready <= '1';
      else
        wready <= '0';
      end if;

      draw_stall(random, state.address_stall_probability, stall);
      if stall or state.queued_bursts >= state.address_fifo_depth then
        awready <= '0';
      else
        awready <= '1';
      end if;
    end;

  begin

    drive_b_invalid;
    session := memory_session(get_memory(axi_slave));
    port_index := attach_axi4_slave(axi_slave, is_write => true);
    assert awlen'length = 4 or awlen'length = 8
      report "AWLEN is 4 bits (AXI3) or 8 bits (AXI4), not " & integer'image(awlen'length)
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

      handle_axi4_slave_messages(
        net,
        axi_slave,
        port_index,
        state,
        idle => state.queued_bursts = 0 and beats = 0 and state.queued_responses = 0 and bvalid = '0'
      );
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
    if to_x01(awvalid) = '1' then
      len := known(awlen);
      num_beats_now := num_beats + len + 1;
    end if;

    -- Always count the beats, so the check can be enabled at any time
    if to_x01(awvalid and awready) = '1' then
      size := 2 ** natural'(known(awsize));
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

    if well_behaved_check and num_beats_now > 0 and to_x01(wvalid) /= '1' then
      check_failed(checker, "Burst not well behaved, wvalid was not high during active burst");
    end if;

    if well_behaved_check and num_beats_now > 0 and to_x01(bready) /= '1' then
      check_failed(checker, "Burst not well behaved, bready was not high during active burst");
    end if;

    if to_x01(wvalid and wready) = '1' then
      num_beats := -1;
    end if;
  end process;

end architecture;
