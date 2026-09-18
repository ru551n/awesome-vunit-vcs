-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Active RMII source: drives one direction of an RMII interface. Python decides
-- what is transmitted and returns the sample words; this entity decides when
-- the pins change, which is on the rising edge of its reference clock.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.rmii_pkg.all;

entity rmii_source is
  generic (
    source : rmii_source_t);
  port (
    -- REF_CLK, 50 MHz
    ref_clk : in  std_ulogic;
    -- TXD or RXD
    data : out std_ulogic_vector(data_length(source) - 1 downto 0) := (others => '0');
    -- TX_EN or CRS_DV
    dv : out std_ulogic := '0';
    -- RX_ER; RMII has no TX_ER
    er : out std_ulogic := '0'
  );
end entity;

architecture a of rmii_source is

begin

  main : process
  begin

    drive_symbol_interface(net, to_ethernet_vc(source), ref_clk, data, dv, er);
  end process;

end architecture;
