-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

-- docs-start: testbench
library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_quickstart is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_quickstart is

  signal clk : std_ulogic := '0';
  signal in_data, out_data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal in_dv : std_ulogic := '0';
  signal in_er : std_ulogic := '0';
  signal out_dv : std_ulogic := '0';
  signal out_er : std_ulogic := '0';

  constant source : gmii_source_t := new_gmii_source;
  constant monitor : gmii_monitor_t := new_gmii_monitor(protocol_checker => default_gmii_protocol_checker);

begin

  clk <= not clk after 4 ns;

  main : process

    constant header : std_ulogic_vector := x"020000000001" & x"020000000002" & x"88B5";
    variable statistics : ethernet_statistics_t;

  begin

    test_runner_setup(runner, runner_cfg);
    start_capture(net, monitor, output_path(runner_cfg) & "quickstart.pcapng");

    for idx in 1 to 10 loop

      check_ethernet_frame(net, monitor, header & (1 to 8 * 10 * idx => '1'), blocking => false);
      push_ethernet_frame(net, source, header & (1 to 8 * 10 * idx => '1'));
    end loop;

    wait_until_idle(net, as_sync(source));
    wait_until_idle(net, as_sync(monitor));
    get_statistics(net, monitor, statistics);
    check_equal(statistics.good_frames, 10);
    log_statistics(net, monitor);
    test_runner_cleanup(runner);
  end process;

  source_inst : entity awesome_vunit_vcs.gmii_source
    generic map (
      source => source
    )
    port map (
      clk => clk,
      data => in_data,
      dv => in_dv,
      er => in_er
    );

  -- The design under test: one register stage
  out_data <= in_data when rising_edge(clk);
  out_dv <= in_dv when rising_edge(clk);
  out_er <= in_er when rising_edge(clk);

  monitor_inst : entity awesome_vunit_vcs.gmii_monitor
    generic map (
      monitor => monitor
    )
    port map (
      clk => clk,
      data => out_data,
      dv => out_dv,
      er => out_er
    );

end architecture;
-- docs-end: testbench
