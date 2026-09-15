-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A depth-8 synchronous FIFO, for the targeted property search of
-- tb_property_fifo.vhd.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fifo8 is
  generic (
    -- A planted bug: a simultaneous push and pop while full drops the pushed
    -- word instead of keeping it, only visible near full and at wraparound.
    inject_bug : boolean := false
  );
  port (
    clk, rst : in std_ulogic;
    push, pop : in std_ulogic;
    data_in : in std_ulogic_vector(7 downto 0);
    data_out : out std_ulogic_vector(7 downto 0);
    full, empty : out std_ulogic;
    count : out std_ulogic_vector(3 downto 0)
  );
end entity;

architecture a of fifo8 is
  type memory_t is array (0 to 7) of std_ulogic_vector(7 downto 0);
  signal memory : memory_t := (others => (others => '0'));
  signal wr_ptr, rd_ptr : natural range 0 to 7 := 0;
  signal fill : natural range 0 to 8 := 0;
  signal is_full, is_empty : std_ulogic;
begin
  is_full <= '1' when fill = 8 else '0';
  is_empty <= '1' when fill = 0 else '0';
  full <= is_full;
  empty <= is_empty;
  count <= std_ulogic_vector(to_unsigned(fill, 4));
  data_out <= memory(rd_ptr);

  main : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        wr_ptr <= 0;
        rd_ptr <= 0;
        fill <= 0;
      elsif push = '1' and pop = '1' and is_full = '1' then
        -- Both at once while full: the pop frees the slot the push uses, so
        -- fill is unchanged. The bug skips writing the new word, dropping it.
        rd_ptr <= (rd_ptr + 1) mod 8;
        if not inject_bug then
          memory(wr_ptr) <= data_in;
          wr_ptr <= (wr_ptr + 1) mod 8;
        else
          fill <= fill - 1;
        end if;
      elsif push = '1' and pop = '1' and is_empty = '1' then
        -- Nothing to pop yet, so only the push happens
        memory(wr_ptr) <= data_in;
        wr_ptr <= (wr_ptr + 1) mod 8;
        fill <= fill + 1;
      elsif push = '1' and pop = '1' then
        memory(wr_ptr) <= data_in;
        wr_ptr <= (wr_ptr + 1) mod 8;
        rd_ptr <= (rd_ptr + 1) mod 8;
      elsif push = '1' and is_full = '0' then
        memory(wr_ptr) <= data_in;
        wr_ptr <= (wr_ptr + 1) mod 8;
        fill <= fill + 1;
      elsif pop = '1' and is_empty = '0' then
        rd_ptr <= (rd_ptr + 1) mod 8;
        fill <= fill - 1;
      end if;
    end if;
  end process;
end architecture;
