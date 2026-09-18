-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active XGMII source: drives one direction of a XGMII interface. Python decides
-- what is transmitted and returns the sample words; this entity decides when
-- the pins change, which is on the rising edge of its clock, or on both edges.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.xgmii_pkg.all;

entity xgmii_source is
  generic (
    source : xgmii_source_t);
  port (
    -- TX_CLK or RX_CLK
    clk : in  std_ulogic;
    -- TXD or RXD, lane 0 in the low octet
    data : out std_ulogic_vector(data_length(source) - 1 downto 0) := (others => '0');
    -- TXC or RXC, lane 0 in the low bit
    ctrl : out std_ulogic_vector(ctrl_length(source) - 1 downto 0) := (others => '1')
  );
end entity;

architecture a of xgmii_source is

begin

  main : process
  begin

    drive_column_interface(net, to_ethernet_vc(source), clk, data, ctrl);
  end process;

end architecture;
