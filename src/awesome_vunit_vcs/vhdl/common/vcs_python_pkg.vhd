-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- The one VHDL package that uses the Python bridge (the vunit-python-bridge
-- VUnit package, library python_bridge).
-- Verification components go through these subprograms, so an API change in
-- the bridge is absorbed here. Its Python counterpart is
-- awesome_vunit_vcs/common/vunit_bridge.py and .../common/reports.py.
--
-- A VC backend is one Python object named vc in a session of its own. The
-- session has the identity of the VC, so Python errors are reported on the
-- logger of the VC and two VC instances never share Python state.
--
-- Sample batches carry what a passive VC observed to its backend: one
-- integer word per sample, each with its time. A VC calls record_sample for
-- every sample it wants the backend to see and flush_samples when the backend
-- must be up to date. The word layout belongs to the VC family; several words
-- may be recorded at the same time (one per lane of a wide interface).

library ieee;
use ieee.std_logic_1164.all;

use std.textio.all;

library vunit_lib;
context vunit_lib.vunit_context;
use vunit_lib.integer_array_pkg.all;

library python_bridge;
context python_bridge.python_context;

package vcs_python_pkg is
  -- The Python session of the VC with id, whose backend is the object vc in it
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

  -- Fetch the reports waiting in the backend and log them: errors as check
  -- failures on checker, the others on logger at their level
  procedure log_reports(session : python_session_t; logger : logger_t; checker : checker_t);

  -- The samples a passive VC recorded and has not sent to its backend yet,
  -- created with :vhdl:`vcs_python_pkg.new_sample_batch`
  type sample_batch_t is record
    p_session : python_session_t;
    p_logger : logger_t;
    p_checker : checker_t;
    -- [word, delta] pairs
    p_samples : integer_array_t;
    p_batch_length : positive;
    p_delta_unit : time;
    p_base_time : time;
    -- Time of the latest sample, rounded down to the delta unit
    p_last_time : time;
  end record;

  -- The samples of a VC. They are sent to vc.push(samples, base_hi, base_lo,
  -- delta_unit_fs), which returns the number of reports waiting, once
  -- batch_length samples are recorded. Sample times are rounded down to
  -- delta_unit, which must not exceed 1 us; a batch spans up to
  -- delta_unit * integer'high between two samples.
  impure function new_sample_batch(
    session : python_session_t;
    logger : logger_t;
    checker : checker_t;
    batch_length : positive;
    delta_unit : time := 1 ps
  ) return sample_batch_t;

  -- Record word at the current simulation time
  procedure record_sample(variable batch : inout sample_batch_t; word : integer);

  -- Send the recorded samples to the backend and log the reports it has
  procedure flush_samples(variable batch : inout sample_batch_t);

  -- The number of samples recorded and not sent yet
  impure function num_samples(batch : sample_batch_t) return natural;
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

  impure function new_sample_batch(
    session : python_session_t;
    logger : logger_t;
    checker : checker_t;
    batch_length : positive;
    delta_unit : time := 1 ps
  ) return sample_batch_t is
  begin
    assert delta_unit > 0 fs and delta_unit <= 1 us
      report "The delta unit of a sample batch must be in (0 fs, 1 us]" severity failure;
    return (
      p_session => session,
      p_logger => logger,
      p_checker => checker,
      p_samples => new_1d(length => 0, bit_width => 32, is_signed => true),
      p_batch_length => batch_length,
      p_delta_unit => delta_unit,
      p_base_time => 0 fs,
      p_last_time => 0 fs
    );
  end;

  impure function num_samples(batch : sample_batch_t) return natural is
  begin
    return length(batch.p_samples) / 2;
  end;

  procedure record_sample(variable batch : inout sample_batch_t; word : integer) is
    variable delta : natural;
  begin
    if num_samples(batch) > 0 and now - batch.p_last_time > batch.p_delta_unit * integer'high then
      flush_samples(batch);
    end if;

    if num_samples(batch) = 0 then
      batch.p_base_time := now;
      batch.p_last_time := now;
      delta := 0;
    else
      delta := (now - batch.p_last_time) / batch.p_delta_unit;
      batch.p_last_time := batch.p_last_time + delta * batch.p_delta_unit;
    end if;

    append(batch.p_samples, word);
    append(batch.p_samples, delta);

    if num_samples(batch) >= batch.p_batch_length then
      flush_samples(batch);
    end if;
  end;

  procedure flush_samples(variable batch : inout sample_batch_t) is
    constant hi : natural := batch.p_base_time / time_split;
    constant lo : natural := (batch.p_base_time - hi * time_split) / 1 fs;
    variable num_reports : natural;
  begin
    if num_samples(batch) = 0 then
      return;
    end if;

    num_reports := call(
      "vc.push", arg(batch.p_samples), arg(hi), arg(lo), arg(batch.p_delta_unit / 1 fs),
      session => batch.p_session
    );
    reshape(batch.p_samples, 0);

    if num_reports > 0 then
      log_reports(batch.p_session, batch.p_logger, batch.p_checker);
    end if;
  end;
end package body;
