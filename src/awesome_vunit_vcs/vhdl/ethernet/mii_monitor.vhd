-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive MII monitor: samples one direction of an MII interface on the rising
-- edge of its clock and never drives it. Nibble pairing, frame
-- reconstruction, protocol checks, statistics and capture happen in the
-- Python backend (awesome_vunit_vcs/ethernet/phy/mii.py). CRS and COL of half
-- duplex operation are not monitored.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_pkg.all;
use work.ethernet_vc_pkg.all;

entity mii_monitor is
  generic (
    monitor : ethernet_monitor_t
  );
  port (
    -- TX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : in std_ulogic_vector(3 downto 0);
    -- TX_EN or RX_DV
    dv : in std_ulogic;
    -- TX_ER or RX_ER
    er : in std_ulogic := '0'
  );
end entity;

architecture a of mii_monitor is
begin
  main : process
  begin
    assert monitor.p_phy = mii
      report "mii_monitor needs a monitor created by new_mii_monitor" severity failure;
    monitor_symbol_interface(net, monitor, clk, data, dv, er);
  end process;
end architecture;
