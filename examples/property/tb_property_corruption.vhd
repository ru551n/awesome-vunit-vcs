-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Two property-based testing techniques on their own small DUTs: fault
-- injection on a parity register, and structured invalid-input mutation on a
-- packet parser. The strategies are in python/corruption_strategies.py.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library awesome_vunit_vcs;
context awesome_vunit_vcs.property_context;

entity tb_property_corruption is
  generic (
    runner_cfg : string;
    inject_bug : boolean := false);
end entity;

architecture tb of tb_property_corruption is

  signal clk, rst : std_ulogic := '0';

  signal pr_write_enable : std_ulogic := '0';
  signal pr_corrupt_enable : std_ulogic := '0';
  signal pr_error : std_ulogic := '0';
  signal pr_data_in : std_ulogic_vector(7 downto 0) := (others => '0');
  signal pr_flip_data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal pr_data_out : std_ulogic_vector(7 downto 0) := (others => '0');
  signal pr_flip_parity : std_ulogic := '0';

  signal pp_valid : std_ulogic := '0';
  signal pp_accepted : std_ulogic := '0';
  signal pp_rejected : std_ulogic := '0';
  signal pp_data : std_ulogic_vector(7 downto 0) := (others => '0');

begin

  clk <= not clk after 5 ns;

  main : process

    variable prop : property_t;
    variable passed : boolean;
    variable timed_out : boolean;
    variable has_fault : boolean;

    -- A property from a strategy in python/corruption_strategies.py, following VUnit's seed
    impure function new_example (strategy : string) return property_t is
    begin

      return new_property(
        "corruption_strategies:" & strategy,
        seed => get_seed(runner_cfg),
        output_path => output_path(runner_cfg),
        search_path => tb_path(runner_cfg) & "python"
      );
    end;

    -- Hold a signal high for one clock cycle
    procedure pulse (signal value : out std_ulogic) is
    begin

      value <= '1';
      wait until rising_edge(clk);
      value <= '0';
    end;

    -- The path of list element idx, "(2)"
    impure function item (idx : natural) return string is
    begin

      return "(" & integer'image(idx) & ")";
    end;

  begin

    test_runner_setup(runner, runner_cfg);
    while test_suite loop

      if run("test_fault_injection") then
        -- docs-start: fault_injection
        -- A stored byte plus its parity bit; with no fault the register reads back
        -- cleanly, and a single bit flip, in the data or in the parity, must surface
        -- as an error. Hypothesis shrinks data, fault kind and fault position.
        prop := new_example("fault_injection");
        while next_example(prop) loop

          pulse(rst);
          pr_data_in <= get_unsigned(prop, "data", 8);
          pulse(pr_write_enable);
          wait for 1 ns;
          has_fault := has_field(prop, "fault");
          if has_fault then
            if get_string(prop, "fault.kind") = "flip_data" then
              pr_flip_data <= std_ulogic_vector(shift_left(to_unsigned(1, 8), get_integer(prop, "fault.position")));
              pr_flip_parity <= '0';
            else
              pr_flip_data <= (others => '0');
              pr_flip_parity <= '1';
            end if;
            pulse(pr_corrupt_enable);
            wait for 1 ns;
          end if;
          if has_fault then
            passed := pr_error = '1';
          else
            passed := pr_error = '0' and pr_data_out = get_unsigned(prop, "data", 8);
          end if;
          report_example(prop, passed => passed);
        end loop;

        check_property(prop);
      -- docs-end: fault_injection

      elsif run("test_invalid_packet_mutation") then
        -- docs-start: invalid_packet_mutation
        -- Generate a valid packet first, then mutate exactly one semantic rule.
        -- Shrinking narrows both the packet (payload length, byte values) and the
        -- mutation (down to "none" versus one specific kind).
        prop := new_example("mutated_packet");
        while next_example(prop) loop

          pulse(rst);
          for idx in 0 to get_length(prop, "packet") - 1 loop

            pp_data <= get_unsigned(prop, "packet" & item(idx), 8);
            pulse(pp_valid);
          end loop;

          wait until (pp_accepted = '1' or pp_rejected = '1')
            for example_budget(20 ns, 10 ns, get_length(prop, "packet"));
          timed_out := pp_accepted /= '1' and pp_rejected /= '1';
          if timed_out then
            passed := not get_boolean(prop, "valid");
          else
            passed := (pp_accepted = '1') = get_boolean(prop, "valid");
          end if;
          -- A truncated packet leaves the parser waiting, which is a rejection too: only a valid
          -- packet that times out is a lockup
          report_example(prop, passed => passed, timed_out => timed_out and not passed);
        end loop;

        check_property(prop);
      -- docs-end: invalid_packet_mutation
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  parity_register_inst : entity work.parity_register
    generic map (
      inject_bug => inject_bug
    )
    port map (
      clk => clk,
      rst => rst,
      write_enable => pr_write_enable,
      corrupt_enable => pr_corrupt_enable,
      data_in => pr_data_in,
      flip_data => pr_flip_data,
      flip_parity => pr_flip_parity,
      data_out => pr_data_out,
      error => pr_error
    );

  packet_parser_inst : entity work.packet_parser
    generic map (
      inject_bug => inject_bug
    )
    port map (
      clk => clk,
      rst => rst,
      valid => pp_valid,
      data => pp_data,
      accepted => pp_accepted,
      rejected => pp_rejected
    );

end architecture;
