-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Counts the set bits of a 16-bit vector with a serial loop and an accumulator.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity popcount_loop is
  port (
    data_in : in std_ulogic_vector(15 downto 0);
    count : out std_ulogic_vector(4 downto 0)
  );
end entity;

architecture a of popcount_loop is
begin
  main : process(data_in)
    variable acc : natural range 0 to 16;
  begin
    acc := 0;
    for idx in data_in'range loop
      if data_in(idx) = '1' then
        acc := acc + 1;
      end if;
    end loop;
    count <= std_ulogic_vector(to_unsigned(acc, 5));
  end process;
end architecture;
