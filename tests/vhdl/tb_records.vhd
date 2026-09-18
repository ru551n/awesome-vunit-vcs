-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Round trip of the VHDL records generated from Python dataclasses: every
-- example read into a generated record shows the same text as the Python
-- value it was drawn as. The dataclasses are in python/record_types.py; run.py
-- generates record_types_pkg from them.

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
  use awesome_vunit_vcs.property_pkg.all;

  use work.record_types_pkg.all;

entity tb_records is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_records is

begin

  main : process

    variable prop : property_t;
    variable link : link_t;
    variable lane : lane_t;

  begin

    test_runner_setup(runner, runner_cfg);
    while test_suite loop

      if run("test_generated_records_read_every_field_type") then
        prop := new_property(
          "record_types:links",
          max_examples => 200,
          seed => get_seed(runner_cfg),
          search_path => tb_path(runner_cfg) & "python"
        );
        while next_example(prop) loop

          link := get_link(prop, "value");
          report_example(prop, passed => to_string(link) = get_string(prop, "image"), msg => to_string(link));
        end loop;

        check_property(prop);

      elsif run("test_generated_record_at_the_top_of_the_example") then
        prop := new_property(
          "record_types:lanes_only",
          max_examples => 20,
          seed => get_seed(runner_cfg),
          search_path => tb_path(runner_cfg) & "python"
        );
        while next_example(prop) loop

          lane := get_lane(prop);
          report_example(
            prop,
            passed => lane.index = get_integer(prop, "index") and lane.enabled = get_boolean(prop, "enabled")
          );
        end loop;

        check_property(prop);
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

end architecture;
