-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Negative tests of the I2C protocol checker: every check is violated on
-- purpose, by a master with one Fast-mode time too short, by a transfer
-- written as operations, or by the testbench driving the lines, and the test
-- asserts that exactly that check counts it.

library awesome_vunit_vcs;
context awesome_vunit_vcs.i2c_context;

entity tb_i2c_protocol_checker is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_i2c_protocol_checker is

  type master_array_t is array (natural range <>) of i2c_master_t;

  -- Masters with one time below the Fast-mode limit, in this order
  constant good_idx : natural := 0;
  constant low_idx : natural := 1;
  constant high_idx : natural := 2;
  constant period_idx : natural := 3;
  constant hd_sta_idx : natural := 4;
  constant su_sta_idx : natural := 5;
  constant su_sto_idx : natural := 6;
  constant buf_idx : natural := 7;
  constant su_dat_idx : natural := 8;
  constant masters : master_array_t(0 to 8) := (
    new_i2c_master(speed => i2c_fast_mode),
    new_i2c_master(speed => i2c_fast_mode, t_low => 1 us, t_high => 1500 ns),
    new_i2c_master(speed => i2c_fast_mode, t_low => 2 us, t_high => 500 ns),
    new_i2c_master(speed => i2c_fast_mode, t_low => 1300 ns, t_high => 900 ns),
    new_i2c_master(speed => i2c_fast_mode, t_hd_sta => 400 ns),
    new_i2c_master(speed => i2c_fast_mode, t_su_sta => 400 ns),
    new_i2c_master(speed => i2c_fast_mode, t_su_sto => 400 ns),
    new_i2c_master(speed => i2c_fast_mode, t_buf => 1 us),
    new_i2c_master(speed => i2c_fast_mode, t_hd_dat => 1250 ns)
  );

  constant target : i2c_target_t := new_i2c_target(address => 16#50#);
  constant checker_vc : i2c_protocol_checker_t := new_i2c_protocol_checker(
    speed => i2c_fast_mode,
    t_stuck => 100 us,
    id => get_id("tb_i2c_protocol_checker:checker")
  );
  -- Asks for 500 ns of data hold time, which the default master does not give
  constant hold_checker : i2c_protocol_checker_t := new_i2c_protocol_checker(
    speed => i2c_fast_mode,
    t_hd_dat => 500 ns,
    id => get_id("tb_i2c_protocol_checker:hold_checker")
  );

  signal scl : std_logic := 'H';
  signal sda : std_logic := 'H';

begin

  scl <= 'H';
  sda <= 'H';

  masters_gen : for idx in masters'range generate
    master_inst : entity awesome_vunit_vcs.i2c_master
      generic map (
        master => masters(idx)
      )
      port map (
        scl => scl,
        sda => sda
      );

  end generate masters_gen;

  target_inst : entity awesome_vunit_vcs.i2c_target
    generic map (
      target => target
    )
    port map (
      scl => scl,
      sda => sda
    );

  checker_inst : entity awesome_vunit_vcs.i2c_protocol_checker
    generic map (
      protocol_checker => checker_vc
    )
    port map (
      scl => scl,
      sda => sda
    );

  hold_checker_inst : entity awesome_vunit_vcs.i2c_protocol_checker
    generic map (
      protocol_checker => hold_checker
    )
    port map (
      scl => scl,
      sda => sda
    );

  main : process

    variable data : std_ulogic_vector(7 downto 0);
    variable result : i2c_result_t;
    variable count : natural;
    variable reference : i2c_protocol_checker_reference_t;

    -- Exactly one check of the checker found violations
    procedure check_only (expected : i2c_check_t) is
    begin

      wait_until_idle(net, as_sync(checker_vc));
      for item in i2c_check_t'low to i2c_stuck_low loop

        get_check_count(net, checker_vc, item, count);
        if item = expected then
          check(count > 0, i2c_check_t'image(item) & " counts the violation");
        else
          check_equal(count, 0, "violations of " & i2c_check_t'image(item));
        end if;
      end loop;

      check(
        get_log_count(get_logger(get_checker(checker_vc)), error) > 0,
        "violations are check failures on the checker"
      );
      reset_log_count(get_logger(get_checker(checker_vc)), error);
    end;

    procedure write_read (idx : natural) is
    begin

      i2c_write_read(net, masters(idx), 16#50#, x"00", data);
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    disable_stop(get_logger(get_checker(checker_vc)), error);
    -- Only test_t_hd_dat asks the hold checker
    set_check_enabled(net, hold_checker, i2c_t_hd_dat, false);
    set_check_enabled(net, hold_checker, i2c_t_su_dat, false);
    set_check_enabled(net, hold_checker, i2c_t_low, false);
    set_check_enabled(net, hold_checker, i2c_t_high, false);
    set_check_enabled(net, hold_checker, i2c_f_scl, false);
    set_check_enabled(net, hold_checker, i2c_t_hd_sta, false);
    set_check_enabled(net, hold_checker, i2c_t_su_sta, false);
    set_check_enabled(net, hold_checker, i2c_t_su_sto, false);
    set_check_enabled(net, hold_checker, i2c_t_buf, false);
    set_check_enabled(net, hold_checker, i2c_sda_stable, false);
    set_check_enabled(net, hold_checker, i2c_ack_slot, false);
    set_check_enabled(net, hold_checker, i2c_metavalue, false);
    set_check_enabled(net, hold_checker, i2c_stuck_low, false);
    wait_until_idle(net, as_sync(hold_checker));

    while test_suite loop

      if run("test_traffic_within_the_limits_passes") then
        write_read(good_idx);
        i2c_write(net, masters(good_idx), 16#50#, x"0102");
        wait_until_idle(net, as_sync(masters(good_idx)));
        wait_until_idle(net, as_sync(checker_vc));
        for item in i2c_check_t'low to i2c_stuck_low loop

          get_check_count(net, checker_vc, item, count);
          check_equal(count, 0, "violations of " & i2c_check_t'image(item));
        end loop;

      elsif run("test_t_low") then
        write_read(low_idx);
        check_only(i2c_t_low);

      elsif run("test_t_high") then
        write_read(high_idx);
        check_only(i2c_t_high);

      elsif run("test_f_scl") then
        write_read(period_idx);
        check_only(i2c_f_scl);

      elsif run("test_t_hd_sta") then
        write_read(hd_sta_idx);
        check_only(i2c_t_hd_sta);

      elsif run("test_t_su_sta") then
        write_read(su_sta_idx);
        check_only(i2c_t_su_sta);

      elsif run("test_t_su_sto") then
        write_read(su_sto_idx);
        check_only(i2c_t_su_sto);

      elsif run("test_t_buf") then
        write_read(buf_idx);
        write_read(buf_idx);
        check_only(i2c_t_buf);
        get_check_count(net, checker_vc, i2c_t_buf, count);
        check_equal(count, 1, "one START too early");

      elsif run("test_t_su_dat") then
        write_read(su_dat_idx);
        check_only(i2c_t_su_dat);

      elsif run("test_t_hd_dat") then
        disable_stop(get_logger(get_checker(hold_checker)), error);
        set_check_enabled(net, hold_checker, i2c_t_hd_dat, true);
        write_read(good_idx);
        wait_until_idle(net, as_sync(hold_checker));
        get_check_count(net, hold_checker, i2c_t_hd_dat, count);
        check(count > 0, "the data hold time of 500 ns is not met");
        reset_log_count(get_logger(get_checker(hold_checker)), error);

      elsif run("test_sda_stable") then
        -- A STOP after 3 bits of a byte
        i2c_transfer(net, masters(good_idx), "S 0xA0 B101 P", result);
        check_only(i2c_sda_stable);

      elsif run("test_ack_slot") then
        -- A STOP right after the 8 bits of a byte, to an address no target answers
        i2c_transfer(net, masters(good_idx), "S B10110000 P", result);
        check_only(i2c_ack_slot);

      elsif run("test_metavalue") then
        sda <= 'X';
        wait for 1 us;
        sda <= 'Z';
        wait for 1 us;
        check_only(i2c_metavalue);

      elsif run("test_stuck_low") then
        scl <= '0';
        wait for 150 us;
        scl <= 'Z';
        wait for 1 us;
        check_only(i2c_stuck_low);
        get_check_count(net, checker_vc, i2c_stuck_low, count);
        check_equal(count, 1, "reported once");

      elsif run("test_a_disabled_check_neither_reports_nor_counts") then
        set_check_enabled(net, checker_vc, i2c_t_low, false);
        write_read(low_idx);
        wait_until_idle(net, as_sync(checker_vc));
        get_check_count(net, checker_vc, i2c_t_low, count);
        check_equal(count, 0, "a disabled check does not count");
        check_equal(get_log_count(get_logger(get_checker(checker_vc)), error), 0, "nor report");

      elsif run("test_reset_clears_the_counts") then
        write_read(low_idx);
        wait_until_idle(net, as_sync(checker_vc));
        get_check_count(net, checker_vc, i2c_t_low, reference);
        await_get_check_count_reply(net, reference, count);
        check(count > 0, "counted before the reset");
        reset(net, checker_vc);
        get_check_count(net, checker_vc, i2c_t_low, count);
        check_equal(count, 0, "after the reset");
        reset_log_count(get_logger(get_checker(checker_vc)), error);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 20 ms);
end architecture;
