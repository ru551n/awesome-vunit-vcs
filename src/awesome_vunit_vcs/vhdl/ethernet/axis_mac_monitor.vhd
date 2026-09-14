-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- An AXI-Stream MAC client monitor: reconstructs the frames of the AXI-Stream
-- packets it observes. It never drives the bus; with a protocol checker in its
-- handle it instantiates one on the same signals.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_vc_pkg.all;
use work.axis_mac_pkg.all;

entity axis_mac_monitor is
  generic (
    monitor : axis_mac_monitor_t
  );
  port (
    clk : in std_ulogic;
    tdata : in std_ulogic_vector(data_length(monitor) - 1 downto 0);
    tkeep : in std_ulogic_vector(keep_length(monitor) - 1 downto 0) := (others => '1');
    tvalid : in std_ulogic;
    tready : in std_ulogic := '1';
    tlast : in std_ulogic;
    tuser : in std_ulogic_vector(user_length(monitor) - 1 downto 0) := (others => '0')
  );
end entity;

architecture a of axis_mac_monitor is
begin
  main : process
  begin
    monitor_axis_interface(net, to_ethernet_vc(monitor), clk, tdata, tkeep, tvalid, tready, tlast, tuser);
  end process;

  protocol_checker_gen : if get_protocol_checker(monitor) /= null_axis_mac_protocol_checker generate
    protocol_checker_inst : entity work.axis_mac_protocol_checker
      generic map (
        protocol_checker => get_protocol_checker(monitor)
      )
      port map (
        clk => clk,
        tdata => tdata,
        tkeep => tkeep,
        tvalid => tvalid,
        tready => tready,
        tlast => tlast,
        tuser => tuser
      );
  end generate;
end architecture;
