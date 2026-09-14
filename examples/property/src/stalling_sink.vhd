-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- An octet sink with a planted bug: after it takes 0xFF, ready stays low until rst.

library ieee;
use ieee.std_logic_1164.all;

entity stalling_sink is
  port (
    clk, rst, valid : in std_ulogic;
    data : in std_ulogic_vector(7 downto 0);
    ready : out std_ulogic
  );
end entity;

architecture a of stalling_sink is
  signal stalled : std_ulogic := '0';
begin
  ready <= not stalled;

  main : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        stalled <= '0';
      elsif valid = '1' and data = x"FF" then
        stalled <= '1';
      end if;
    end if;
  end process;
end architecture;
