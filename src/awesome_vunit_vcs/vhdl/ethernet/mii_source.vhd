-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active MII source: drives one direction of a MII interface. Python decides
-- what is transmitted and returns the sample words; this entity decides when
-- the pins change, which is on the rising edge of its clock.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.mii_pkg.all;

entity mii_source is
  generic (
    source : mii_source_t);
  port (
    -- TX_CLK or RX_CLK
    clk : in  std_ulogic;
    -- TXD or RXD
    data : out std_ulogic_vector(data_length(source) - 1 downto 0) := (others => '0');
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

    drive_symbol_interface(net, to_ethernet_vc(source), clk, data, dv, er);
  end process;

end architecture;
