-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- QSPI protocol checker verification component: the rules, one violation at a
-- time.
--
-- The testbench drives a raw bus without a master, frames of SPI mode 0 with
-- every timing a parameter, and breaks one rule in each test. The per-rule
-- counts prove the violation was attributed to that rule and to no other.
-- A second checker on the raw bus has a 0 ns tSHSL, and a third checker sits
-- on the bus of a QSPI master, which must give no violations at all.

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_qspi_protocol_checker is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_qspi_protocol_checker is

  -- docs-start: protocol_checker_constructor
  constant raw_checker : qspi_protocol_checker_t :=
    new_qspi_protocol_checker(id => get_id("tb_qspi_protocol_checker:raw_checker"));
  -- docs-end: protocol_checker_constructor
  constant no_deselect_checker : qspi_protocol_checker_t :=
    new_qspi_protocol_checker(t_shsl => 0 ns, id => get_id("tb_qspi_protocol_checker:no_deselect_checker"));
  signal raw_m2s : qspi_m2s_t := qspi_m2s_init;

  constant master : qspi_master_t := new_qspi_master(sck_period => 20 ns);
  constant master_checker : qspi_protocol_checker_t :=
    new_qspi_protocol_checker(id => get_id("tb_qspi_protocol_checker:master_checker"));
  signal master_m2s : qspi_m2s_t := qspi_m2s_init;
  signal master_s2m : qspi_s2m_t := qspi_s2m_init;

begin

  -- docs-start: protocol_checker_instance
  raw_checker_inst : entity awesome_vunit_vcs.qspi_protocol_checker
    generic map (
      protocol_checker => raw_checker
    )
    port map (
      m2s => raw_m2s,
      s2m => qspi_s2m_init
    );

  -- docs-end: protocol_checker_instance

  no_deselect_checker_inst : entity awesome_vunit_vcs.qspi_protocol_checker
    generic map (
      protocol_checker => no_deselect_checker
    )
    port map (
      m2s => raw_m2s,
      s2m => qspi_s2m_init
    );

  qspi_master_inst : entity awesome_vunit_vcs.qspi_master
    generic map (
      qspi_master => master
    )
    port map (
      m2s => master_m2s,
      s2m => master_s2m
    );

  master_checker_inst : entity awesome_vunit_vcs.qspi_protocol_checker
    generic map (
      protocol_checker => master_checker
    )
    port map (
      m2s => master_m2s,
      s2m => master_s2m
    );

  main : process

    variable count : natural;
    variable cmd : integer_array_t;
    variable data : integer_array_t;

    -- One frame on the raw bus. The lane toggles once between two beats,
    -- change_offset after the rising edge; the defaults meet every rule with
    -- a margin. CS stays high for 5 ns before the frame, while the lanes are
    -- driven, and for deselect_after after it.
    procedure send_frame (
      high : delay_length := 10 ns;
      low : delay_length := 10 ns;
      slch : delay_length := 10 ns;
      chsh : delay_length := 10 ns;
      change_offset : delay_length := 10 ns;
      beats : positive := 2;
      toggled_lane : natural := 0;
      deselect_after : delay_length := 50 ns
    ) is
    begin

      raw_m2s.io <= (value => "0000", enable => "0001");
      wait for 5 ns;
      raw_m2s.cs_n <= '0';
      wait for slch;
      for beat in 1 to beats loop

        raw_m2s.sck <= '1';
        if beat = beats then
          wait for high;
          raw_m2s.sck <= '0';
        elsif change_offset < high then
          wait for change_offset;
          raw_m2s.io.value(toggled_lane) <= not raw_m2s.io.value(toggled_lane);
          wait for high - change_offset;
          raw_m2s.sck <= '0';
          wait for low;
        else
          wait for high;
          raw_m2s.sck <= '0';
          wait for change_offset - high;
          raw_m2s.io.value(toggled_lane) <= not raw_m2s.io.value(toggled_lane);
          wait for high + low - change_offset;
        end if;
      end loop;

      wait for chsh;
      raw_m2s.cs_n <= '1';
      raw_m2s.io <= qspi_drive_init;
      wait for deselect_after;
    end;

    -- Every count of protocol_checker is 0, except expected for violated
    procedure check_counts (protocol_checker : qspi_protocol_checker_t; violated : qspi_check_t; expected : natural) is
    begin

      for rule in qspi_check_t loop

        get_check_count(net, protocol_checker, rule, count);
        if rule = violated then
          check_equal(count, expected, "violations of " & qspi_check_t'image(rule));
        else
          check_equal(count, 0, "violations of " & qspi_check_t'image(rule));
        end if;
      end loop;

    end;

    procedure check_no_violations (protocol_checker : qspi_protocol_checker_t) is
    begin

      check_counts(protocol_checker, qspi_check_t'low, 0);
    end;

    -- One error on the logger of the raw checker, then clear it
    procedure check_one_error is
    begin

      check_equal(get_log_count(get_logger(raw_checker), error), 1, "errors logged");
      reset_log_count(get_logger(raw_checker), error);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    disable_stop(get_logger(raw_checker), error);
    -- It sees the violations of the raw bus too, which tests check on
    -- raw_checker, and its own counts where they differ
    disable_stop(get_logger(no_deselect_checker), error);

    while test_suite loop

      if run("test_clean_raw_frames_have_no_violations") then
        send_frame;
        send_frame;
        check_no_violations(raw_checker);
        check_no_violations(no_deselect_checker);

      elsif run("test_sck_period_violation") then
        send_frame;
        send_frame(high => 3 ns, low => 3 ns, change_offset => 3 ns);
        check_counts(raw_checker, qspi_sck_period, 1);
        check_one_error;

      elsif run("test_sck_high_violation") then
        send_frame;
        send_frame(high => 2 ns, beats => 1);
        check_counts(raw_checker, qspi_sck_high, 1);
        check_one_error;

      elsif run("test_sck_low_violation") then
        send_frame;
        send_frame(low => 2 ns, change_offset => 9 ns);
        check_counts(raw_checker, qspi_sck_low, 1);
        check_one_error;

      elsif run("test_cs_setup_violation") then
        send_frame;
        send_frame(slch => 2 ns);
        check_counts(raw_checker, qspi_cs_setup, 1);
        check_one_error;

      elsif run("test_cs_hold_violation") then
        -- The last rising edge is 3 ns + 1 ns before CS rises
        send_frame;
        mock(get_logger(raw_checker), error);
        send_frame(high => 3 ns, chsh => 1 ns);
        check_only_log(
          get_logger(raw_checker),
          "QSPI_CS_HOLD: last SCK rising edge to CS high 4 ns is shorter than the 5 ns minimum",
          error
        );
        unmock(get_logger(raw_checker));
        check_counts(raw_checker, qspi_cs_hold, 1);
        reset_log_count(get_logger(raw_checker), error);

      elsif run("test_cs_hold_is_measured_from_the_last_rising_edge") then
        -- SPI mode 0: the last rising edge is 10 ns + 2 ns before CS rises,
        -- the falling edge after it only 2 ns
        send_frame(chsh => 2 ns);
        check_no_violations(raw_checker);
        check_equal(get_log_count(get_logger(raw_checker), error), 0, "errors of a compliant CS hold");

      elsif run("test_cs_deselect_violation") then
        -- docs-start: protocol_checker_cs_deselect
        -- 20 ns after the first frame and 5 ns before the second
        mock(get_logger(raw_checker), error);
        send_frame(deselect_after => 20 ns);
        send_frame;
        check_only_log(
          get_logger(raw_checker),
          "QSPI_CS_DESELECT: CS high time between commands 25 ns is shorter than the 30 ns minimum",
          error
        );
        unmock(get_logger(raw_checker));
        check_counts(raw_checker, qspi_cs_deselect, 1);
        reset_log_count(get_logger(raw_checker), error);
      -- docs-end: protocol_checker_cs_deselect

      elsif run("test_data_setup_violation") then
        send_frame;
        send_frame(change_offset => 19 ns);
        check_counts(raw_checker, qspi_data_setup, 1);
        check_one_error;

      elsif run("test_data_hold_violation") then
        send_frame;
        send_frame(change_offset => 1 ns);
        check_counts(raw_checker, qspi_data_hold, 1);
        check_one_error;

      elsif run("test_undriven_lanes_have_no_data_timing") then
        -- Lane 3 is not driven, so changing it next to an edge is no violation
        send_frame(change_offset => 1 ns, toggled_lane => 3);
        send_frame(change_offset => 19 ns, toggled_lane => 3);
        check_no_violations(raw_checker);

      elsif run("test_disabled_check_is_not_reported") then
        -- docs-start: protocol_checker_disable
        set_check_enabled(net, raw_checker, qspi_cs_hold, false);
        send_frame(high => 3 ns, chsh => 1 ns);
        check_no_violations(raw_checker);
        check_equal(get_log_count(get_logger(raw_checker), error), 0, "errors of a disabled check");

        set_check_enabled(net, raw_checker, qspi_cs_hold, true);
        send_frame(high => 3 ns, chsh => 1 ns);
        check_counts(raw_checker, qspi_cs_hold, 1);
        check_one_error;
      -- docs-end: protocol_checker_disable

      elsif run("test_zero_limit_disables_the_check") then
        send_frame(deselect_after => 20 ns);
        send_frame;
        check_counts(raw_checker, qspi_cs_deselect, 1);
        check_one_error;
        check_no_violations(no_deselect_checker);

      elsif run("test_reset_clears_counts_and_timing_history") then
        send_frame(deselect_after => 20 ns);
        send_frame;
        -- docs-start: protocol-checker-reset
        check_counts(raw_checker, qspi_cs_deselect, 1);
        check_one_error;
        reset(net, raw_checker);
        check_no_violations(raw_checker);
        -- docs-end: protocol-checker-reset

        -- CS is high for 10 ns around the reset, but the CS rise before it is
        -- forgotten: no tSHSL violation
        send_frame(deselect_after => 5 ns);
        reset(net, raw_checker);
        send_frame;
        check_no_violations(raw_checker);
        check_equal(get_log_count(get_logger(raw_checker), error), 0, "errors after the reset");

      elsif run("test_clean_master_transfer_has_no_violations") then
        cmd := new_byte_array((0 => 16#32#));
        data := new_byte_array((16#12#, 16#34#, 16#56#, 16#78#));
        for idx in 1 to 3 loop

          qspi_transfer(
            net,
            master,
            cmd => cmd,
            addr => new_byte_array((16#00#, 16#10#, 16#00#)),
            wr_data => data,
            wr_lanes => 4,
            dummy_cycles => 2
          );
        end loop;

        deallocate(cmd);
        deallocate(data);
        check_no_violations(master_checker);
      end if;

      reset_log_count(get_logger(no_deselect_checker), error);
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 ms);
end architecture;
