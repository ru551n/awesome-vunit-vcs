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
    -- A planted bug: release frees the lowest still-live slot instead of the
    -- one named by handle, so a later allocate can hand out a handle that is
    -- still live.
    inject_bug : boolean := false);
  port (
    clk : in  std_ulogic;
    rst : in  std_ulogic;
    allocate : in  std_ulogic;
    release_handle : in  std_ulogic;
    write_enable : in  std_ulogic;
    handle : in  std_ulogic_vector(1 downto 0);
    write_data : in  std_ulogic_vector(7 downto 0);
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

  main : process (clk)

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

          slot_free := live(slot) = '0';
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
        idx := to_integer(unsigned(handle));
        if inject_bug then
          for slot in 0 to 3 loop

            if live(slot) = '1' then
              idx := slot;
              exit;
            end if;
          end loop;

        end if;
        live(idx) <= '0';
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
