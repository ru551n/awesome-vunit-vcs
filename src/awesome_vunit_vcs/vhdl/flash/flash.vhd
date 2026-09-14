-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- QSPI NOR flash verification component.
--
-- The entity is a pin-level shift engine. It owns what the Python device model
-- cannot have, the wires and simulation time, and leaves every decision about
-- what the wires mean to the model (awesome_vunit_vcs.flash), its backend.
-- After every byte it asks the backend what to do next and gets one packed
-- directive back: receive or transmit, on how many lanes, after how many dummy
-- cycles, and which byte to drive. It does not know that 0xEB carries a mode
-- byte or that programming is AND-only.
--
-- Three processes, deliberately separate:
--
--   * main creates the backend and serves the messages of the testbench;
--   * pins is the shift engine;
--   * busy_timer waits out a program or erase for flash_wait_until_ready. It
--     must not be part of pins, which would then be deaf to the bus for the
--     whole busy time, exactly when a controller polls the status register.
--     The model derives write-in-progress from a deadline and the time pins
--     passes in, so a status poll never races this process.
--
-- A flash_protocol_checker instance checks the pin timing of the controller.
-- Violations and metavalues sampled on the IOs are check failures on the
-- checker of the component, like the content checks of the model.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
use vunit_lib.integer_array_pkg.all;
use vunit_lib.sync_pkg.all;
use vunit_lib.vc_pkg.all;

library python_bridge;
context python_bridge.python_context;

use work.qspi_pkg.all;
use work.flash_pkg.all;
use work.vcs_python_pkg.all;

entity flash is
  generic (
    -- Created with new_flash
    flash : flash_t
  );
  port (
    -- Clock, chip select and the IO drive of the controller
    m2s : in qspi_m2s_t;
    -- The IO drive of the device
    s2m : out qspi_s2m_t := qspi_s2m_init
  );
end entity;

architecture a of flash is
  constant logger : logger_t := get_logger(flash);
  constant checker : checker_t := get_checker(flash);
  constant session : python_session_t := new_vc_session(get_id(flash));

  -- Raised when the backend exists; pins must not call it before
  signal initialized : boolean := false;

  -- The busy time of a program or erase, set by pins
  signal busy_request : time := 0 ns;

  -- Two counters with one driver each, instead of a flag set by busy_timer:
  -- busy_active then goes true in the delta pins starts the busy time, and
  -- flash_wait_until_ready cannot see it false for a device about to be busy.
  signal busy_started : natural := 0;
  signal busy_finished : natural := 0;
  signal busy_active : boolean := false;
begin
  main : process
    variable msg : msg_t;
    variable reply_msg : msg_t;
    variable msg_type : msg_type_t;
    variable data : integer_array_t;
    variable address : natural;
    variable num_bytes : natural;
    variable value : natural;
    variable enable : boolean;
    variable locked : boolean;
    variable num_reports : natural;

    procedure log_waiting_reports(count : natural) is
    begin
      if count > 0 then
        log_reports(session, logger, checker);
      end if;
    end;

    -- The fields of each message are popped in declaration order, since the
    -- evaluation order of the operands of an expression is not defined
    impure function load_image_expression(load_msg : msg_t) return string is
      constant file_name : string := pop_string(load_msg);
      constant format : string := pop_string(load_msg);
      constant base_address : natural := pop(load_msg);
    begin
      return "load_image(" & py_str(file_name) & ", " & py_str(format) & ", " & integer'image(base_address) & ")";
    end;

    impure function set_timing_expression(timing_msg : msg_t) return string is
      constant name : string := pop_string(timing_msg);
      constant duration : time := pop_time(timing_msg);
    begin
      return "set_timing(" & py_str(name) & ", " & python_time_arguments(duration) & ")";
    end;

    impure function get_stat_expression(stat_msg : msg_t) return string is
      constant name : string := pop_string(stat_msg);
    begin
      return "get_stat(" & py_str(name) & ")";
    end;
  begin
    create_backend(session, flash_backend_module, flash_backend_class, backend_arguments(flash));
    log_waiting_reports(backend_integer(session, "num_reports()"));
    check_equal(
      checker,
      backend_integer(session, "layout_version()"),
      flash_layout_version,
      "The directive layout of the Python backend does not match flash_pkg"
    );
    initialized <= true;

    loop
      receive(net, get_actor(flash.p_std_cfg), msg);
      msg_type := message_type(msg);

      handle_sync_message(net, msg_type, msg);

      if msg_type = flash_preload_msg then
        address := pop(msg);
        data := pop_integer_array_t_ref(msg);
        num_reports := call("vc.preload", arg(data), arg(address), session => session);
        deallocate(data);
        log_waiting_reports(num_reports);

      elsif msg_type = flash_preload_fill_msg then
        address := pop(msg);
        num_bytes := pop(msg);
        value := pop(msg);
        log_waiting_reports(
          backend_integer(
            session,
            "preload_fill(" & integer'image(address) & ", " & integer'image(num_bytes) & ", " &
            integer'image(value) & ")"
          )
        );

      elsif msg_type = flash_load_image_msg then
        log_waiting_reports(backend_integer(session, load_image_expression(msg)));

      elsif msg_type = flash_read_back_msg then
        address := pop(msg);
        num_bytes := pop(msg);
        data := backend_integer_array(
          session, "read_back(" & integer'image(address) & ", " & integer'image(num_bytes) & ")"
        );
        log_waiting_reports(backend_integer(session, "num_reports()"));
        reply_msg := new_msg(flash_read_back_reply_msg);
        -- The caller owns the data
        push_integer_array_t_ref(reply_msg, data);
        reply(net, msg, reply_msg);

      elsif msg_type = flash_check_content_msg then
        address := pop(msg);
        data := pop_integer_array_t_ref(msg);
        num_reports := call("vc.check_content", arg(data), arg(address), session => session);
        deallocate(data);
        log_waiting_reports(num_reports);

      elsif msg_type = flash_check_content_fill_msg then
        address := pop(msg);
        num_bytes := pop(msg);
        value := pop(msg);
        log_waiting_reports(
          backend_integer(
            session,
            "check_content_fill(" & integer'image(address) & ", " & integer'image(num_bytes) & ", " &
            integer'image(value) & ")"
          )
        );

      elsif msg_type = flash_written_regions_msg then
        data := backend_integer_array(session, "written_regions()");
        log_waiting_reports(backend_integer(session, "num_reports()"));
        reply_msg := new_msg(flash_written_regions_reply_msg);
        push_integer_array_t_ref(reply_msg, data);
        reply(net, msg, reply_msg);

      elsif msg_type = flash_set_timing_enable_msg then
        enable := pop(msg);
        log_waiting_reports(backend_integer(session, "set_timing_enable(" & py_bool(enable) & ")"));

      elsif msg_type = flash_set_timing_msg then
        log_waiting_reports(backend_integer(session, set_timing_expression(msg)));

      elsif msg_type = flash_set_protection_msg then
        address := pop(msg);
        num_bytes := pop(msg);
        locked := pop(msg);
        log_waiting_reports(
          backend_integer(
            session,
            "set_protection(" & integer'image(address) & ", " & integer'image(num_bytes) & ", " &
            py_bool(locked) & ")"
          )
        );

      elsif msg_type = flash_wait_until_ready_msg then
        -- Cannot see a busy time pins has not started yet: a caller racing
        -- the command it just issued polls the status register instead
        if busy_active then
          wait until not busy_active;
        end if;
        reply_msg := new_msg;
        reply(net, msg, reply_msg);

      elsif msg_type = flash_reset_msg then
        log_waiting_reports(backend_integer(session, "reset()"));
        reply_msg := new_msg;
        reply(net, msg, reply_msg);

      elsif msg_type = flash_get_stat_msg then
        value := backend_integer(session, get_stat_expression(msg));
        log_waiting_reports(backend_integer(session, "num_reports()"));
        reply_msg := new_msg(flash_get_stat_reply_msg);
        push(reply_msg, value);
        reply(net, msg, reply_msg);

      else
        unexpected_msg_type(msg_type, flash.p_std_cfg);
      end if;
    end loop;
  end process;

  flash_protocol_checker_inst : entity work.flash_protocol_checker
    generic map (
      flash => flash
    )
    port map (
      m2s => m2s
    );

  busy_active <= busy_started /= busy_finished;

  busy_timer : process
  begin
    wait until busy_started /= busy_finished;
    wait for busy_request;
    busy_finished <= busy_started;
  end process;

  pins : process
    variable directive : flash_directive_t;
    variable byte : std_ulogic_vector(7 downto 0);
    variable bits_since_byte : natural;
    variable busy_values : integer_array_t;
    variable busy_time : time;
    variable num_reports : natural;

    -- The next directive. pass_now is the volatile flag of the previous
    -- directive: only a byte that depends on time (a status register) needs
    -- the time, so an array read does not pay for it.
    impure function next_directive(byte_in : integer; pass_now : boolean) return flash_directive_t is
    begin
      if pass_now then
        return decode_directive(
          backend_integer(session, "xfer(" & integer'image(byte_in) & ", " & python_time_arguments(now) & ")")
        );
      end if;
      return decode_directive(backend_integer(session, "xfer(" & integer'image(byte_in) & ")"));
    end;

    impure function sampled_lanes(lanes : lane_count_t) return std_ulogic_vector is
    begin
      return qspi_sample_beat(qspi_io_value(m2s, qspi_s2m_init), lanes, qspi_master_side);
    end;

    procedure release_io is
    begin
      s2m.io <= qspi_drive_init after flash.p_t_shqz;
    end;
  begin
    if not initialized then
      wait until initialized;
    end if;

    loop
      release_io;

      if m2s.cs_n /= '0' then
        wait until m2s.cs_n = '0';
      end if;

      bits_since_byte := 0;
      directive := decode_directive(backend_integer(session, "cs_assert(" & python_time_arguments(now) & ")"));

      while m2s.cs_n = '0' loop
        -- Dummy cycles are a prefix of the action, which is what lets the lane
        -- width change at the dummy boundary (0x6B) within one directive
        for cycle in 1 to directive.pre_dummy_cycles loop
          release_io;
          wait until rising_edge(m2s.sck) or m2s.cs_n /= '0';
          exit when m2s.cs_n /= '0';
        end loop;
        exit when m2s.cs_n /= '0';

        case directive.action is
          when receive =>
            release_io;
            byte := (others => '0');
            for beat in 0 to qspi_beats_per_byte(directive.lanes) - 1 loop
              wait until rising_edge(m2s.sck) or m2s.cs_n /= '0';
              exit when m2s.cs_n /= '0';
              if is_x(sampled_lanes(directive.lanes)) then
                check_failed(
                  checker,
                  "Metavalue " & to_string(sampled_lanes(directive.lanes)) & " sampled on the IOs at " &
                  to_string(now)
                );
              end if;
              byte := qspi_byte_insert(
                data => byte,
                lanes => directive.lanes,
                beat => beat,
                value => to_01(sampled_lanes(directive.lanes))
              );
              bits_since_byte := (bits_since_byte + directive.lanes) mod 8;
            end loop;
            exit when m2s.cs_n /= '0';
            directive := next_directive(qspi_to_natural(byte), directive.is_volatile);

          when transmit =>
            byte := qspi_to_byte(directive.byte_out);
            for beat in 0 to qspi_beats_per_byte(directive.lanes) - 1 loop
              -- SPI mode 0: the device changes its output after SCK falls and
              -- the controller samples it on the next rising edge
              wait until falling_edge(m2s.sck) or m2s.cs_n /= '0';
              exit when m2s.cs_n /= '0';
              s2m.io <= qspi_drive_beat(
                data => byte,
                lanes => directive.lanes,
                beat => beat,
                driver => qspi_slave_side
              ) after flash.p_t_clqv;
              wait until rising_edge(m2s.sck) or m2s.cs_n /= '0';
              exit when m2s.cs_n /= '0';
              bits_since_byte := (bits_since_byte + directive.lanes) mod 8;
            end loop;
            exit when m2s.cs_n /= '0';
            -- -1: the device clocked a byte out
            directive := next_directive(-1, directive.is_volatile);

          when ignore_rest =>
            release_io;
            wait until m2s.cs_n /= '0';
        end case;
      end loop;

      release_io;

      -- The trailing bits matter: a real part aborts a page program or status
      -- write whose clock count is not a multiple of 8
      busy_values := backend_integer_array(
        session, "cs_deassert(" & integer'image(bits_since_byte) & ", " & python_time_arguments(now) & ")"
      );
      busy_time := from_python_time(get(busy_values, 0), get(busy_values, 1));
      num_reports := get(busy_values, 2);
      deallocate(busy_values);

      if num_reports > 0 then
        log_reports(session, logger, checker);
      end if;

      if busy_time > 0 fs then
        busy_request <= busy_time;
        busy_started <= busy_started + 1;
      end if;
    end loop;
  end process;
end architecture;
