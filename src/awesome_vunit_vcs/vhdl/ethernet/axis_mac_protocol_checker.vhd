-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- An AXI-Stream MAC client protocol checker: checks the frames of the
-- AXI-Stream packets it observes and the AXI-Stream rules a MAC client relies
-- on (tkeep, stability while waiting for tready, tvalid until the handshake).

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

  use work.ethernet_vc_pkg.all;
  use work.axis_mac_pkg.all;

entity axis_mac_protocol_checker is
  generic (
    protocol_checker : axis_mac_protocol_checker_t);
  port (
    clk : in  std_ulogic;
    tdata : in  std_ulogic_vector(data_length(protocol_checker) - 1 downto 0);
    tkeep : in  std_ulogic_vector(keep_length(protocol_checker) - 1 downto 0) := (others => '1');
    tvalid : in  std_ulogic;
    tready : in  std_ulogic := '1';
    tlast : in  std_ulogic;
    tuser : in  std_ulogic_vector(user_length(protocol_checker) - 1 downto 0) := (others => '0')
  );
end entity;

architecture a of axis_mac_protocol_checker is

begin

  main : process
  begin

    monitor_axis_interface(net, to_ethernet_vc(protocol_checker), clk, tdata, tkeep, tvalid, tready, tlast, tuser);
  end process;

end architecture;
