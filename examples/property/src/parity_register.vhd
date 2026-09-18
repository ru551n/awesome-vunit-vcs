-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- An 8-bit register with a stored parity bit and an error output. A fault can
-- be injected into the STORED value without a simulator-specific force: pulse
-- corrupt_enable with flip_data and/or flip_parity XORed into the register.
-- inject_bug leaves bits 7 downto 4 out of the parity, so a flip there goes
-- undetected.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity parity_register is
  generic (
    inject_bug : boolean := false);
  port (
    clk : in  std_ulogic;
    rst : in  std_ulogic;
    write_enable : in  std_ulogic;
    corrupt_enable : in  std_ulogic;
    data_in : in  std_ulogic_vector(7 downto 0);
    flip_data : in  std_ulogic_vector(7 downto 0);
    flip_parity : in  std_ulogic;
    data_out : out std_ulogic_vector(7 downto 0);
    error : out std_ulogic
  );
end entity;

architecture a of parity_register is

  signal stored_data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal stored_parity : std_ulogic := '0';
  signal computed_parity : std_ulogic;

begin

  main : process (clk)
  begin

    if rising_edge(clk) then
      if rst = '1' then
        stored_data <= (others => '0');
        stored_parity <= '0';
      elsif write_enable = '1' then
        stored_data <= data_in;
        stored_parity <= (xor data_in(3 downto 0)) when inject_bug else
                         (xor data_in);
      elsif corrupt_enable = '1' then
        stored_data <= stored_data xor flip_data;
        stored_parity <= stored_parity xor flip_parity;
      end if;
    end if;
  end process;

  -- With the bug, bits 7 downto 4 are left out of both the stored and the recomputed
  -- parity, so a fault there is silent while every other single-bit fault
  -- (data or the parity bit itself) still changes one side but not the other
  computed_parity <= (xor stored_data(3 downto 0)) when inject_bug else
                     (xor stored_data);

  data_out <= stored_data;
  error <= computed_parity xor stored_parity;
end architecture;
