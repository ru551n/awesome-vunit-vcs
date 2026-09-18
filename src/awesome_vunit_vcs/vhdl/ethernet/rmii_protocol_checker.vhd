-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive RMII protocol checker: samples one direction of an RMII interface
-- on the rising edge of its reference clock and never drives it. The protocol checks happen in the
-- Python backend; violations are check failures on the checker of the handle.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.rmii_pkg.all;

entity rmii_protocol_checker is
  generic (
    protocol_checker : rmii_protocol_checker_t);
  port (
    -- REF_CLK, 50 MHz
    ref_clk : in  std_ulogic;
    -- TXD or RXD
    data : in  std_ulogic_vector(data_length(protocol_checker) - 1 downto 0);
    -- TX_EN or CRS_DV
    dv : in  std_ulogic;
    -- RX_ER; RMII has no TX_ER
    er : in  std_ulogic := '0'
  );
end entity;

architecture a of rmii_protocol_checker is

begin

  main : process
  begin

    monitor_symbol_interface(net, to_ethernet_vc(protocol_checker), ref_clk, data, dv, er);
  end process;

end architecture;
