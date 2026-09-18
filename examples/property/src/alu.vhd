-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Adds or subtracts two octets; y is the 9-bit result, modulo 512.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity alu is
  port (
    a : in  std_ulogic_vector(7 downto 0);
    b : in  std_ulogic_vector(7 downto 0);
    subtract : in  std_ulogic;
    y : out std_ulogic_vector(8 downto 0)
  );
end entity;

architecture a of alu is

begin

  y <= std_ulogic_vector(resize(unsigned(a), 9) - unsigned(b)) when subtract = '1' else
       std_ulogic_vector(resize(unsigned(a), 9) + unsigned(b));
end architecture;
