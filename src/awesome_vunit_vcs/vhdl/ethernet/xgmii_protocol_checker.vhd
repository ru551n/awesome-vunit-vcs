-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive XGMII protocol checker: samples one direction of a XGMII interface
-- on the rising edge of its clock, or on both edges and never drives it. The protocol checks happen in the
-- Python backend; violations are check failures on the checker of the handle.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_vc_pkg.all;
use work.xgmii_pkg.all;

entity xgmii_protocol_checker is
  generic (
    protocol_checker : xgmii_protocol_checker_t
  );
  port (
    -- TX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD, lane 0 in the low octet
    data : in std_ulogic_vector(data_length(protocol_checker) - 1 downto 0);
    -- TXC or RXC, lane 0 in the low bit
    ctrl : in std_ulogic_vector(ctrl_length(protocol_checker) - 1 downto 0)
  );
end entity;

architecture a of xgmii_protocol_checker is
begin
  main : process
  begin
    monitor_column_interface(net, to_ethernet_vc(protocol_checker), clk, data, ctrl);
  end process;
end architecture;
