-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active GMII source: drives one direction of a GMII interface. Python decides
-- what is transmitted (preamble, SFD, padding, FCS, errors, IFG) and returns
-- one sample word per clock cycle; this entity decides when the pins change,
-- which is on the rising edge of the clock, see drive_symbol_interface in
-- ethernet_vc_pkg.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_pkg.all;
use work.ethernet_vc_pkg.all;

entity gmii_source is
  generic (
    source : ethernet_source_t
  );
  port (
    -- GTX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : out std_ulogic_vector(7 downto 0) := (others => '0');
    -- TX_EN or RX_DV
    dv : out std_ulogic := '0';
    -- TX_ER or RX_ER
    er : out std_ulogic := '0'
  );
end entity;

architecture a of gmii_source is
begin
  main : process
  begin
    assert source.p_phy = gmii
      report "gmii_source needs a source created by new_gmii_source" severity failure;
    drive_symbol_interface(net, source, clk, data, dv, er);
  end process;
end architecture;
