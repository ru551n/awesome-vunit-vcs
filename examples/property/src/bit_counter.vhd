-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Counts the ones of a 16-bit value.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bit_counter is
  port (
    value : in std_ulogic_vector(15 downto 0);
    count : out std_ulogic_vector(4 downto 0)
  );
end entity;

architecture a of bit_counter is
begin
  main : process(value)
    variable ones : unsigned(count'range);
  begin
    ones := (others => '0');
    for idx in value'range loop
      if value(idx) = '1' then
        ones := ones + 1;
      end if;
    end loop;
    count <= std_ulogic_vector(ones);
  end process;
end architecture;
