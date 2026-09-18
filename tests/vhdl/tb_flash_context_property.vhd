-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- flash_context alone is enough to run a property with typed arguments.

library awesome_vunit_vcs;
context awesome_vunit_vcs.flash_context;

entity tb_flash_context_property is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_flash_context_property is

begin

  main : process

    variable prop : property_t;

  begin

    test_runner_setup(runner, runner_cfg);
    prop := new_property(
      "property_strategies:payloads",
      kwarg("max_size", 4),
      max_examples => 5,
      seed => get_seed(runner_cfg),
      output_path => output_path(runner_cfg),
      search_path => tb_path(runner_cfg) & "python"
    );
    while next_example(prop) loop

      report_example(prop, passed => get_length(prop) <= 4);
    end loop;

    check_property(prop);
    test_runner_cleanup(runner);
  end process;

end architecture;
