-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.

library vunit_lib;
context vunit_lib.vunit_context;

library python_bridge;
context python_bridge.python_context;

library awesome_vunit_vcs;
  use awesome_vunit_vcs.vc_python_pkg.all;

-- Uses the installed package: its VHDL library, compiled by add_package, and
-- its Python modules, imported by the embedded interpreter. Neither is
-- located through a path.
entity tb_installed_package is
  generic (
    runner_cfg : string);
end entity;

architecture tb of tb_installed_package is

begin

  main : process

    constant session : python_session_t := new_vc_session(get_id("tb_installed_package:backend"));

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("test_installed_python_backend_is_importable") then
        create_backend(session, "awesome_vunit_vcs.common.reports", "ReportQueue");
        check_equal(backend_call_integer(session, "__len__"), 0);

      elsif run("test_typed_arguments_round_trip") then
        create_backend(session, "builtins", "list", arg(integer_vector'(1, -2, 3)));
        check_equal(backend_call_integer(session, "__len__"), 3);
        check_equal(backend_call_string(session, "__repr__"), "[1, -2, 3]");
        check_true(backend_call_boolean(session, "__contains__", arg(-2)));

        -- Free text keeps its quotes and backslashes
        create_backend(
          session,
          "awesome_vunit_vcs.common.vunit_bridge",
          "decode_text",
          arg_text("quote "" ' and backslash \")
        );
        check_equal(backend_call_string(session, "__str__"), "quote "" ' and backslash \");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  test_runner_watchdog(runner, 10 ms);
end architecture;
