-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A two-client arbiter for one shared resource. Each client's level request is
-- granted when the resource is free; dropping the request cancels a pending
-- request or releases a held one. inject_bug plants a bug where a client
-- requesting the same cycle another cancels is granted immediately, before the
-- cancelling client's own grant has cleared, so both are held for a cycle.

library ieee;
  use ieee.std_logic_1164.all;

entity arbiter2 is
  generic (
    inject_bug : boolean := false);
  port (
    clk : in  std_ulogic;
    rst : in  std_ulogic;
    request_a : in  std_ulogic;
    request_b : in  std_ulogic;
    grant_a : out std_ulogic;
    grant_b : out std_ulogic
  );
end entity;

architecture a of arbiter2 is

  signal held_a, held_b : std_ulogic := '0';

begin

  grant_a <= held_a;
  grant_b <= held_b;

  main : process (clk)

    variable next_a, next_b : std_ulogic;

  begin

    if rising_edge(clk) then
      if rst = '1' then
        held_a <= '0';
        held_b <= '0';
      elsif inject_bug and held_a = '1' and request_a = '0' and held_b = '0' and request_b = '1' then
        held_a <= '1';
        held_b <= '1';
      elsif inject_bug and held_b = '1' and request_b = '0' and held_a = '0' and request_a = '1' then
        held_a <= '1';
        held_b <= '1';
      else
        next_a := held_a;
        next_b := held_b;
        if next_a = '1' and request_a = '0' then
          next_a := '0';
        end if;
        if next_b = '1' and request_b = '0' then
          next_b := '0';
        end if;
        if held_a = '0' and held_b = '0' then
          if request_a = '1' then
            next_a := '1';
          elsif request_b = '1' then
            next_b := '1';
          end if;
        end if;
        held_a <= next_a;
        held_b <= next_b;
      end if;
    end if;
  end process;

end architecture;
