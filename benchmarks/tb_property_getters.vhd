-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Benchmark of property_pkg field getters: 200 examples of a 50-field record,
-- read field by field or not at all. Compare the test times of the two
-- configurations.

library vunit_lib;
context vunit_lib.vunit_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.property_pkg.all;

entity tb_property_getters is
  generic (
    runner_cfg : string;
    reads : natural := 50
  );
end entity;

architecture tb of tb_property_getters is
begin
  main : process
    variable prop : property_t;
    variable total : natural;
    variable start : time;
  begin
    test_runner_setup(runner, runner_cfg);
    prop := new_property("property_benchmark:fields", max_examples => 200, seed => "benchmark",
      search_path => tb_path(runner_cfg) & "python");
    while next_example(prop) loop
      for idx in 0 to reads - 1 loop
        total := total + get_integer(prop, "field_" & integer'image(idx));
      end loop;
      report_example(prop, passed => true);
    end loop;
    check_property(prop);
    info("BENCHMARK getters reads=" & integer'image(reads) & " examples=" & integer'image(get_example_count(prop)));
    test_runner_cleanup(runner);
  end process;
end architecture;
