-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

-- The same frame over MII, RGMII, RMII, XGMII and an AXI-Stream MAC client bus,
-- each source connected straight to a monitor (and a sink on AXI-Stream). run.py
-- runs every interface at two of its rates.
entity tb_cookbook_interfaces is
  generic (
    runner_cfg : string;
    mii_link_rate_mbps : positive := 100;
    rgmii_link_rate_mbps : positive := 1000;
    rmii_link_rate_mbps : positive := 100;
    xgmii_lanes : positive := 4;
    xgmii_link_rate_mbps : positive := 10_000);
end entity;

architecture tb of tb_cookbook_interfaces is

  constant frame : std_ulogic_vector := x"020000000001" & x"020000000002" & x"88B5" & (0 to 8 * 46 - 1 => '1');

  -- docs-start: mii-handles
  -- MII: 2.5 MHz at 10 Mbit/s, 25 MHz at 100 Mbit/s
  constant mii_source : mii_source_t := new_mii_source(link_rate_mbps => mii_link_rate_mbps);
  constant mii_monitor : mii_monitor_t :=
    new_mii_monitor(link_rate_mbps => mii_link_rate_mbps, protocol_checker => default_mii_protocol_checker);
  signal mii_clk : std_ulogic := '0';
  signal mii_data : std_ulogic_vector(3 downto 0) := (others => '0');
  signal mii_dv, mii_er : std_ulogic := '0';
  -- docs-end: mii-handles

  -- docs-start: rgmii-handles
  -- RGMII: both clock edges; 125 MHz at 1000 Mbit/s, 25 MHz at 100, 2.5 MHz at 10
  constant rgmii_source : rgmii_source_t := new_rgmii_source(link_rate_mbps => rgmii_link_rate_mbps);
  constant rgmii_monitor : rgmii_monitor_t :=
    new_rgmii_monitor(link_rate_mbps => rgmii_link_rate_mbps, protocol_checker => default_rgmii_protocol_checker);
  signal rgmii_clk : std_ulogic := '0';
  signal rgmii_data : std_ulogic_vector(3 downto 0) := (others => '0');
  signal rgmii_ctl : std_ulogic := '0';
  -- docs-end: rgmii-handles

  -- docs-start: rmii-handles
  -- RMII: a 50 MHz reference clock at both 10 and 100 Mbit/s
  constant rmii_source : rmii_source_t := new_rmii_source(link_rate_mbps => rmii_link_rate_mbps);
  constant rmii_monitor : rmii_monitor_t :=
    new_rmii_monitor(link_rate_mbps => rmii_link_rate_mbps, protocol_checker => default_rmii_protocol_checker);
  signal rmii_ref_clk : std_ulogic := '0';
  signal rmii_data : std_ulogic_vector(1 downto 0) := (others => '0');
  signal rmii_dv, rmii_er : std_ulogic := '0';
  -- docs-end: rmii-handles

  -- docs-start: xgmii-handles
  -- XGMII family: 4 lanes (XGMII) or 8 lanes (25GMII up to 400GMII); one column per rising edge
  constant xgmii_source : xgmii_source_t :=
    new_xgmii_source(lanes => xgmii_lanes, link_rate_mbps => xgmii_link_rate_mbps);
  constant xgmii_monitor : xgmii_monitor_t := new_xgmii_monitor(
    lanes => xgmii_lanes,
    link_rate_mbps => xgmii_link_rate_mbps,
    protocol_checker => default_xgmii_protocol_checker
  );
  constant xgmii_clk_period : time := xgmii_lanes * (8 us / xgmii_link_rate_mbps);
  signal xgmii_clk : std_ulogic := '0';
  signal xgmii_data : std_ulogic_vector(data_length(xgmii_source) - 1 downto 0);
  signal xgmii_ctrl : std_ulogic_vector(ctrl_length(xgmii_source) - 1 downto 0);
  -- docs-end: xgmii-handles

  -- docs-start: axis-mac-handles
  -- AXI-Stream MAC client: frames without preamble, a sink with tready high on 60 % of the clocks
  constant axis_source : axis_mac_source_t := new_axis_mac_source(bytes_per_beat => 8);
  constant axis_sink : axis_mac_sink_t := new_axis_mac_sink(ready_high_percent => 60);
  constant axis_monitor : axis_mac_monitor_t :=
    new_axis_mac_monitor(bytes_per_beat => 8, protocol_checker => default_axis_mac_protocol_checker);
  signal axis_clk : std_ulogic := '0';
  signal tdata : std_ulogic_vector(data_length(axis_source) - 1 downto 0);
  signal tkeep : std_ulogic_vector(keep_length(axis_source) - 1 downto 0);
  signal tvalid : std_ulogic;
  signal tready : std_ulogic;
  signal tlast : std_ulogic;
  signal tuser : std_ulogic_vector(user_length(axis_source) - 1 downto 0);

-- docs-end: axis-mac-handles
begin

  mii_clk <= not mii_clk after (4000 ns / mii_link_rate_mbps) / 2;
  rgmii_clk <= not rgmii_clk after 4 ns when rgmii_link_rate_mbps = 1000 else
               not rgmii_clk after (4000 ns / rgmii_link_rate_mbps) / 2;
  rmii_ref_clk <= not rmii_ref_clk after 10 ns;
  xgmii_clk <= not xgmii_clk after xgmii_clk_period / 2;
  axis_clk <= not axis_clk after 3200 ps;

  main : process
  begin

    test_runner_setup(runner, runner_cfg);
    while test_suite loop

      if run("test_mii") then
        -- docs-start: mii-test
        check_ethernet_frame(net, mii_monitor, frame, blocking => false);
        push_ethernet_frame(net, mii_source, frame);
        wait_until_idle(net, as_sync(mii_source));
        wait_until_idle(net, as_sync(mii_monitor));
      -- docs-end: mii-test

      elsif run("test_rgmii") then
        check_ethernet_frame(net, rgmii_monitor, frame, blocking => false);
        push_ethernet_frame(net, rgmii_source, frame);
        wait_until_idle(net, as_sync(rgmii_source));
        wait_until_idle(net, as_sync(rgmii_monitor));

      elsif run("test_rmii") then
        check_ethernet_frame(net, rmii_monitor, frame, blocking => false);
        push_ethernet_frame(net, rmii_source, frame);
        wait_until_idle(net, as_sync(rmii_source));
        wait_until_idle(net, as_sync(rmii_monitor));

      elsif run("test_xgmii") then
        check_ethernet_frame(net, xgmii_monitor, frame, blocking => false);
        push_ethernet_frame(net, xgmii_source, frame);
        wait_until_idle(net, as_sync(xgmii_source));
        wait_until_idle(net, as_sync(xgmii_monitor));

      elsif run("test_axis_mac") then
        check_ethernet_frame(net, axis_monitor, frame, blocking => false);
        push_ethernet_frame(net, axis_source, frame);
        wait_until_idle(net, as_sync(axis_source));
        wait_until_idle(net, as_sync(axis_monitor));
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 100 ms);

  -- docs-start: mii-instances
  mii_source_inst : entity awesome_vunit_vcs.mii_source
    generic map (
      source => mii_source
    )
    port map (
      clk => mii_clk,
      data => mii_data,
      dv => mii_dv,
      er => mii_er
    );

  mii_monitor_inst : entity awesome_vunit_vcs.mii_monitor
    generic map (
      monitor => mii_monitor
    )
    port map (
      clk => mii_clk,
      data => mii_data,
      dv => mii_dv,
      er => mii_er
    );

  -- docs-end: mii-instances

  -- docs-start: rgmii-instances
  rgmii_source_inst : entity awesome_vunit_vcs.rgmii_source
    generic map (
      source => rgmii_source
    )
    port map (
      clk => rgmii_clk,
      data => rgmii_data,
      ctl => rgmii_ctl
    );

  rgmii_monitor_inst : entity awesome_vunit_vcs.rgmii_monitor
    generic map (
      monitor => rgmii_monitor
    )
    port map (
      clk => rgmii_clk,
      data => rgmii_data,
      ctl => rgmii_ctl
    );

  -- docs-end: rgmii-instances

  -- docs-start: rmii-instances
  rmii_source_inst : entity awesome_vunit_vcs.rmii_source
    generic map (
      source => rmii_source
    )
    port map (
      ref_clk => rmii_ref_clk,
      data => rmii_data,
      dv => rmii_dv,
      er => rmii_er
    );

  rmii_monitor_inst : entity awesome_vunit_vcs.rmii_monitor
    generic map (
      monitor => rmii_monitor
    )
    port map (
      ref_clk => rmii_ref_clk,
      data => rmii_data,
      dv => rmii_dv,
      er => rmii_er
    );

  -- docs-end: rmii-instances

  -- docs-start: xgmii-instances
  xgmii_source_inst : entity awesome_vunit_vcs.xgmii_source
    generic map (
      source => xgmii_source
    )
    port map (
      clk => xgmii_clk,
      data => xgmii_data,
      ctrl => xgmii_ctrl
    );

  xgmii_monitor_inst : entity awesome_vunit_vcs.xgmii_monitor
    generic map (
      monitor => xgmii_monitor
    )
    port map (
      clk => xgmii_clk,
      data => xgmii_data,
      ctrl => xgmii_ctrl
    );

  -- docs-end: xgmii-instances

  -- docs-start: axis-mac-instances
  axis_source_inst : entity awesome_vunit_vcs.axis_mac_source
    generic map (
      source => axis_source
    )
    port map (
      clk => axis_clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  axis_sink_inst : entity awesome_vunit_vcs.axis_mac_sink
    generic map (
      sink => axis_sink
    )
    port map (
      clk => axis_clk,
      tready => tready
    );

  axis_monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (
      monitor => axis_monitor
    )
    port map (
      clk => axis_clk,
      tdata => tdata,
      tkeep => tkeep,
      tvalid => tvalid,
      tready => tready,
      tlast => tlast,
      tuser => tuser
    );

  -- docs-end: axis-mac-instances
end architecture;
