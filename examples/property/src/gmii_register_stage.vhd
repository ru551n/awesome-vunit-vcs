-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A GMII register stage: the output is the input delayed by one clock cycle.

library ieee;
use ieee.std_logic_1164.all;

entity gmii_register_stage is
  port (
    clk : in std_ulogic;
    in_data : in std_ulogic_vector(7 downto 0);
    in_dv : in std_ulogic;
    in_er : in std_ulogic;
    out_data : out std_ulogic_vector(7 downto 0) := (others => '0');
    out_dv : out std_ulogic := '0';
    out_er : out std_ulogic := '0'
  );
end entity;

architecture a of gmii_register_stage is
begin
  main : process(clk)
  begin
    if rising_edge(clk) then
      out_data <= in_data;
      out_dv <= in_dv;
      out_er <= in_er;
    end if;
  end process;
end architecture;
