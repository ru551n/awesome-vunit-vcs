-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive MII monitor: samples one direction of a MII interface
-- on the rising edge of its clock and never drives it. Frame reconstruction, statistics,
-- scoreboard and capture happen in the Python backend. With a protocol checker
-- in its handle, the monitor instantiates a mii_protocol_checker on the same
-- pins, as axi_stream_monitor of VUnit does.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_vc_pkg.all;
use work.mii_pkg.all;

entity mii_monitor is
  generic (
    monitor : mii_monitor_t
  );
  port (
    -- TX_CLK or RX_CLK
    clk : in std_ulogic;
    -- TXD or RXD
    data : in std_ulogic_vector(data_length(monitor) - 1 downto 0);
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
    monitor_symbol_interface(net, to_ethernet_vc(monitor), clk, data, dv, er);
  end process;

  protocol_checker_gen : if get_protocol_checker(monitor) /= null_mii_protocol_checker generate
    protocol_checker_inst : entity work.mii_protocol_checker
      generic map (
        protocol_checker => get_protocol_checker(monitor)
      )
      port map (
        clk => clk,
        data => data,
        dv => dv,
        er => er
      );
  end generate;
end architecture;
