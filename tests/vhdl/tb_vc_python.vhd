-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The helpers of vc_python_pkg: backend calls with typed arguments, time and
-- text arguments, and arguments carried in com messages to another process.

use std.textio.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;

library python_bridge;
context python_bridge.python_context;

library awesome_vunit_vcs;
use awesome_vunit_vcs.vc_python_pkg.all;

entity tb_vc_python is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_vc_python is
  constant receiver : actor_t := new_actor("tb_vc_python:receiver");
  constant arguments_msg : msg_type_t := new_msg_type("tb_vc_python arguments");
  signal received : boolean := false;
begin
  main : process
    constant session : python_session_t := new_vc_session(get_id("tb_vc_python:backend"));

    -- The arguments are built from variables that are gone before the receiver uses them
    procedure send_arguments is
      variable port_number : integer := 1234;
      variable text : line := new string'("it's ""quoted"" \ here" & LF & "and on a new line");
      variable msg : msg_t := new_msg(arguments_msg);
    begin
      push_arg(msg, arg("plain") & kwarg("port", port_number) & kwarg_text("message", text.all));
      deallocate(text);
      port_number := 0;
      send(net, receiver, msg);
    end;
  begin
    test_runner_setup(runner, runner_cfg);
    exec("import builtins", session);

    while test_suite loop
      if run("test_backend_calls_with_typed_arguments") then
        create_backend(session, "collections", "Counter", kwarg("a", 2) & kwarg("b", 3));
        check_equal(backend_call_integer(session, "total"), 5);
        check_true(backend_call_boolean(session, "__contains__", arg("a")));
        check_equal(backend_call_string(session, "__repr__"), "Counter({'b': 3, 'a': 2})");
        backend_call(session, "update", kwarg("c", 4));
        check_equal(backend_call_integer(session, "total"), 9);

      elsif run("test_text_arguments_keep_every_character") then
        create_backend(
          session, "awesome_vunit_vcs.common.vunit_bridge", "decode_text",
          arg_text("quote "" apostrophe ' backslash \ tab" & HT & "end")
        );
        check_equal(backend_call_string(session, "__str__"), "quote "" apostrophe ' backslash \ tab" & HT & "end");

      elsif run("test_time_arguments_of_any_size") then
        create_backend(session, "awesome_vunit_vcs.common.vunit_bridge", "decode_time_fs", arg_time(123456789 ns));
        check_equal(backend_call_string(session, "__str__"), "123456789000000");
        create_backend(session, "awesome_vunit_vcs.common.vunit_bridge", "decode_time_fs", arg_time(1 fs));
        check_equal(backend_call_integer(session, "__int__"), 1);

      elsif run("test_arguments_carried_to_another_process") then
        send_arguments;
        wait until received for 1 ns;
        check_true(received, "The receiver got the arguments");
      end if;
    end loop;

    test_runner_cleanup(runner);
  end process;

  receiving : process
    constant session : python_session_t := new_vc_session(get_id("tb_vc_python:receiver_backend"));
    variable msg : msg_t;
  begin
    receive(net, receiver, msg);
    exec("from awesome_vunit_vcs.common.vunit_bridge import decode_text", session);
    exec(
      "def collect(name, port, message):" & LF &
      "    return f'{name}|{port}|{decode_text(message)}'" & LF &
      "vc = type('Receiver', (), {'collect': staticmethod(collect)})",
      session
    );
    check_equal(
      backend_call_string(session, "collect", pop_arg(msg)),
      "plain|1234|it's ""quoted"" \ here" & LF & "and on a new line"
    );
    received <= true;
    wait;
  end process;

  test_runner_watchdog(runner, 10 ms);
end architecture;
