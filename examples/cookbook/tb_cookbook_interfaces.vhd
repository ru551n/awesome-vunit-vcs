-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

-- The same frame over MII and XGMII, each source connected straight to a
-- monitor. run.py runs it at 10M/10G and at 100M/400G.
entity tb_cookbook_interfaces is
  generic (
    runner_cfg : string;
    mii_link_rate_mbps : positive := 100;
    xgmii_lanes : positive := 4;
    xgmii_link_rate_mbps : positive := 10_000
  );
end entity;

architecture tb of tb_cookbook_interfaces is
  constant frame : std_ulogic_vector := x"020000000001" & x"020000000002" & x"88B5" & (0 to 8 * 46 - 1 => '1');

  -- docs-start: mii
  -- MII: 2.5 MHz at 10 Mbit/s, 25 MHz at 100 Mbit/s
  constant mii_source : mii_source_t := new_mii_source(link_rate_mbps => mii_link_rate_mbps);
  constant mii_monitor : mii_monitor_t := new_mii_monitor(
    link_rate_mbps => mii_link_rate_mbps, protocol_checker => default_mii_protocol_checker
  );
  signal mii_clk : std_ulogic := '0';
  signal mii_data : std_ulogic_vector(3 downto 0) := (others => '0');
  signal mii_dv, mii_er : std_ulogic := '0';
  -- docs-end: mii

  -- docs-start: xgmii
  -- XGMII family: 4 lanes (XGMII) or 8 lanes (25GMII up to 400GMII); one column per rising edge
  constant xgmii_source : xgmii_source_t := new_xgmii_source(lanes => xgmii_lanes, link_rate_mbps => xgmii_link_rate_mbps);
  constant xgmii_monitor : xgmii_monitor_t := new_xgmii_monitor(
    lanes => xgmii_lanes, link_rate_mbps => xgmii_link_rate_mbps, protocol_checker => default_xgmii_protocol_checker
  );
  constant xgmii_clk_period : time := xgmii_lanes * (8 us / xgmii_link_rate_mbps);
  signal xgmii_clk : std_ulogic := '0';
  signal xgmii_data : std_ulogic_vector(data_length(xgmii_source) - 1 downto 0);
  signal xgmii_ctrl : std_ulogic_vector(ctrl_length(xgmii_source) - 1 downto 0);
  -- docs-end: xgmii
begin
  mii_clk <= not mii_clk after (4000 ns / mii_link_rate_mbps) / 2;
  xgmii_clk <= not xgmii_clk after xgmii_clk_period / 2;

  main : process
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_mii") then
        check_ethernet_frame(net, mii_monitor, frame, blocking => false);
        push_ethernet_frame(net, mii_source, frame);
        wait_until_idle(net, as_sync(mii_source));
        wait_until_idle(net, as_sync(mii_monitor));

      elsif run("test_xgmii") then
        check_ethernet_frame(net, xgmii_monitor, frame, blocking => false);
        push_ethernet_frame(net, xgmii_source, frame);
        wait_until_idle(net, as_sync(xgmii_source));
        wait_until_idle(net, as_sync(xgmii_monitor));
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 100 ms);

  -- docs-start: mii-instances
  mii_source_inst : entity awesome_vunit_vcs.mii_source
    generic map (mii_source)
    port map (mii_clk, mii_data, mii_dv, mii_er);

  mii_monitor_inst : entity awesome_vunit_vcs.mii_monitor
    generic map (mii_monitor)
    port map (mii_clk, mii_data, mii_dv, mii_er);
  -- docs-end: mii-instances

  -- docs-start: xgmii-instances
  xgmii_source_inst : entity awesome_vunit_vcs.xgmii_source
    generic map (xgmii_source)
    port map (xgmii_clk, xgmii_data, xgmii_ctrl);

  xgmii_monitor_inst : entity awesome_vunit_vcs.xgmii_monitor
    generic map (xgmii_monitor)
    port map (xgmii_clk, xgmii_data, xgmii_ctrl);
  -- docs-end: xgmii-instances
end architecture;
