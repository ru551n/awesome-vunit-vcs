-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Property: every frame the GMII source sends, the GMII monitor receives unchanged.

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;
use awesome_vunit_vcs.property_pkg.all;

entity tb_property_ethernet is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_property_ethernet is
  signal clk : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0);
  signal dv, er : std_ulogic;

  constant source : gmii_source_t := new_gmii_source;
  constant monitor : gmii_monitor_t := new_gmii_monitor;
begin
  clk <= not clk after 4 ns;

  main : process
    variable prop : property_t;
    variable received : std_ulogic_vector(0 to 8 * 128 - 1);
    variable length : natural;
  begin
    test_runner_setup(runner, runner_cfg);
    -- docs-start: ethernet
    prop := new_property("strategies:frame_data", seed => get_seed(runner_cfg),
      search_path => tb_path(runner_cfg) & "python");
    while next_example(prop) loop
      push_ethernet_frame(net, source, get_unsigned(prop, "", 8 * get_length(prop)));
      pop_ethernet_frame(net, monitor, received, length);
      report_example(prop, passed => length = get_length(prop) and
        received(0 to 8 * length - 1) = get_unsigned(prop, "", 8 * get_length(prop)));
    end loop;
    check_property(prop);
    -- docs-end: ethernet
    test_runner_cleanup(runner);
  end process;

  source_inst : entity awesome_vunit_vcs.gmii_source
    generic map (source => source)
    port map (clk => clk, data => data, dv => dv, er => er);

  monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (monitor => monitor)
    port map (clk => clk, data => data, dv => dv, er => er);
end architecture;
