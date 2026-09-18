-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive AXI4 monitor: records what happens on the five channels at every
-- rising edge of ACLK and never drives them. Transactions, the scoreboards
-- and the statistics are the work of its Python backend
-- (awesome_vunit_vcs.axi4.monitor). The records go to Python when a batch is
-- full, before a message is handled, and at the end of every transaction
-- while the monitor has subscribers or waiting pops. With a protocol checker
-- in its handle, the monitor instantiates an axi4_protocol_checker on the
-- same pins.

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

  use work.axi4_pkg.all;
  use work.axi4_monitor_pkg.all;
  use work.axi4_protocol_checker_pkg.all;
  use work.vc_python_pkg.all;

entity axi4_monitor is
  generic (
    -- Created with :vhdl:`axi4_monitor_pkg.new_axi4_monitor`
    monitor : axi4_monitor_t);
  port (
    -- The clock; the monitor samples at its rising edges
    aclk : in  std_ulogic;
    -- The active low reset, 1 when left open
    aresetn : in  std_ulogic := '1';
    -- The write address channel. Signals left open take the default of the
    -- AXI specification: AWLEN 0, AWSIZE the data width, AWBURST INCR, the
    -- others 0.
    awvalid : in  std_ulogic := '0';
    awready : in  std_ulogic := '0';
    awid : in  std_ulogic_vector(id_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    awaddr : in  std_ulogic_vector(address_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    awlen : in  std_ulogic_vector(7 downto 0) := (others => '0');
    awsize : in  std_ulogic_vector(2 downto 0) := full_size(get_bus(monitor));
    awburst : in  std_ulogic_vector(1 downto 0) := "01";
    awlock : in  std_ulogic := '0';
    awcache : in  std_ulogic_vector(3 downto 0) := "0000";
    awprot : in  std_ulogic_vector(2 downto 0) := "000";
    awqos : in  std_ulogic_vector(3 downto 0) := "0000";
    awregion : in  std_ulogic_vector(3 downto 0) := "0000";
    awuser : in  std_ulogic_vector(awuser_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    -- The write data channel; WSTRB and WLAST are 1 when left open
    wvalid : in  std_ulogic := '0';
    wready : in  std_ulogic := '0';
    wdata : in  std_ulogic_vector(data_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    wstrb : in  std_ulogic_vector(byte_lanes(get_bus(monitor)) - 1 downto 0) := (others => '1');
    wlast : in  std_ulogic := '1';
    wuser : in  std_ulogic_vector(wuser_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    -- The write response channel
    bvalid : in  std_ulogic := '0';
    bready : in  std_ulogic := '0';
    bid : in  std_ulogic_vector(id_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    bresp : in  std_ulogic_vector(1 downto 0) := "00";
    buser : in  std_ulogic_vector(buser_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    -- The read address channel, with the defaults of the write address channel
    arvalid : in  std_ulogic := '0';
    arready : in  std_ulogic := '0';
    arid : in  std_ulogic_vector(id_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    araddr : in  std_ulogic_vector(address_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    arlen : in  std_ulogic_vector(7 downto 0) := (others => '0');
    arsize : in  std_ulogic_vector(2 downto 0) := full_size(get_bus(monitor));
    arburst : in  std_ulogic_vector(1 downto 0) := "01";
    arlock : in  std_ulogic := '0';
    arcache : in  std_ulogic_vector(3 downto 0) := "0000";
    arprot : in  std_ulogic_vector(2 downto 0) := "000";
    arqos : in  std_ulogic_vector(3 downto 0) := "0000";
    arregion : in  std_ulogic_vector(3 downto 0) := "0000";
    aruser : in  std_ulogic_vector(aruser_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    -- The read data channel; RLAST is 1 when left open
    rvalid : in  std_ulogic := '0';
    rready : in  std_ulogic := '0';
    rid : in  std_ulogic_vector(id_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    rdata : in  std_ulogic_vector(data_length(get_bus(monitor)) - 1 downto 0) := (others => '0');
    rresp : in  std_ulogic_vector(1 downto 0) := "00";
    rlast : in  std_ulogic := '1';
    ruser : in  std_ulogic_vector(ruser_length(get_bus(monitor)) - 1 downto 0) := (others => '0')
  );
end entity;

architecture a of axi4_monitor is

begin

  main : process

    -- The values of a flat transaction before its bytes
    constant header_length : natural := 21;
    constant logger : logger_t := get_logger(monitor);
    constant checker : checker_t := get_checker(monitor);
    constant actor : actor_t := get_actor(monitor);
    variable session : python_session_t;
    variable batch : sample_batch_t;
    variable sampler : axi4_sampler_t := new_axi4_sampler;
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

    -- The transaction of values from index first on, into a message
    procedure push_transaction (transaction_msg : msg_t; first : natural) is
    begin

      for idx in first to first + 11 loop

        push(transaction_msg, get(values, idx));
      end loop;

      for idx in 0 to 3 loop

        push(transaction_msg, axi4_time(get(values, first + 12 + 2 * idx), get(values, first + 13 + 2 * idx)));
      end loop;

      push(transaction_msg, get(values, first + 20));
      for idx in 0 to get(values, first + 20) - 1 loop

        push(transaction_msg, get(values, first + header_length + idx));
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

          publish_msg := new_msg(axi4_transaction_msg);
          push_transaction(publish_msg, idx);
          publish(net, actor, publish_msg);
          idx := idx + header_length + get(values, idx + 20);
        end loop;

        deallocate(values);
      end if;
      if publishing /= has_subscribers then
        publishing := not publishing;
        backend_call(session, "set_publish", arg(publishing));
      end if;

      while not is_empty(pop_requests) loop

        values := backend_call_integer_array(session, "pop_transaction");
        if length(values) = 0 then
          deallocate(values);
          exit;
        end if;
        request_msg := pop(pop_requests);
        reply_msg := new_msg(pop_axi4_transaction_reply_msg);
        push_transaction(reply_msg, 0);
        deallocate(values);
        reply(net, request_msg, reply_msg);
      end loop;

    end;

    procedure check_transaction (request_msg : msg_t) is

      constant is_write : boolean := pop(request_msg);
      constant address_hi : integer := pop(request_msg);
      constant address_lo : integer := pop(request_msg);
      constant id : integer := pop(request_msg);
      constant resp : integer := pop(request_msg);
      constant num_bytes : natural := pop(request_msg);
      variable data : integer_vector(0 to num_bytes - 1);
    begin

      for idx in data'range loop

        data(idx) := pop(request_msg);
      end loop;

      backend_call(
        session,
        "check_transaction",
        arg(is_write)
        & arg(address_hi)
        & arg(address_lo)
        & arg(data)
        & arg(id)
        & arg(resp)
        & arg_text(pop_string(request_msg))
      );
    end;

  begin

    session := new_vc_session(get_id(monitor), logger);
    create_backend(session, "awesome_vunit_vcs.axi4.vunit_backend", "Axi4MonitorBackend", backend_arguments(monitor));
    log_waiting(backend_call_integer(session, "num_reports"));
    batch := new_sample_batch(session, logger, checker, batch_length => 4096);

    loop

      if resume_time > now then
        wait on aclk, net, runner for resume_time - now;
      else
        wait on aclk, net, runner;
      end if;

      if rising_edge(aclk) then
        record_axi4_clock(batch, sampler, aresetn);
        record_axi4_channel(
          batch,
          sampler,
          axi4_aw,
          awvalid,
          awready,
          aresetn,
          is_x(awuser & awregion & awqos & awprot & awcache & awlock & awburst & awsize & awlen & awaddr & awid),
          awuser & awregion & awqos & awprot & awcache & awlock & awburst & awsize & awlen & awaddr & awid
        );
        record_axi4_channel(
          batch,
          sampler,
          axi4_w,
          wvalid,
          wready,
          aresetn,
          is_x(wuser & wlast & wstrb),
          lane_metavalues(wdata) & wuser & wlast & wstrb & wdata
        );
        record_axi4_channel(
          batch,
          sampler,
          axi4_b,
          bvalid,
          bready,
          aresetn,
          is_x(buser & bresp & bid),
          buser & bresp & bid
        );
        record_axi4_channel(
          batch,
          sampler,
          axi4_ar,
          arvalid,
          arready,
          aresetn,
          is_x(aruser & arregion & arqos & arprot & arcache & arlock & arburst & arsize & arlen & araddr & arid),
          aruser & arregion & arqos & arprot & arcache & arlock & arburst & arsize & arlen & araddr & arid
        );
        record_axi4_channel(
          batch,
          sampler,
          axi4_r,
          rvalid,
          rready,
          aresetn,
          is_x(ruser & rlast & rresp & rid),
          lane_metavalues(rdata) & ruser & rlast & rresp & rdata & rid
        );
        -- A B handshake or the last R beat ends a transaction
        if (publishing or not is_empty(pop_requests))
           and (to_x01(bvalid and bready) = '1' or to_x01(rvalid and rready and rlast) = '1') then
          serve;
        end if;
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
        elsif msg_type = pop_axi4_transaction_msg then
          push(pop_requests, msg);
          serve;
        elsif msg_type = check_axi4_transaction_msg then
          check_transaction(msg);
        elsif msg_type = get_axi4_statistics_msg then
          values := backend_call_integer_array(session, "statistics_values", arg_time(now));
          reply_msg := new_msg(get_axi4_statistics_reply_msg);
          for idx in 0 to length(values) - 1 loop

            push(reply_msg, get(values, idx));
          end loop;

          deallocate(values);
          reply(net, msg, reply_msg);
        elsif msg_type = log_axi4_statistics_msg then
          log(
            logger,
            backend_call_string(session, "statistics_summary", arg_time(now)),
            log_level_t'val(integer'(pop(msg)))
          );
        elsif msg_type = reset_axi4_monitor_msg then
          log_waiting(backend_call_integer(session, "reset", arg(boolean'(pop(msg)))));
          -- Pending pops are cancelled
          while not is_empty(pop_requests) loop

            reply_msg := pop(pop_requests);
            delete(reply_msg);
          end loop;

          sampler := new_axi4_sampler;
          reply_msg := new_msg(reset_axi4_monitor_reply_msg);
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

  protocol_checker_gen : if protocol_checker(monitor) /= null_axi4_protocol_checker generate
    protocol_checker_inst : entity work.axi4_protocol_checker
      generic map (
        protocol_checker => protocol_checker(monitor)
      )
      port map (
        aclk => aclk,
        aresetn => aresetn,
        awvalid => awvalid,
        awready => awready,
        awid => awid,
        awaddr => awaddr,
        awlen => awlen,
        awsize => awsize,
        awburst => awburst,
        awlock => awlock,
        awcache => awcache,
        awprot => awprot,
        awqos => awqos,
        awregion => awregion,
        awuser => awuser,
        wvalid => wvalid,
        wready => wready,
        wdata => wdata,
        wstrb => wstrb,
        wlast => wlast,
        wuser => wuser,
        bvalid => bvalid,
        bready => bready,
        bid => bid,
        bresp => bresp,
        buser => buser,
        arvalid => arvalid,
        arready => arready,
        arid => arid,
        araddr => araddr,
        arlen => arlen,
        arsize => arsize,
        arburst => arburst,
        arlock => arlock,
        arcache => arcache,
        arprot => arprot,
        arqos => arqos,
        arregion => arregion,
        aruser => aruser,
        rvalid => rvalid,
        rready => rready,
        rid => rid,
        rdata => rdata,
        rresp => rresp,
        rlast => rlast,
        ruser => ruser
      );

  end generate protocol_checker_gen;

end architecture;
