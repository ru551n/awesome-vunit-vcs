-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- ethernet_context is the only context clause a testbench needs: std_logic_1164,
-- VUnit, com, the sync and stream VCIs and every Ethernet VC package.

library awesome_vunit_vcs;
context awesome_vunit_vcs.ethernet_context;

entity tb_ethernet_context is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_ethernet_context is

  constant source : gmii_source_t := new_gmii_source;
  constant monitor : xgmii_monitor_t := new_xgmii_monitor(protocol_checker => default_xgmii_protocol_checker);
  constant protocol_checker : mii_protocol_checker_t := new_mii_protocol_checker;
  signal data : std_ulogic_vector(7 downto 0) := x"55";

begin

  main : process

    variable options : ethernet_frame_options_t;
    variable reference : ethernet_reference_t;
    variable stream_reference : stream_reference_t;
    variable values : integer_array_t;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_one_context_clause_is_enough") then
        options := frame_options(fcs => fcs_bad, ifg_octets => 8);
        check(options /= default_frame_options);
        check_equal(data_length(source), data'length);
        check_equal(ctrl_length(monitor), 4);
        check(as_sync(protocol_checker) = get_actor(protocol_checker));
        check(as_stream(source).p_actor = get_actor(source));
        values := new_1d(length => 1);
        check_equal(length(values), 1);
        info(get_logger(monitor), "Everything is visible");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

end architecture;
