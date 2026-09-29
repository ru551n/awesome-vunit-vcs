-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The MDIO master and three PHYs on one bus: reads and writes, the register
-- file, addressing, TA, the clock-to-output delay and every check of the PHY.

library awesome_vunit_vcs;
context awesome_vunit_vcs.mdio_context;

library osvvm;
use osvvm.randompkg.randomptype;

entity tb_mdio is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_mdio is

  constant master : mdio_master_t := new_mdio_master(id => get_id("tb_mdio:master"));
  constant phy : mdio_phy_t := new_mdio_phy(phy_address => 5, id => get_id("tb_mdio:phy"));
  -- The slowest PHY the standard allows
  constant slow_phy : mdio_phy_t := new_mdio_phy(
    phy_address => 9,
    clock_to_output_delay => mdio_max_clock_to_output_delay,
    id => get_id("tb_mdio:slow_phy")
  );
  -- A PHY that accepts frames without a preamble
  constant no_preamble_phy : mdio_phy_t :=
    new_mdio_phy(phy_address => 12, preamble_bits => 0, id => get_id("tb_mdio:no_preamble_phy"));

  signal mdc : std_ulogic;
  signal mdio : std_logic := 'H';

begin

  -- The pull-up of MDIO
  mdio <= 'H';

  master_inst : entity awesome_vunit_vcs.mdio_master
    generic map (
      master => master
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  slow_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => slow_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  no_preamble_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => no_preamble_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  main : process

    -- Bit positions in a frame with a 32-bit preamble
    constant op : natural := 34;
    constant ta : natural := 46;
    constant data_msb : natural := 48;

    type values_t is array (0 to 31) of std_ulogic_vector(15 downto 0);

    variable rnd : randomptype;
    variable data : std_ulogic_vector(15 downto 0);
    variable values : values_t;
    variable count : natural;
    variable bits : std_ulogic_vector(0 to 63);
    variable sampled : std_ulogic_vector(0 to 63);
    variable reference : mdio_master_reference_t;
    variable start : time;

    -- Exactly one check of target found violations, and they were check failures
    procedure check_only(target : mdio_phy_t; expected : mdio_check_t)is
    begin

      for item in mdio_check_t'low to mdio_check_t'high loop

        get_mdio_phy_check_count(net, target, item, count);
        if item = expected then
          check(count > 0, mdio_check_t'image(item) & " counts the violation");
        else
          check_equal(count, 0, "violations of " & mdio_check_t'image(item));
        end if;
      end loop;

      check(get_log_count(get_logger(target), error) > 0, "violations are check failures");
      reset_log_count(get_logger(target), error);
    end procedure;

    -- A read of target's register 1 whose first data bit arrives the
    -- clock-to-output delay after the rising MDC edge of the first TA bit
    procedure check_clock_to_output_delay(target : mdio_phy_t; delay : delay_length)is
    begin

      set_mdio_phy_register(net, target, 1, x"4C3A");
      read_mdio(net, master, phy_address(target), 1, reference);
      for edge in 0 to ta loop

        wait until rising_edge(mdc);
      end loop;

      start := now;
      wait on mdio;
      check_equal(now - start, delay, "clock-to-output delay");
      check_equal(mdio, '0', "the second TA bit");
      await_read_mdio_reply(net, reference, data);
      check_equal(data, std_ulogic_vector'(x"4C3A"), "the data read");
    end procedure;

  begin
    test_runner_setup(runner, runner_cfg);
    rnd.InitSeed(get_string_seed(runner_cfg));
    disable_stop(get_logger(phy), error);

    while test_suite loop

      if run("test_write_then_read_back") then
        -- Patterns that a bit shifted by one would change
        write_mdio(net, master, 5, 3, x"4C3A");
        read_mdio(net, master, 5, 3, data);
        check_equal(data, std_ulogic_vector'(x"4C3A"), "0x4C3A read back");
        write_mdio(net, master, 5, 3, x"A5C3");
        read_mdio(net, master, 5, 3, data);
        check_equal(data, std_ulogic_vector'(x"A5C3"), "0xA5C3 read back");
        check_mdio_phy_register(net, phy, 3, x"A5C3", "the register file");

      elsif run("test_every_register_holds_its_value") then
        for register_address in values'range loop

          values(register_address) := rnd.RandSlv(16);
          write_mdio(net, master, 5, register_address, values(register_address));
        end loop;

        for register_address in values'range loop

          read_mdio(net, master, 5, register_address, data);
          check_equal(
            data,
            values(register_address),
            "register " & integer'image(register_address)
          );
        end loop;

      elsif run("test_registers_are_set_and_read_without_the_bus") then
        set_mdio_phy_register(net, phy, 2, x"0141");
        read_mdio(net, master, 5, 2, data);
        check_equal(data, std_ulogic_vector'(x"0141"), "a set register reads over MDIO");
        write_mdio(net, master, 5, 20, x"1234");
        wait_until_idle(net, as_sync(master));
        get_mdio_phy_register(net, phy, 20, data);
        check_equal(data, std_ulogic_vector'(x"1234"), "a written register reads without the bus");

      elsif run("test_other_phy_addresses_are_ignored") then
        set_mdio_phy_register(net, phy, 1, x"796D");
        read_mdio(net, master, 7, 1, data);
        check_equal(data, std_ulogic_vector'(x"FFFF"), "no PHY at 7 reads as the pull-up");
        write_mdio(net, master, 7, 1, x"0000");
        wait_until_idle(net, as_sync(master));
        check_mdio_phy_register(net, phy, 1, x"796D", "a write to PHY 7");
        get_mdio_phy_access_count(net, phy, count);
        check_equal(count, 0, "frames PHY 5 answered");
        get_mdio_phy_access_count(net, slow_phy, count);
        check_equal(count, 0, "frames PHY 9 answered");

      elsif run("test_access_counts") then
        write_mdio(net, master, 5, 4, x"0001");
        write_mdio(net, master, 5, 4, x"0002");
        read_mdio(net, master, 5, 4, data);
        read_mdio(net, master, 5, 6, data);
        get_mdio_phy_access_count(net, phy, count);
        check_equal(count, 4, "every frame");
        get_mdio_phy_access_count(net, phy, mdio_write_op, count);
        check_equal(count, 2, "writes");
        get_mdio_phy_access_count(net, phy, mdio_read_op, count, register_address => 6);
        check_equal(count, 1, "reads of register 6");

      elsif run("test_read_releases_the_first_ta_bit_and_drives_zero") then
        set_mdio_phy_register(net, phy, 0, x"8001");
        transfer_mdio(net, master, mdio_frame(mdio_read_op, 5, 0), sampled);
        check_equal(sampled(ta), 'H', "the first TA bit is the pull-up");
        check_equal(sampled(ta + 1), '0', "the PHY drives the second TA bit");
        check_equal(sampled(data_msb to data_msb + 15), std_ulogic_vector'(x"8001"), "the data");

      elsif run("test_write_with_a_bad_ta_is_reported_and_not_made") then
        bits := mdio_frame(mdio_write_op, 5, 8, x"BEEF");
        bits(ta to ta + 1) := "11";
        transfer_mdio(net, master, bits, sampled);
        check_only(phy, mdio_ta);
        get_mdio_phy_register(net, phy, 8, data);
        check_equal(data, std_ulogic_vector'(x"0000"), "register 8 after the bad write");

      elsif run("test_master_driving_the_first_read_ta_bit_is_reported") then
        bits := mdio_frame(mdio_read_op, 5, 0);
        bits(ta) := '1';
        transfer_mdio(net, master, bits, sampled);
        check_only(phy, mdio_ta);

      elsif run("test_master_driving_read_data_is_reported") then
        bits := mdio_frame(mdio_read_op, 5, 0);
        bits(data_msb + 2) := '1';
        transfer_mdio(net, master, bits, sampled);
        check_equal(sampled(data_msb + 2), 'X', "both drive MDIO");
        check_only(phy, mdio_contention);

      elsif run("test_short_preamble_is_reported_and_ignored") then
        transfer_mdio(
          net,
          master,
          mdio_frame(mdio_write_op, 5, 8, x"1111", preamble_bits => 31),
          sampled(0 to 62)
        );
        check_only(phy, mdio_preamble);
        get_mdio_phy_access_count(net, phy, count);
        check_equal(count, 0, "frames PHY 5 answered");

      elsif run("test_suppressed_preamble_is_accepted") then
        transfer_mdio(
          net,
          master,
          mdio_frame(mdio_write_op, 12, 8, x"2222", preamble_bits => 0),
          sampled(0 to 31)
        );
        check_mdio_phy_register(net, no_preamble_phy, 8, x"2222", "written without a preamble");
        read_mdio(net, master, 12, 8, data);
        check_equal(data, std_ulogic_vector'(x"2222"), "read with a preamble");

      elsif run("test_invalid_op_is_reported") then
        bits := mdio_frame(mdio_write_op, 5, 8, x"1111");
        bits(op to op + 1) := "11";
        transfer_mdio(net, master, bits, sampled);
        check_only(phy, mdio_op);

      elsif run("test_metavalue_is_reported") then
        bits := mdio_frame(mdio_write_op, 5, 8, x"1111");
        bits(data_msb + 5) := 'X';
        transfer_mdio(net, master, bits, sampled);
        check_only(phy, mdio_metavalue);

      elsif run("test_register_difference_is_reported") then
        check_mdio_phy_register(net, phy, 3, x"0001");
        check_only(phy, mdio_register);

      elsif run("test_clock_to_output_delay") then
        check_clock_to_output_delay(slow_phy, 300 ns);
        check_clock_to_output_delay(phy, 0 ns);
        set_mdio_phy_clock_to_output_delay(net, phy, 120 ns);
        check_clock_to_output_delay(phy, 120 ns);

      elsif run("test_master_sampling_before_the_delay_reads_shifted_data") then
        -- Data valid 300 ns after MDC rises misses a 200 ns MDC period: every
        -- bit arrives one period late, the TA 0 first
        set_mdio_phy_register(net, slow_phy, 1, x"4C3A");
        set_mdio_master_mdc_period(net, master, 200 ns);
        read_mdio(net, master, 9, 1, data);
        check_equal(data, std_ulogic_vector'(x"261D"), "0 & 0x4C3A(15 downto 1)");
        set_mdio_master_mdc_period(net, master, 400 ns);
        read_mdio(net, master, 9, 1, data);
        check_equal(data, std_ulogic_vector'(x"4C3A"), "at 400 ns");

      elsif run("test_reset_releases_mdio") then
        -- A read that stops in its data: the PHY drives MDIO
        set_mdio_phy_register(net, phy, 0, x"FFFF");
        transfer_mdio(
          net,
          master,
          mdio_frame(mdio_read_op, 5, 0)(0 to data_msb + 3),
          sampled(0 to data_msb + 3)
        );
        check_equal(mdio, '1', "the PHY drives MDIO");
        start := now;
        reset(net, phy);
        check_equal(now, start, "reset returns at once");
        check_equal(mdio, 'H', "the PHY released MDIO");
        read_mdio(net, master, 5, 0, data);
        check_equal(data, std_ulogic_vector'(x"FFFF"), "a read after the reset");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 50 ms);

end architecture;
