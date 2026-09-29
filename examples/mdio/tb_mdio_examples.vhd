-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The MDIO examples of the documentation. A master manages two PHYs on one
-- bus: a register file, and a PHY modelled in Python (python/link_phy.py) that
-- answers at the slowest clock-to-output delay the standard allows. In a real
-- test your design takes the place of the master.

-- docs-start: context
library awesome_vunit_vcs;
context awesome_vunit_vcs.mdio_context;

-- docs-end: context

entity tb_mdio_examples is
  generic (
    runner_cfg : string
  );
end entity;

architecture tb of tb_mdio_examples is

  -- docs-start: handles
  constant master : mdio_master_t := new_mdio_master(mdc_period => 400 ns);
  constant phy : mdio_phy_t := new_mdio_phy(phy_address => 1);
  constant link_phy : mdio_phy_t := new_mdio_phy(
    phy_address => 7,
    clock_to_output_delay => mdio_max_clock_to_output_delay,
    model => "link_phy:LinkPhy",
    model_args => kwarg_time("link_up_fs", 100 us)
  );
  -- docs-end: handles

  -- docs-start: bus
  signal mdc : std_ulogic;
  signal mdio : std_logic := 'H';

-- docs-end: bus

begin

  -- docs-start: instances
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

  link_phy_inst : entity awesome_vunit_vcs.mdio_phy
    generic map (
      phy => link_phy
    )
    port map (
      mdc => mdc,
      mdio => mdio
    );

  -- docs-end: instances

  main : process

    variable data : std_ulogic_vector(15 downto 0);
    variable count : natural;
    variable bits : std_ulogic_vector(0 to 63);
    variable sampled : std_ulogic_vector(0 to 63);

  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_read_and_write_registers") then
        -- docs-start: read-write
        set_mdio_phy_register(net, phy, 2, x"0141");
        read_mdio(net, master, 1, 2, data);
        check_equal(data, std_ulogic_vector'(x"0141"), "PHY ID 1");

        write_mdio(net, master, 1, 4, x"01E1");
        wait_until_idle(net, as_sync(master));
        check_mdio_phy_register(net, phy, 4, x"01E1", "the advertisement");
        get_mdio_phy_access_count(net, phy, mdio_write_op, count);
        check_equal(count, 1, "writes to the PHY");
      -- docs-end: read-write

      elsif run("test_device_model_in_python") then
        -- docs-start: link-up
        read_mdio(net, master, 7, 1, data);
        check_equal(data(2), '0', "the link is down after reset");
        wait for 100 us;
        read_mdio(net, master, 7, 1, data);
        check_equal(data(2), '1', "the link is up");

        write_mdio(net, master, 7, 0, x"9140");
        read_mdio(net, master, 7, 0, data);
        check_equal(data, std_ulogic_vector'(x"1140"), "the reset bit clears itself");
      -- docs-end: link-up

      elsif run("test_malformed_frame") then
        -- docs-start: malformed
        disable_stop(get_logger(phy), error);
        bits := mdio_frame(mdio_write_op, 1, 4, x"FFFF");
        -- The TA of a write is 10
        bits(46 to 47) := "11";
        transfer_mdio(net, master, bits, sampled);
        get_mdio_phy_check_count(net, phy, mdio_ta, count);
        check_equal(count, 1, "MDIO_TA violations");
        check_mdio_phy_register(net, phy, 4, x"0000", "a write with a bad TA is not made");
        check_equal(get_log_count(get_logger(phy), error), 1, "violations are check failures");
        reset_log_count(get_logger(phy), error);
      -- docs-end: malformed
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 ms);

end architecture;
