-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Properties: every frame a source sends, the monitor receives unchanged, on GMII
-- and on an AXI-Stream MAC client bus with backpressure drawn by Hypothesis.

-- docs-start: context
library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;
-- docs-end: context

entity tb_property_ethernet is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_property_ethernet is
  signal clk : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0);
  signal dv, er : std_ulogic;

  constant source : gmii_source_t := new_gmii_source;
  constant monitor : gmii_monitor_t := new_gmii_monitor;

  constant axis_source : axis_mac_source_t := new_axis_mac_source;
  constant axis_sink : axis_mac_sink_t := new_axis_mac_sink;
  constant axis_monitor : axis_mac_monitor_t := new_axis_mac_monitor;
  signal tdata : std_ulogic_vector(data_length(axis_source) - 1 downto 0);
  signal tkeep : std_ulogic_vector(keep_length(axis_source) - 1 downto 0);
  signal tvalid, tready, tlast : std_ulogic;
  signal tuser : std_ulogic_vector(user_length(axis_source) - 1 downto 0);
begin
  clk <= not clk after 4 ns;

  main : process
    -- docs-start: frame-variables
    variable prop : property_t;
    -- Room for the longest frame the strategy draws
    variable received : std_ulogic_vector(0 to 8 * 128 - 1);
    variable length : natural;
    -- docs-end: frame-variables
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_gmii_frames") then
        -- docs-start: ethernet
        prop := new_property("strategies:frame_data", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          push_ethernet_frame(net, source, get_unsigned(prop, "", 8 * get_length(prop)));
          pop_ethernet_frame(net, monitor, received, length);
          report_example(prop, passed => length = get_length(prop) and
            received(0 to 8 * length - 1) = get_unsigned(prop, "", 8 * get_length(prop)));
        end loop;
        check_property(prop);
        -- docs-end: ethernet

      elsif run("test_axis_backpressure") then
        -- docs-start: axis-backpressure
        prop := new_property("strategies:backpressure", seed => get_seed(runner_cfg),
          search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          set_ready_pattern(net, axis_sink, get_integer(prop, "ready_high_percent"), get_integer(prop, "seed"));
          push_ethernet_frame(net, axis_source, get_unsigned(prop, "frame", 8 * get_length(prop, "frame")));
          pop_ethernet_frame(net, axis_monitor, received, length);
          report_example(prop, passed => length = get_length(prop, "frame") and
            received(0 to 8 * length - 1) = get_unsigned(prop, "frame", 8 * get_length(prop, "frame")));
        end loop;
        check_property(prop);
        -- docs-end: axis-backpressure
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  source_inst : entity awesome_vunit_vcs.gmii_source
    generic map (source => source)
    port map (clk => clk, data => data, dv => dv, er => er);

  monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (monitor => monitor)
    port map (clk => clk, data => data, dv => dv, er => er);

  axis_source_inst : entity awesome_vunit_vcs.axis_mac_source
    generic map (source => axis_source)
    port map (clk => clk, tdata => tdata, tkeep => tkeep, tvalid => tvalid, tready => tready, tlast => tlast, tuser => tuser);

  axis_sink_inst : entity awesome_vunit_vcs.axis_mac_sink
    generic map (sink => axis_sink)
    port map (clk => clk, tready => tready);

  axis_monitor_inst : entity awesome_vunit_vcs.axis_mac_monitor
    generic map (monitor => axis_monitor)
    port map (clk => clk, tdata => tdata, tkeep => tkeep, tvalid => tvalid, tready => tready, tlast => tlast, tuser => tuser);
end architecture;
