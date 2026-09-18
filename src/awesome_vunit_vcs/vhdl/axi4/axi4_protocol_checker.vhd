-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- AXI4 protocol checker verification component. It records what happens on
-- the five channels at every rising edge of ACLK and never drives them; its
-- Python backend (awesome_vunit_vcs.axi4.checker) checks the protocol and
-- reports violations as check failures on the checker of the component.
--
-- The records go to Python when a batch is full, before a message is
-- handled, and every ``timeout_cycles`` clock cycles with a tick record, so
-- a transaction that never completes is reported while the test waits for it.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.sync_pkg.all;

library python_bridge;
context python_bridge.python_context;

  use work.axi4_pkg.all;
  use work.axi4_protocol_checker_pkg.all;
  use work.vc_python_pkg.all;

entity axi4_protocol_checker is
  generic (
    -- Created with :vhdl:`axi4_protocol_checker_pkg.new_axi4_protocol_checker`
    protocol_checker : axi4_protocol_checker_t);
  port (
    -- The clock; the checker samples at its rising edges
    aclk : in  std_ulogic;
    -- The active low reset, 1 when left open
    aresetn : in  std_ulogic := '1';
    -- The write address channel. Signals left open take the default of the
    -- AXI specification: AWLEN 0, AWSIZE the data width, AWBURST INCR, the
    -- others 0.
    awvalid : in  std_ulogic := '0';
    awready : in  std_ulogic := '0';
    awid : in  std_ulogic_vector(id_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    awaddr : in  std_ulogic_vector(address_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    awlen : in  std_ulogic_vector(7 downto 0) := (others => '0');
    awsize : in  std_ulogic_vector(2 downto 0) := full_size(get_bus(protocol_checker));
    awburst : in  std_ulogic_vector(1 downto 0) := "01";
    awlock : in  std_ulogic := '0';
    awcache : in  std_ulogic_vector(3 downto 0) := "0000";
    awprot : in  std_ulogic_vector(2 downto 0) := "000";
    awqos : in  std_ulogic_vector(3 downto 0) := "0000";
    awregion : in  std_ulogic_vector(3 downto 0) := "0000";
    awuser : in  std_ulogic_vector(awuser_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    -- The write data channel; WSTRB and WLAST are 1 when left open
    wvalid : in  std_ulogic := '0';
    wready : in  std_ulogic := '0';
    wdata : in  std_ulogic_vector(data_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    wstrb : in  std_ulogic_vector(byte_lanes(get_bus(protocol_checker)) - 1 downto 0) := (others => '1');
    wlast : in  std_ulogic := '1';
    wuser : in  std_ulogic_vector(wuser_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    -- The write response channel
    bvalid : in  std_ulogic := '0';
    bready : in  std_ulogic := '0';
    bid : in  std_ulogic_vector(id_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    bresp : in  std_ulogic_vector(1 downto 0) := "00";
    buser : in  std_ulogic_vector(buser_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    -- The read address channel, with the defaults of the write address channel
    arvalid : in  std_ulogic := '0';
    arready : in  std_ulogic := '0';
    arid : in  std_ulogic_vector(id_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    araddr : in  std_ulogic_vector(address_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    arlen : in  std_ulogic_vector(7 downto 0) := (others => '0');
    arsize : in  std_ulogic_vector(2 downto 0) := full_size(get_bus(protocol_checker));
    arburst : in  std_ulogic_vector(1 downto 0) := "01";
    arlock : in  std_ulogic := '0';
    arcache : in  std_ulogic_vector(3 downto 0) := "0000";
    arprot : in  std_ulogic_vector(2 downto 0) := "000";
    arqos : in  std_ulogic_vector(3 downto 0) := "0000";
    arregion : in  std_ulogic_vector(3 downto 0) := "0000";
    aruser : in  std_ulogic_vector(aruser_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    -- The read data channel; RLAST is 1 when left open
    rvalid : in  std_ulogic := '0';
    rready : in  std_ulogic := '0';
    rid : in  std_ulogic_vector(id_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    rdata : in  std_ulogic_vector(data_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0');
    rresp : in  std_ulogic_vector(1 downto 0) := "00";
    rlast : in  std_ulogic := '1';
    ruser : in  std_ulogic_vector(ruser_length(get_bus(protocol_checker)) - 1 downto 0) := (others => '0')
  );
end entity;

architecture a of axi4_protocol_checker is

begin

  main : process

    constant logger : logger_t := get_logger(protocol_checker);
    constant checker : checker_t := get_checker(protocol_checker);
    constant actor : actor_t := get_actor(protocol_checker);
    constant tick_cycles : natural := timeout_cycles(protocol_checker);
    variable session : python_session_t;
    variable batch : sample_batch_t;
    variable sampler : axi4_sampler_t := new_axi4_sampler;
    variable cycles : natural := 0;
    variable resume_time : time := 0 ns;
    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable check : axi4_check_t;
    variable enabled : boolean;

    procedure log_waiting (count : natural) is
    begin

      if count > 0 then
        log_reports(session, logger, checker);
      end if;
    end;

  begin

    session := new_vc_session(get_id(protocol_checker), logger);
    create_backend(
      session,
      "awesome_vunit_vcs.axi4.vunit_backend",
      "Axi4ProtocolCheckerBackend",
      backend_arguments(protocol_checker)
    );
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
        cycles := cycles + 1;
        if tick_cycles > 0 and cycles >= tick_cycles then
          record_axi4_tick(batch, aresetn);
          flush_samples(batch);
          cycles := 0;
        end if;
      end if;

      while now >= resume_time and has_message(actor) loop

        receive(net, actor, msg);
        msg_type := message_type(msg);
        flush_samples(batch);
        cycles := 0;
        if msg_type = wait_until_idle_msg then
          handle_message(msg_type);
          reply_msg := new_msg(wait_until_idle_reply_msg);
          reply(net, msg, reply_msg);
        elsif msg_type = wait_for_time_msg then
          handle_message(msg_type);
          resume_time := now + pop_time(msg);
          delete(msg);
        elsif msg_type = set_axi4_check_enabled_msg then
          check := axi4_check_t'val(integer'(pop(msg)));
          enabled := pop(msg);
          log_waiting(
            backend_call_integer(session, "set_check_enabled", arg_text(axi4_check_t'image(check)) & arg(enabled))
          );
        elsif msg_type = get_axi4_check_count_msg then
          check := axi4_check_t'val(integer'(pop(msg)));
          reply_msg := new_msg(get_axi4_check_count_reply_msg);
          push(reply_msg, backend_call_integer(session, "check_count", arg_text(axi4_check_t'image(check))));
          log_waiting(backend_call_integer(session, "num_reports"));
          reply(net, msg, reply_msg);
        elsif msg_type = reset_axi4_protocol_checker_msg then
          log_waiting(backend_call_integer(session, "reset"));
          sampler := new_axi4_sampler;
          reply_msg := new_msg(reset_axi4_protocol_checker_reply_msg);
          reply(net, msg, reply_msg);
        else
          unexpected_msg_type(msg_type, protocol_checker);
        end if;
      end loop;

      -- Final checks when the test ends, within the gates of test_runner_cleanup
      if is_active(runner_phase) and is_within_gates_of(test_runner_cleanup) then
        flush_samples(batch);
        log_waiting(backend_call_integer(session, "finish", arg_time(now)));
        exit;
      end if;
    end loop;

    wait;
  end process;

end architecture;
