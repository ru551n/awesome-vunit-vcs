-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- An AXI-Stream MAC client source: transmits frames as AXI-Stream packets,
-- one beat per clock edge that tready accepts. Frames carry no preamble or
-- SFD, and the FCS only when the source has one.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.com_context;

use work.ethernet_vc_pkg.all;
use work.axis_mac_pkg.all;

entity axis_mac_source is
  generic (
    source : axis_mac_source_t
  );
  port (
    clk : in std_ulogic;
    tdata : out std_ulogic_vector(data_length(source) - 1 downto 0) := (others => '0');
    tkeep : out std_ulogic_vector(keep_length(source) - 1 downto 0) := (others => '0');
    tvalid : out std_ulogic := '0';
    tready : in std_ulogic := '1';
    tlast : out std_ulogic := '0';
    tuser : out std_ulogic_vector(user_length(source) - 1 downto 0) := (others => '0')
  );
end entity;

architecture a of axis_mac_source is
begin
  main : process
  begin
    drive_axis_interface(net, to_ethernet_vc(source), clk, tdata, tkeep, tvalid, tready, tlast, tuser);
  end process;
end architecture;
