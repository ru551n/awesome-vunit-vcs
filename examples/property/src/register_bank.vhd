-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Eight 8-bit registers with a synchronous write and a combinational read.
-- planted_bug makes a write to register 3 also write register 7, which
-- tb_register_sequence_property uses to show shrinking.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity register_bank is
  port (
    clk : in std_ulogic;
    rst : in std_ulogic;
    planted_bug : in boolean;
    write_enable : in std_ulogic;
    address : in std_ulogic_vector(2 downto 0);
    write_data : in std_ulogic_vector(7 downto 0);
    read_data : out std_ulogic_vector(7 downto 0)
  );
end entity;

architecture a of register_bank is
  type registers_t is array (0 to 7) of std_ulogic_vector(7 downto 0);
  signal registers : registers_t := (others => (others => '0'));
begin
  read_data <= registers(to_integer(unsigned(address)));

  main : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        registers <= (others => (others => '0'));
      elsif write_enable = '1' then
        registers(to_integer(unsigned(address))) <= write_data;
        if planted_bug and to_integer(unsigned(address)) = 3 then
          registers(7) <= write_data;
        end if;
      end if;
    end if;
  end process;
end architecture;
