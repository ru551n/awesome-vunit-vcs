-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Eight registers with a synchronous write and a combinational read.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity register_bank is
  generic (
    -- A planted bug: writes to this address are lost. -1 for none.
    stuck_address : integer := -1);
  port (
    clk : in  std_ulogic;
    rst : in  std_ulogic;
    write_enable : in  std_ulogic;
    address : in  std_ulogic_vector(2 downto 0);
    write_data : in  std_ulogic_vector(7 downto 0);
    read_data : out std_ulogic_vector(7 downto 0)
  );
end entity;

architecture a of register_bank is

  type registers_t is array (0 to 7) of std_ulogic_vector(7 downto 0);

  signal registers : registers_t := (others => (others => '0'));

begin

  read_data <= registers(to_integer(unsigned(address)));

  main : process (clk)
  begin

    if rising_edge(clk) then
      if rst = '1' then
        registers <= (others => (others => '0'));
      elsif write_enable = '1' and to_integer(unsigned(address)) /= stuck_address then
        registers(to_integer(unsigned(address))) <= write_data;
      end if;
    end if;
  end process;

end architecture;
