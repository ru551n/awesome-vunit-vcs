-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A toggle-based pulse synchronizer: a one-cycle event pulse in the source
-- domain toggles a flag, a 2-flop synchronizer brings the flag into the
-- destination domain and an edge detector turns each toggle transition back
-- into a one-cycle destination event pulse. Correct use: source events at
-- least the documented minimum number of source cycles apart.

library ieee;
  use ieee.std_logic_1164.all;

entity toggle_synchronizer is
  generic (
    -- The deliberate bug: replace the toggle handshake with a naive pulse
    -- synchronizer that samples src_event directly through the destination
    -- flops instead of a toggle. A source pulse shorter than a destination
    -- period can be missed, and two close events can merge into one.
    inject_bug : boolean := false);
  port (
    src_clk : in  std_ulogic;
    src_rst : in  std_ulogic;
    src_event : in  std_ulogic;
    dst_clk : in  std_ulogic;
    dst_rst : in  std_ulogic;
    dst_event : out std_ulogic
  );
end entity;

architecture a of toggle_synchronizer is

  signal src_toggle : std_ulogic := '0';
  signal fed : std_ulogic;
  signal dst_sync_0 : std_ulogic := '0';
  signal dst_sync_1 : std_ulogic := '0';
  signal dst_sync_2 : std_ulogic := '0';

begin

  -- Source domain: the event pulse toggles a flag
  toggle_gen : process (src_clk)
  begin

    if rising_edge(src_clk) then
      if src_rst = '1' then
        src_toggle <= '0';
      elsif src_event = '1' then
        src_toggle <= not src_toggle;
      end if;
    end if;
  end process;

  -- The bug feeds the raw pulse into the synchronizer instead of the toggle
  fed <= src_event when inject_bug else
         src_toggle;

  -- Destination domain: a 2-flop synchronizer plus one more stage for edge detection
  sync_gen : process (dst_clk)
  begin

    if rising_edge(dst_clk) then
      if dst_rst = '1' then
        dst_sync_0 <= '0';
        dst_sync_1 <= '0';
        dst_sync_2 <= '0';
      else
        dst_sync_0 <= fed;
        dst_sync_1 <= dst_sync_0;
        dst_sync_2 <= dst_sync_1;
      end if;
    end if;
  end process;

  -- Correct: any toggle transition is one event. Buggy: only a rising edge of the
  -- sampled pulse is, so two events merged into one destination-domain high period
  -- are seen as a single event.
  dst_event <= (dst_sync_1 xor dst_sync_2) when not inject_bug else
               (dst_sync_1 and not dst_sync_2);
end architecture;
