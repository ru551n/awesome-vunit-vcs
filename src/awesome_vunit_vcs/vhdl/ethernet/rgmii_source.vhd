-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active RGMII source: drives one direction of an RGMII interface. Python
-- decides what is transmitted and returns the symbols; this entity decides when
-- the pins change, on both edges of its clock.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.rgmii_pkg.all;

entity rgmii_source is
  generic (
    source : rgmii_source_t);
  port (
    -- TXC or RXC
    clk : in  std_ulogic;
    -- TD or RD
    data : out std_ulogic_vector(data_length(source) - 1 downto 0) := (others => '0');
    -- TX_CTL or RX_CTL
    ctl : out std_ulogic := '0'
  );
end entity;

architecture a of rgmii_source is

  -- The symbol of a clock cycle, changing on the rising edges of clk
  signal octet : std_ulogic_vector(7 downto 0) := (others => '0');
  signal dv, er : std_ulogic := '0';

begin

  main : process
  begin

    drive_symbol_interface(net, to_ethernet_vc(source), clk, octet, dv, er);
  end process;

  split : process
  begin

    split_double_edges(to_ethernet_vc(source), clk, octet, dv, er, data, ctl);
  end process;

end architecture;
