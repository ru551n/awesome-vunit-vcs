-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- A synchronous stack machine that evaluates a postfix arithmetic program, one instruction per
-- clock cycle: const pushes operand, add/subtract/negate pop and push. All arithmetic is modulo
-- 256 (8-bit unsigned wraparound), which unsigned overflow gives for free.
-- A planted bug: inject_bug swaps subtract's operand order, computing b - a instead of a - b.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rpn_evaluator is
  generic (
    inject_bug : boolean := false
  );
  port (
    clk, rst, push : in std_ulogic;
    -- "00" const, "01" add, "10" subtract, "11" negate
    op : in std_ulogic_vector(1 downto 0);
    -- The value to push for const, don't-care otherwise
    operand : in std_ulogic_vector(7 downto 0);
    -- The top of the stack, valid one cycle after each push
    result : out std_ulogic_vector(7 downto 0)
  );
end entity;

architecture a of rpn_evaluator is
  type stack_t is array (0 to 7) of unsigned(7 downto 0);
  signal stack : stack_t := (others => (others => '0'));
  signal sp : natural range 0 to 8 := 0;
begin
  result <= std_ulogic_vector(stack(sp - 1)) when sp > 0 else (others => '0');

  main : process(clk)
    variable a, b : unsigned(7 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        sp <= 0;
      elsif push = '1' then
        if op = "00" then
          stack(sp) <= unsigned(operand);
          sp <= sp + 1;
        elsif op = "11" then
          a := stack(sp - 1);
          stack(sp - 1) <= 0 - a;
        else
          b := stack(sp - 1);
          a := stack(sp - 2);
          if op = "01" then
            stack(sp - 2) <= a + b;
          elsif inject_bug then
            stack(sp - 2) <= b - a;
          else
            stack(sp - 2) <= a - b;
          end if;
          sp <= sp - 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
