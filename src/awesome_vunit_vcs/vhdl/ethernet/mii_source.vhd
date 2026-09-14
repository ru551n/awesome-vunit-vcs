-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active MII source: drives one direction of an MII interface. Python decides
-- what is transmitted (preamble, SFD, padding, FCS, errors, IFG) and returns
-- one nibble word per clock cycle, least significant nibble of each octet
-- first; this entity decides when the pins change, which is on the rising
-- edge of the clock. CRS and COL of half duplex operation are not driven.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_pkg.all;
use work.ethernet_vc_pkg.all;

entity mii_source is
  generic (
    source : ethernet_source_t
  );
  port (
    -- TX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : out std_ulogic_vector(3 downto 0) := (others => '0');
    -- TX_EN or RX_DV
    dv : out std_ulogic := '0';
    -- TX_ER or RX_ER
    er : out std_ulogic := '0'
  );
end entity;

architecture a of mii_source is
begin
  main : process
  begin
    assert source.p_phy = mii
      report "mii_source needs a source created by new_mii_source" severity failure;
    drive_symbol_interface(net, source, clk, data, dv, er);
  end process;
end architecture;
