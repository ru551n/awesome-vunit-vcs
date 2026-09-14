-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- (a) A single integer. Property: the bit counter reports the number of ones
-- of every 16-bit value. Shrinking: had the counter a bug, Hypothesis would
-- reduce the failing value to the smallest one with the same defect, such as
-- 0x8000 for a miscounted top bit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_integer_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_integer_property is
  signal value : std_ulogic_vector(15 downto 0) := (others => '0');
  signal count : std_ulogic_vector(4 downto 0);
begin
  main : process
    function ones(number : natural) return natural is
      constant bits : unsigned(15 downto 0) := to_unsigned(number, 16);
      variable result : natural := 0;
    begin
      for idx in bits'range loop
        if bits(idx) = '1' then
          result := result + 1;
        end if;
      end loop;
      return result;
    end;

    variable prop : property_t;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_bit_count_of_every_value") then
        -- docs-start: integer_loop
        prop := new_property("property_examples:any_16_bit_value", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          value <= std_ulogic_vector(to_unsigned(get_integer(prop), 16));
          wait for 1 ns;
          report_example(prop, passed => to_integer(unsigned(count)) = ones(get_integer(prop)));
        end loop;
        check_property(prop);
        -- docs-end: integer_loop
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.bit_counter
    port map (
      value => value,
      count => count
    );
end architecture;
