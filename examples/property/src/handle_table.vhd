-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A 4-slot handle table: allocate returns a free slot, or none when the table
-- is full; write, read and release_handle act on a slot by its handle.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity handle_table is
  generic (
    -- A planted bug: the free-slot search always treats slot 3 as free, so
    -- allocate can hand out a handle that is still live.
    inject_bug : boolean := false
  );
  port (
    clk, rst, allocate, release_handle, write_enable : in std_ulogic;
    handle : in std_ulogic_vector(1 downto 0);
    write_data : in std_ulogic_vector(7 downto 0);
    read_data : out std_ulogic_vector(7 downto 0);
    allocated_handle : out std_ulogic_vector(1 downto 0);
    allocated : out std_ulogic
  );
end entity;

architecture a of handle_table is
  type data_t is array (0 to 3) of std_ulogic_vector(7 downto 0);
  signal data : data_t := (others => (others => '0'));
  signal live : std_ulogic_vector(3 downto 0) := (others => '0');
begin
  read_data <= data(to_integer(unsigned(handle)));

  main : process(clk)
    variable idx : natural range 0 to 4;
    variable slot_free : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        live <= (others => '0');
        data <= (others => (others => '0'));
        allocated <= '0';
      elsif allocate = '1' then
        idx := 4;
        for slot in 0 to 3 loop
          slot_free := (live(slot) = '0') or (inject_bug and (slot = 3));
          if slot_free and idx = 4 then
            idx := slot;
          end if;
        end loop;
        if idx = 4 then
          allocated <= '0';
        else
          live(idx) <= '1';
          data(idx) <= (others => '0');
          allocated_handle <= std_ulogic_vector(to_unsigned(idx, 2));
          allocated <= '1';
        end if;
      elsif release_handle = '1' then
        live(to_integer(unsigned(handle))) <= '0';
        allocated <= '0';
      elsif write_enable = '1' then
        data(to_integer(unsigned(handle))) <= write_data;
        allocated <= '0';
      else
        allocated <= '0';
      end if;
    end if;
  end process;
end architecture;
