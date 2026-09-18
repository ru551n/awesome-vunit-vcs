-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive XGMII monitor: samples one direction of a XGMII interface
-- on the rising edge of its clock, or on both edges and never drives it. Frame reconstruction, statistics,
-- scoreboard and capture happen in the Python backend. With a protocol checker
-- in its handle, the monitor instantiates a xgmii_protocol_checker on the same
-- pins, as axi_stream_monitor of VUnit does.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.xgmii_pkg.all;

entity xgmii_monitor is
  generic (
    monitor : xgmii_monitor_t);
  port (
    -- TX_CLK or RX_CLK
    clk : in  std_ulogic;
    -- TXD or RXD, lane 0 in the low octet
    data : in  std_ulogic_vector(data_length(monitor) - 1 downto 0);
    -- TXC or RXC, lane 0 in the low bit
    ctrl : in  std_ulogic_vector(ctrl_length(monitor) - 1 downto 0)
  );
end entity;

architecture a of xgmii_monitor is

begin

  main : process
  begin

    monitor_column_interface(net, to_ethernet_vc(monitor), clk, data, ctrl);
  end process;

  protocol_checker_gen : if get_protocol_checker(monitor) /= null_xgmii_protocol_checker generate
    protocol_checker_inst : entity work.xgmii_protocol_checker
      generic map (
        protocol_checker => get_protocol_checker(monitor)
      )
      port map (
        clk => clk,
        data => data,
        ctrl => ctrl
      );

  end generate protocol_checker_gen;

end architecture;
