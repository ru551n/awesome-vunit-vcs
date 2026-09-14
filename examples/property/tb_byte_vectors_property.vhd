-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- (c) A list of variable-length byte vectors. Property: the checksum of every
-- packet of every packet list is the sum of its bytes modulo 256, reported
-- within a simulation-time budget that grows with the packet. A checksum that
-- never arrives is reported as a lockup, a different failure than a wrong
-- checksum. Shrinking: Hypothesis removes packets, then bytes, then lowers
-- byte values, so a failure ends as the fewest and smallest bytes that fail.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_byte_vectors_property is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_byte_vectors_property is
  constant clk_period : time := 10 ns;

  signal clk : std_ulogic := '0';
  signal rst : std_ulogic := '1';
  signal data : std_ulogic_vector(7 downto 0) := (others => '0');
  signal valid : std_ulogic := '0';
  signal last : std_ulogic := '0';
  signal checksum : std_ulogic_vector(7 downto 0);
  signal done : std_ulogic;
begin
  clk <= not clk after clk_period / 2;

  main : process
    variable prop : property_t;
    variable passed, timed_out : boolean;
    variable sum : natural;

    procedure send_packet(packet : integer_vector) is
    begin
      for idx in packet'range loop
        data <= std_ulogic_vector(to_unsigned(packet(idx), 8));
        valid <= '1';
        last <= '1' when idx = packet'right else '0';
        wait until rising_edge(clk);
      end loop;
      valid <= '0';
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    while test_suite loop
      if run("test_checksum_of_every_packet") then
        -- docs-start: byte_vectors_loop
        prop := new_property("property_examples:packets", seed => get_seed(runner_cfg),
          output_path => output_path(runner_cfg), search_path => tb_path(runner_cfg) & "python");
        while next_example(prop) loop
          rst <= '1';
          wait until rising_edge(clk);
          rst <= '0';
          passed := true;
          timed_out := false;
          for packet_idx in 0 to get_length(prop) - 1 loop
            send_packet(get_integer_vector(prop, "(" & integer'image(packet_idx) & ")"));
            -- done is high for one clock cycle after the last byte; sample it on a clock edge
            wait until rising_edge(clk) and done = '1' for 3 * clk_period;
            timed_out := done /= '1';
            sum := 0;
            for idx in 0 to get_length(prop, "(" & integer'image(packet_idx) & ")") - 1 loop
              sum := sum + get_integer(prop, "(" & integer'image(packet_idx) & ")(" & integer'image(idx) & ")");
            end loop;
            passed := not timed_out and to_integer(unsigned(checksum)) = sum mod 256;
            exit when not passed;
          end loop;
          report_example(prop, passed => passed, timed_out => timed_out);
        end loop;
        check_property(prop);
        -- docs-end: byte_vectors_loop
      end if;
    end loop;
    test_runner_cleanup(runner);
  end process;

  dut_inst : entity work.byte_checksum
    port map (
      clk => clk,
      rst => rst,
      data => data,
      valid => valid,
      last => last,
      checksum => checksum,
      done => done
    );
end architecture;
