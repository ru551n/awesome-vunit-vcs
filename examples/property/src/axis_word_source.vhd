-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A one-word AXI4-Stream source: a word taken on the load interface is sent on
-- the AXI output. TVALID rises one cycle after the word is loaded and stays high
-- until the transfer. A planted bug, off by default, makes TVALID wait until
-- TREADY is seen, which an AXI4-Stream source must never do.

library ieee;
use ieee.std_logic_1164.all;

entity axis_word_source is
  generic (
    -- A planted bug: TVALID only rises after TREADY is seen
    inject_bug : boolean := false
  );
  port (
    clk, rst : in std_ulogic;
    -- The load interface: a word is taken when load_valid and load_ready are high
    load_valid : in std_ulogic;
    load_data : in std_ulogic_vector(7 downto 0);
    load_ready : out std_ulogic;
    -- The AXI4-Stream output
    m_axis_tvalid : out std_ulogic;
    m_axis_tready : in std_ulogic;
    m_axis_tdata : out std_ulogic_vector(7 downto 0)
  );
end entity;

architecture a of axis_word_source is
  signal pending, tvalid : std_ulogic := '0';
  signal data : std_ulogic_vector(7 downto 0) := (others => '0');
begin
  -- A new word is taken only when no word is pending
  load_ready <= not pending;
  m_axis_tvalid <= tvalid;
  m_axis_tdata <= data;

  main : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pending <= '0';
        tvalid <= '0';
      else
        if tvalid = '1' and m_axis_tready = '1' then
          -- The transfer: the word is gone
          pending <= '0';
          tvalid <= '0';
        -- docs-start: tvalid
        elsif inject_bug then
          -- Wrong: TVALID waits for TREADY
          tvalid <= pending and (tvalid or m_axis_tready);
        else
          -- Right: TVALID follows the pending word, whatever TREADY is
          tvalid <= pending;
        -- docs-end: tvalid
        end if;

        if load_valid = '1' and pending = '0' then
          pending <= '1';
          data <= load_data;
        end if;
      end if;
    end if;
  end process;
end architecture;
