-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A pin-level boot reader: after reset it reads num_bytes bytes from address 0
-- of a QSPI flash with READ (0x03) on one lane, SPI mode 0, with SCK at half
-- the clock frequency. An RTL example of driving the flash pins directly.

-- docs-start: spi-boot-reader
library ieee;
use ieee.std_logic_1164.all;

library awesome_vunit_vcs;
use awesome_vunit_vcs.qspi_pkg.all;

entity spi_boot_reader is
  generic (num_bytes : positive := 4);
  port (
    clk : in std_ulogic;
    rst_n : in std_ulogic;
    m2s : out qspi_m2s_t := qspi_m2s_init;
    s2m : in qspi_s2m_t;
    data : out std_ulogic_vector(0 to 8 * num_bytes - 1) := (others => '0');
    done : out std_ulogic := '0'
  );
end entity;

architecture a of spi_boot_reader is
  -- READ (0x03) followed by the 24-bit address 0, sent most significant bit first
  constant command : std_ulogic_vector(0 to 31) := x"03000000";
  signal bit_index : natural range 0 to command'length + 8 * num_bytes := 0;
begin
  main : process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        m2s <= qspi_m2s_init;
        bit_index <= 0;
        done <= '0';
      elsif done = '0' then
        if m2s.cs_n = '1' then
          -- Select the flash and put the first command bit on IO0, SCK still low
          m2s.cs_n <= '0';
          m2s.io.value(0) <= command(0);
          m2s.io.enable(0) <= '1';
        elsif m2s.sck = '0' then
          -- Rising edge: the flash samples IO0
          m2s.sck <= '1';
        else
          -- Falling edge: take IO1, then set up the next command bit
          m2s.sck <= '0';
          if bit_index >= command'length then
            data(bit_index - command'length) <= s2m.io.value(1);
          end if;
          if bit_index + 1 < command'length then
            m2s.io.value(0) <= command(bit_index + 1);
          else
            m2s.io.enable(0) <= '0';
          end if;
          if bit_index = command'length + data'length - 1 then
            m2s.cs_n <= '1';
            done <= '1';
          end if;
          bit_index <= bit_index + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
-- docs-end: spi-boot-reader
