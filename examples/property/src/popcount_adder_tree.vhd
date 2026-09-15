-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Counts the set bits of a 16-bit vector with a tree of adders, an
-- implementation genuinely different from popcount_loop.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity popcount_adder_tree is
  generic (
    -- A planted bug: the MSB is dropped before counting
    inject_bug : boolean := false
  );
  port (
    data_in : in std_ulogic_vector(15 downto 0);
    count : out std_ulogic_vector(4 downto 0)
  );
end entity;

architecture a of popcount_adder_tree is
  signal counted : std_ulogic_vector(15 downto 0);
  type stage1_t is array (0 to 3) of unsigned(2 downto 0);
  signal stage1 : stage1_t;
  type stage2_t is array (0 to 1) of unsigned(3 downto 0);
  signal stage2 : stage2_t;
begin
  counted <= data_in when not inject_bug else '0' & data_in(14 downto 0);

  stage1_gen : for grp in 0 to 3 generate
    stage1(grp) <= resize(unsigned'("" & counted(4 * grp)), 3) + resize(unsigned'("" & counted(4 * grp + 1)), 3) +
      resize(unsigned'("" & counted(4 * grp + 2)), 3) + resize(unsigned'("" & counted(4 * grp + 3)), 3);
  end generate;

  stage2(0) <= resize(stage1(0), 4) + resize(stage1(1), 4);
  stage2(1) <= resize(stage1(2), 4) + resize(stage1(3), 4);

  count <= std_ulogic_vector(resize(stage2(0), 5) + resize(stage2(1), 5));
end architecture;
