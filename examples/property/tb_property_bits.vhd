-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Property-based testing examples of a differential popcount, using
-- hardware-aware bit-pattern strategies, and a round-trip pack/unpack. The
-- strategies are in python/bits_strategies.py, built from python/bit_patterns.py.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

entity tb_property_bits is
  generic (
    runner_cfg : string;
    -- Plants the popcount_adder_tree and field_unpacker bugs: see
    -- examples/property/src/popcount_adder_tree.vhd and field_pack_unpack.vhd
    inject_bug : boolean := false);
end entity;

architecture tb of tb_property_bits is

  signal data_in : std_ulogic_vector(15 downto 0) := (others => '0');
  signal count_loop, count_tree : std_ulogic_vector(4 downto 0);
  signal opcode_in, opcode_out : std_ulogic_vector(3 downto 0) := (others => '0');
  signal flag_in, flag_out : std_ulogic := '0';
  signal address_in, address_out : std_ulogic_vector(5 downto 0) := (others => '0');
  signal value_in, value_out : std_ulogic_vector(4 downto 0) := (others => '0');
  signal packed : std_ulogic_vector(15 downto 0);

begin

  main : process

    variable prop : property_t;
    variable passed : boolean;

    -- A property from a strategy in python/bits_strategies.py, following VUnit's seed
    impure function new_example (strategy : string) return property_t is
    begin

      return new_property(
        "bits_strategies:" & strategy,
        seed => get_seed(runner_cfg),
        output_path => output_path(runner_cfg),
        search_path => tb_path(runner_cfg) & "python"
      );
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    while test_suite loop

      if run("test_differential_popcount") then
        -- docs-start: differential_popcount
        -- Two independently written popcount implementations must agree, with no
        -- golden third implementation. inject_bug makes the adder tree drop the
        -- MSB; Hypothesis finds and shrinks a minimal failing pattern.
        prop := new_example("differential_popcount");
        while next_example(prop) loop

          data_in <= get_unsigned(prop, "", 16);
          wait for 1 ns;
          report_example(
            prop,
            passed => count_loop = count_tree,
            msg => "data_in=" & integer'image(to_integer(unsigned(data_in)))
          );
        end loop;

        check_property(prop);
      -- docs-end: differential_popcount

      elsif run("test_roundtrip_pack") then
        -- docs-start: roundtrip_pack
        -- Unpacking a packed record returns the original fields: no expected
        -- value is computed, only that unpack(pack(x)) = x. inject_bug swaps the
        -- address MSB with the value LSB in the unpacker; Hypothesis shrinks the
        -- failure to a minimal record showing it.
        prop := new_example("roundtrip_pack");
        while next_example(prop) loop

          opcode_in <= std_ulogic_vector(to_unsigned(get_integer(prop, "opcode"), 4));
          flag_in <= '1' when get_integer(prop, "flag") = 1 else
                     '0';
          address_in <= std_ulogic_vector(to_unsigned(get_integer(prop, "address"), 6));
          value_in <= std_ulogic_vector(to_unsigned(get_integer(prop, "value"), 5));
          wait for 1 ns;
          passed := opcode_out = opcode_in and flag_out = flag_in and address_out = address_in and value_out = value_in;
          report_example(
            prop,
            passed => passed,
            msg =>
              "in: opcode="
              & to_hstring(opcode_in)
              & " flag="
              & std_ulogic'image(flag_in)
              & " address="
              & to_hstring(address_in)
              & " value="
              & to_hstring(value_in)
              & " out: opcode="
              & to_hstring(opcode_out)
              & " flag="
              & std_ulogic'image(flag_out)
              & " address="
              & to_hstring(address_out)
              & " value="
              & to_hstring(value_out)
          );
        end loop;

        check_property(prop);
      -- docs-end: roundtrip_pack
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  popcount_loop_inst : entity work.popcount_loop
    port map (
      data_in => data_in,
      count => count_loop
    );

  popcount_adder_tree_inst : entity work.popcount_adder_tree
    generic map (
      inject_bug => inject_bug
    )
    port map (
      data_in => data_in,
      count => count_tree
    );

  field_packer_inst : entity work.field_packer
    port map (
      opcode => opcode_in,
      flag => flag_in,
      address => address_in,
      value => value_in,
      packed => packed
    );

  field_unpacker_inst : entity work.field_unpacker
    generic map (
      inject_bug => inject_bug
    )
    port map (
      packed => packed,
      opcode => opcode_out,
      flag => flag_out,
      address => address_out,
      value => value_out
    );

end architecture;
