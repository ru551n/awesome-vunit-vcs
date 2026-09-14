-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive GMII monitor: samples one direction of a GMII interface on the
-- rising edge of its clock and never drives it. Frame reconstruction,
-- protocol checks, statistics and capture happen in the Python backend. The
-- sampling is that of every one-symbol-per-cycle interface, see
-- monitor_symbol_interface in ethernet_vc_pkg.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_pkg.all;
use work.ethernet_vc_pkg.all;

entity gmii_monitor is
  generic (
    monitor : ethernet_monitor_t
  );
  port (
    -- GTX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : in std_ulogic_vector(7 downto 0);
    -- TX_EN or RX_DV
    dv : in std_ulogic;
    -- TX_ER or RX_ER
    er : in std_ulogic := '0'
  );
end entity;

architecture a of gmii_monitor is
begin
  main : process
  begin
    assert monitor.p_phy = gmii
      report "gmii_monitor needs a monitor created by new_gmii_monitor" severity failure;
    monitor_symbol_interface(net, monitor, clk, data, dv, er);
  end process;
end architecture;
