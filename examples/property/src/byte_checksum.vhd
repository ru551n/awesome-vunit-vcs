-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Sums the bytes of a packet modulo 256. done pulses with the checksum on the
-- clock edge after the last byte.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity byte_checksum is
  port (
    clk : in std_ulogic;
    rst : in std_ulogic;
    data : in std_ulogic_vector(7 downto 0);
    valid : in std_ulogic;
    last : in std_ulogic;
    checksum : out std_ulogic_vector(7 downto 0) := (others => '0');
    done : out std_ulogic := '0'
  );
end entity;

architecture a of byte_checksum is
  signal sum : unsigned(7 downto 0) := (others => '0');
begin
  main : process(clk)
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        sum <= (others => '0');
      elsif valid = '1' then
        if last = '1' then
          checksum <= std_ulogic_vector(sum + unsigned(data));
          done <= '1';
          sum <= (others => '0');
        else
          sum <= sum + unsigned(data);
        end if;
      end if;
    end if;
  end process;
end architecture;
