-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Byte sink for tb_property with a planted deadlock: a byte of 0xF0 or more
-- directly followed by a byte of 0x0F or less makes ready stick low until
-- rst. With reset_works false the reset is ignored, so the lockup never clears.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity property_lockup_dut is
  port (
    clk : in  std_ulogic;
    rst : in  std_ulogic;
    reset_works : in  boolean;
    data : in  std_ulogic_vector(7 downto 0);
    valid : in  std_ulogic;
    ready : out std_ulogic := '0'
  );
end entity;

architecture a of property_lockup_dut is

  signal high_seen, locked : boolean := false;

begin

  ready <= '0' when locked or rst = '1' else
           '1';

  main : process (clk)
  begin

    if rising_edge(clk) then
      if rst = '1' and reset_works then
        high_seen <= false;
        locked <= false;
      elsif valid = '1' and not locked then
        if high_seen and unsigned(data) <= 16#0f# then
          locked <= true;
        end if;
        high_seen <= unsigned(data) >= 16#f0#;
      end if;
    end if;
  end process;

end architecture;
