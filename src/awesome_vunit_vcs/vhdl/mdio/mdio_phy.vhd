-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- MDIO PHY verification component: a Clause 22 PHY at one address.
--
-- The entity samples MDIO on rising MDC edges and, in a read, drives TA and
-- the data the clock-to-output delay after rising MDC edges. Its Python
-- backend (awesome_vunit_vcs.mdio.phy and a device model) checks the frames
-- and holds the registers. It calls the backend twice per frame, after REGAD
-- and after the last data bit, never per clock edge.
--
-- Two processes: main creates the backend and serves the messages of the
-- testbench; pins follows the bus.

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

use work.mdio_pkg.all;
use work.mdio_phy_pkg.all;
use work.vc_python_pkg.all;

entity mdio_phy is
  generic (
    -- Created with :vhdl:`mdio_phy_pkg.new_mdio_phy`
    phy : mdio_phy_t
  );
  port (
    -- The management clock, driven by the master
    mdc : in std_ulogic;
    -- The management data line: released 'Z', or driven '0' and '1' in the TA
    -- and data of a read
    mdio : inout std_logic := 'Z'
  );
end entity;

architecture a of mdio_phy is

  constant logger : logger_t := get_logger(phy);
  constant checker : checker_t := get_checker(phy);
  constant session : python_session_t := new_vc_session(get_id(phy), logger);

  -- Raised when the backend exists; pins must not call it before
  signal initialized : boolean := false;
  signal output_delay : delay_length := clock_to_output_delay(phy);
  -- Changed by main when a reset asks pins to release MDIO, and set to it by
  -- pins when it did
  signal reset_count : natural := 0;
  signal reset_done : natural := 0;
  -- What the PHY drives on MDIO, 'Z' when released
  signal phy_level : std_ulogic := 'Z';

begin

  main : process

    variable msg, reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable register_address : natural;
    variable value : std_ulogic_vector(15 downto 0);
    variable delay : delay_length;
    variable operation_code : natural;
    variable reset_number : natural;

    procedure log_waiting(count : natural)is
    begin

      if count > 0 then
        log_reports(session, logger, checker);
      end if;
    end procedure;

  begin
    create_backend(
      session,
      "awesome_vunit_vcs.mdio.vunit_backend",
      "MdioPhyBackend",
      backend_arguments(phy)
    );
    backend_call(session, "set_arguments", model_arguments(phy));
    log_waiting(backend_call_integer(session, "create_device", arg_text(model(phy))));
    initialized <= true;

    loop

      receive(net, get_actor(phy), msg);
      -- A frame ending at this time reaches the model first
      wait for 0 ns;
      msg_type := message_type(msg);
      handle_sync_message(net, msg_type, msg);

      if msg_type = set_mdio_phy_clock_to_output_delay_msg then
        delay := pop(msg);
        if delay > mdio_max_clock_to_output_delay then
          check_failed(
            checker,
            "A clock-to-output delay of "
            & time'image(delay)
            & " exceeds "
            & time'image(mdio_max_clock_to_output_delay)
            & "."
          );
        end if;
        output_delay <= delay;
      elsif msg_type = set_mdio_phy_register_msg then
        register_address := pop(msg);
        value := pop_std_ulogic_vector(msg);
        log_waiting(
          backend_call_integer(
            session,
            "set_register",
            arg(register_address) & arg(to_integer(unsigned(to_01(value))))
          )
        );
      elsif msg_type = check_mdio_phy_register_msg then
        register_address := pop(msg);
        value := pop_std_ulogic_vector(msg);
        log_waiting(
          backend_call_integer(
            session,
            "check_register",
            arg(register_address)
            & arg(to_integer(unsigned(to_01(value))))
            & arg_text(pop_string(msg))
            & arg_time(now)
          )
        );
      elsif msg_type = get_mdio_phy_register_msg then
        register_address := pop(msg);
        value := std_ulogic_vector(
          to_unsigned(backend_call_integer(session, "get_register", arg(register_address)), 16)
        );
        log_waiting(backend_call_integer(session, "num_reports"));
        reply_msg := new_msg(get_mdio_phy_register_reply_msg);
        push_std_ulogic_vector(reply_msg, value);
        reply(net, msg, reply_msg);
      elsif msg_type = get_mdio_phy_access_count_msg then
        operation_code := pop(msg);
        reply_msg := new_msg(get_mdio_phy_access_count_reply_msg);
        push(
          reply_msg,
          backend_call_integer(
            session,
            "access_count",
            arg(operation_code) & arg(integer'(pop(msg)))
          )
        );
        log_waiting(backend_call_integer(session, "num_reports"));
        reply(net, msg, reply_msg);
      elsif msg_type = get_mdio_phy_check_count_msg then
        reply_msg := new_msg(get_mdio_phy_check_count_reply_msg);
        push(reply_msg, backend_call_integer(session, "check_count", arg_text(pop_string(msg))));
        log_waiting(backend_call_integer(session, "num_reports"));
        reply(net, msg, reply_msg);
      elsif msg_type = reset_mdio_phy_msg then
        log_waiting(backend_call_integer(session, "reset"));
        reset_number := reset_count + 1;
        reset_count <= reset_number;
        wait until reset_done = reset_number;
        reply_msg := new_msg(reset_mdio_phy_reply_msg);
        reply(net, msg, reply_msg);
      else
        unexpected_msg_type(msg_type, phy);
      end if;
    end loop;

  end process;

  pins : process

    constant ignore_action : natural := 0;
    constant write_action : natural := 1;

    type state_t is (idle, header, ignoring, writing, reading);

    variable state : state_t := idle;
    variable sample : std_ulogic;
    variable value : std_ulogic;
    -- Preamble ones before the frame, capped
    variable ones : natural := 0;
    -- Bits of the current field, and their value with metavalues as 0
    variable count : natural := 0;
    variable bits : natural := 0;
    variable metavalues : natural := 0;
    variable response : integer_array_t;
    variable data : std_ulogic_vector(15 downto 0);
    variable ta_driven : boolean;
    variable contention_bits : natural := 0;

    procedure take_bit is
    begin

      bits := 2 * bits;
      if value = '1' then
        bits := bits + 1;
      elsif value /= '0' then
        metavalues := metavalues + 1;
      end if;
      count := count + 1;
    end procedure;

    procedure drive(level : std_ulogic)is
    begin

      mdio <= transport level after output_delay;
      phy_level <= transport level after output_delay;
    end procedure;

  begin
    if not initialized then
      wait until initialized;
    end if;

    loop

      wait on mdc, reset_count;
      if reset_count'event then
        mdio <= transport 'Z';
        phy_level <= transport 'Z';
        state := idle;
        ones := 0;
        reset_done <= reset_count;
      elsif rising_edge(mdc) then
        sample := mdio;
        value := to_x01(sample);

        case state is

          when idle =>
            if value = '1' then
              ones := minimum(ones + 1, 1000);
            elsif value = '0' then
              state := header;
              count := 1;
              bits := 0;
              metavalues := 0;
            else
              ones := 0;
            end if;

          when header =>
            take_bit;
            if count = 14 then
              response := backend_call_integer_array(
                session,
                "header",
                arg(ones) & arg(bits) & arg(metavalues) & arg_time(now)
              );
              if get(response, 2) > 0 then
                log_reports(session, logger, checker);
              end if;
              data := std_ulogic_vector(to_unsigned(get(response, 1), 16));
              count := 0;
              bits := 0;
              metavalues := 0;
              ones := 0;
              if get(response, 0) = ignore_action then
                state := ignoring;
              elsif get(response, 0) = write_action then
                state := writing;
              else
                state := reading;
                contention_bits := 0;
              end if;
              deallocate(response);
            end if;

          when ignoring =>
            count := count + 1;
            if count = 18 then
              state := idle;
            end if;

          when writing =>
            take_bit;
            if count = 18 then
              if backend_call_integer(
                   session,
                   "write_end",
                   arg(bits / 2 ** 16) & arg(bits mod 2 ** 16) & arg(metavalues) & arg_time(now)
                 )
                 > 0 then
                log_reports(session, logger, checker);
              end if;
              state := idle;
            end if;

          when reading =>
            count := count + 1;
            if count = 1 then
              -- The first TA bit belongs to the pull-up
              ta_driven := sample = '0' or sample = '1' or sample = 'X';
              drive('0');
            else
              if phy_level /= 'Z' and value /= phy_level then
                contention_bits := contention_bits + 1;
              end if;
              if count < 18 then
                drive(data(17 - count));
              else
                drive('Z');
                if backend_call_integer(
                     session,
                     "read_end",
                     arg(ta_driven)
                     & arg(contention_bits)
                     & arg(to_integer(unsigned(data)))
                     & arg_time(now)
                   )
                   > 0 then
                  log_reports(session, logger, checker);
                end if;
                state := idle;
              end if;
            end if;

        end case;
      end if;
    end loop;

  end process;

end architecture;
