-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A counter that adds step on every enabled clock edge and wraps past limit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wrap_counter is
  port (
    clk : in std_ulogic;
    rst : in std_ulogic;
    enable : in std_ulogic;
    step : in std_ulogic_vector(3 downto 0);
    limit : in std_ulogic_vector(7 downto 0);
    count : out std_ulogic_vector(7 downto 0) := (others => '0')
  );
end entity;

architecture a of wrap_counter is
begin
  main : process(clk)
    variable next_count : natural range 0 to 255 + 15;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        count <= (others => '0');
      elsif enable = '1' then
        next_count := to_integer(unsigned(count)) + to_integer(unsigned(step));
        count <= std_ulogic_vector(to_unsigned(next_count mod (to_integer(unsigned(limit)) + 1), count'length));
      end if;
    end if;
  end process;
end architecture;
