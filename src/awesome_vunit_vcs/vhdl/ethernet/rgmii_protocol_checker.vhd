-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Passive RGMII protocol checker: samples one direction of an RGMII interface
-- on both edges of its clock and never drives it. The protocol checks happen in
-- the Python backend; violations are check failures on the checker of the
-- handle.

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.rgmii_pkg.all;

entity rgmii_protocol_checker is
  generic (
    protocol_checker : rgmii_protocol_checker_t);
  port (
    -- TXC or RXC
    clk : in  std_ulogic;
    -- TD or RD
    data : in  std_ulogic_vector(data_length(protocol_checker) - 1 downto 0);
    -- TX_CTL or RX_CTL
    ctl : in  std_ulogic
  );
end entity;

architecture a of rgmii_protocol_checker is

  -- The clock edge aligned data is sampled on, a quarter period late
  signal sample_clk : std_ulogic := '0';
  -- The symbols of both clock edges, changing on the falling sampling edges
  signal symbol_clk : std_ulogic := '0';
  signal octet : std_ulogic_vector(7 downto 0) := (others => '0');
  signal dv, er : std_ulogic := '0';

begin

  -- Without a delay the line is sampled on clk itself: a copy of clk would
  -- change a delta cycle later and see data that changed on the clock edge
  combine_gen : if get_sample_delay(protocol_checker) = 0 ns generate
    symbol_clk <= not clk;

    combine : process
    begin

      combine_double_edges(to_ethernet_vc(protocol_checker), clk, data, ctl, octet, dv, er);
    end process;

  else generate
    sample_clk <= transport clk after get_sample_delay(protocol_checker);
    symbol_clk <= not sample_clk;

    combine : process
    begin

      combine_double_edges(to_ethernet_vc(protocol_checker), sample_clk, data, ctl, octet, dv, er);
    end process;

  end generate combine_gen;

  main : process
  begin

    monitor_symbol_interface(net, to_ethernet_vc(protocol_checker), symbol_clk, octet, dv, er);
  end process;

end architecture;
