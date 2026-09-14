-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A combinational ALU: op "00" adds a and b, "01" shifts a left by b(2:0)
-- bits within 8 bits, "10" gives 1 when a < b.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mini_alu is
  port (
    op : in std_ulogic_vector(1 downto 0);
    a : in std_ulogic_vector(7 downto 0);
    b : in std_ulogic_vector(7 downto 0);
    y : out std_ulogic_vector(8 downto 0)
  );
end entity;

architecture a of mini_alu is
begin
  main : process(op, a, b)
  begin
    case op is
      when "00" =>
        y <= std_ulogic_vector(resize(unsigned(a), 9) + unsigned(b));
      when "01" =>
        y <= '0' & std_ulogic_vector(shift_left(unsigned(a), to_integer(unsigned(b(2 downto 0)))));
      when "10" =>
        y <= (0 => '1', others => '0') when unsigned(a) < unsigned(b) else (others => '0');
      when others =>
        y <= (others => '0');
    end case;
  end process;
end architecture;
