-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The one VHDL package that uses the VUnit Python bridge (VUnit PR #1220).
-- Verification components go through these subprograms, so an API change in
-- the bridge is absorbed here. Its Python counterpart is
-- awesome_vunit_vcs/common/vunit_bridge.py and .../common/reports.py.
--
-- A VC backend is one Python object named vc in a session of its own. The
-- session has the identity of the VC, so Python errors are reported on the
-- logger of the VC and two VC instances never share Python state.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.python_context;
use vunit_lib.integer_array_pkg.all;

package vcs_python_pkg is
  -- Largest time between two samples of a batch; deltas are 32-bit femtoseconds
  constant max_sample_delta : time := 1000 ns;

  impure function new_vc_session(id : id_t) return python_session_t;

  -- Python literals
  function py_str(value : string) return string;
  function py_bool(value : boolean) return string;
  function py_int_list(value : integer_vector) return string;

  -- Import class_name from module_name and create vc = class_name(arguments)
  procedure create_backend(
    session : python_session_t; module_name, class_name, arguments : string
  );

  -- Run vc.<statement>, evaluate vc.<expression>
  procedure backend_exec(session : python_session_t; statement : string);
  impure function backend_integer(session : python_session_t; expression : string) return integer;
  impure function backend_boolean(session : python_session_t; expression : string) return boolean;
  impure function backend_string(session : python_session_t; expression : string) return string;
  impure function backend_integer_array(session : python_session_t; expression : string) return integer_array_t;

  -- Send a sample batch ([word, delta_fs] pairs) to vc.push. Returns the
  -- number of reports waiting.
  impure function push_samples(
    session : python_session_t; samples : integer_array_t; base_time : time
  ) return natural;

  -- Fetch the reports waiting in the backend and log them: errors as check
  -- failures on checker, the others on logger at their level
  procedure log_reports(session : python_session_t; logger : logger_t; checker : checker_t);
end package;

package body vcs_python_pkg is
  constant time_split : time := 1073741824 fs;
  constant record_separator : character := character'val(30);
  constant field_separator : character := character'val(31);

  impure function new_vc_session(id : id_t) return python_session_t is
  begin
    return new_session(id);
  end;

  function py_str(value : string) return string is
    variable result : line;
  begin
    write(result, string'("'"));
    for idx in value'range loop
      case value(idx) is
        when '\' => write(result, string'("\\"));
        when ''' => write(result, string'("\'"));
        when LF => write(result, string'("\n"));
        when CR => write(result, string'("\r"));
        when others => write(result, value(idx));
      end case;
    end loop;
    write(result, string'("'"));
    return result.all;
  end;

  function py_bool(value : boolean) return string is
  begin
    if value then
      return "True";
    end if;
    return "False";
  end;

  function py_int_list(value : integer_vector) return string is
    variable result : line;
  begin
    write(result, string'("["));
    for idx in value'range loop
      if idx /= value'left then
        write(result, string'(", "));
      end if;
      write(result, integer'image(value(idx)));
    end loop;
    write(result, string'("]"));
    return result.all;
  end;

  procedure create_backend(
    session : python_session_t; module_name, class_name, arguments : string
  ) is
  begin
    exec(
      "from " & module_name & " import " & class_name & LF &
      "vc = " & class_name & "(" & arguments & ")",
      session);
  end;

  procedure backend_exec(session : python_session_t; statement : string) is
  begin
    exec("vc." & statement, session);
  end;

  impure function backend_integer(session : python_session_t; expression : string) return integer is
  begin
    return eval_integer("vc." & expression, session);
  end;

  impure function backend_boolean(session : python_session_t; expression : string) return boolean is
  begin
    return eval_boolean("vc." & expression, session);
  end;

  impure function backend_string(session : python_session_t; expression : string) return string is
  begin
    return eval_string("vc." & expression, session);
  end;

  impure function backend_integer_array(session : python_session_t; expression : string) return integer_array_t is
  begin
    return eval_integer_array("vc." & expression, session);
  end;

  impure function push_samples(
    session : python_session_t; samples : integer_array_t; base_time : time
  ) return natural is
    constant hi : natural := base_time / time_split;
    constant lo : natural := (base_time - hi * time_split) / 1 fs;
  begin
    return call("vc.push", arg(samples), arg(hi), arg(lo), session => session);
  end;

  procedure log_reports(session : python_session_t; logger : logger_t; checker : checker_t) is
    constant reports : string := call_string("vc.take_reports", session => session);
    alias text : string(1 to reports'length) is reports;
    variable first : positive := 1;
    variable last : natural;
  begin
    while first <= text'length loop
      last := first;
      while last <= text'length and text(last) /= record_separator loop
        last := last + 1;
      end loop;
      -- text(first) is the severity code, text(first + 1) the field separator
      if last - first >= 2 and text(first + 1) = field_separator then
        case text(first) is
          when 'E' => check_failed(checker, text(first + 2 to last - 1));
          when 'F' => failure(logger, text(first + 2 to last - 1));
          when 'W' => warning(logger, text(first + 2 to last - 1));
          when 'I' => info(logger, text(first + 2 to last - 1));
          when others => debug(logger, text(first + 2 to last - 1));
        end case;
      else
        failure(logger, "Malformed report from the Python backend: " & text(first to last - 1));
      end if;
      first := last + 1;
    end loop;
  end;
end package body;
