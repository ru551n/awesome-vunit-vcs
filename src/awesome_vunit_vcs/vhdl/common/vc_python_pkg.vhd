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
-- Backends are called with the typed arguments of the bridge, never with
-- Python source text: ``arg`` and ``kwarg`` for integers, reals, booleans,
-- identifier-like strings and vectors, combined with ``&``, plus the helpers
-- below for times and for free text such as messages and file names.
--
-- Sample batches carry what a passive VC observed to its backend: one
-- integer word per sample, each with its time. A VC calls record_sample for
-- every sample it wants the backend to see and flush_samples when the backend
-- must be up to date. The word layout belongs to the VC family; several words
-- may be recorded at the same time (one per lane of a wide interface).

library ieee;
  use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
  use vunit_lib.integer_array_pkg.all;

library python_bridge;
context python_bridge.python_context;

package vc_python_pkg is

  -- The Python session of a VC, identified by the id of the VC. Two VCs with the same id would
  -- share their Python state, so a second session for an id is a failure on logger, or on the
  -- logger of the id when logger is null_logger.
  impure function new_vc_session (id : id_t; logger : logger_t := null_logger) return python_session_t;

  -- Import ``class_name`` from ``module_name`` and create the backend, the object ``vc`` of the
  -- session: ``vc = class_name(args)``.
  procedure create_backend (session : python_session_t; module_name, class_name : string; args : arg_t := null_arg);

  -- Call ``vc.<method>(args)``, ignoring or returning its result.
  procedure backend_call (session : python_session_t; method : string; args : arg_t := null_arg);
  impure function backend_call_integer (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return integer;
  impure function backend_call_boolean (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return boolean;
  impure function backend_call_string (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return string;
  impure function backend_call_integer_array (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return integer_array_t;

  -- A simulation time as an argument, of any size; Python decodes it with
  -- ``awesome_vunit_vcs.common.vunit_bridge.decode_time_fs``.
  function arg_time (value : time) return arg_t;
  function kwarg_time (name : string; value : time) return arg_t;

  -- Any text as an argument, including quotes, backslashes and line breaks, for
  -- messages and file names; Python decodes it with
  -- ``awesome_vunit_vcs.common.vunit_bridge.decode_text``. The bridge's own
  -- ``arg(string)`` is meant for identifier-like strings.
  function arg_text (value : string) return arg_t;
  function kwarg_text (name : string; value : string) return arg_t;

  -- Carry arguments in a com message, for a VC that calls its backend with
  -- arguments a user gave to a procedure
  procedure push_arg (msg : msg_t; value : arg_t);
  impure function pop_arg (msg : msg_t) return arg_t;

  -- Fetch the reports waiting in the backend, ``vc.take_reports(args)``, and
  -- log them: errors as check failures on checker, the others on logger at
  -- their level
  procedure log_reports (session : python_session_t; logger : logger_t; checker : checker_t; args : arg_t := null_arg);

  -- The samples a passive VC recorded and has not sent to its backend yet,
  -- created with :vhdl:`vc_python_pkg.new_sample_batch`
  type sample_batch_t is record
    p_session      : python_session_t;
    p_logger       : logger_t;
    p_checker      : checker_t;
    -- [word, delta] pairs
    p_samples      : integer_array_t;
    p_batch_length : positive;
    p_delta_unit   : time;
    p_base_time    : time;
    -- Time of the latest sample, rounded down to the delta unit
    p_last_time    : time;
  end record;

  -- The samples of a VC. They are sent to vc.push(samples, base_time,
  -- delta_unit), which returns the number of reports waiting, once
  -- batch_length samples are recorded. Sample times are rounded down to
  -- delta_unit, which must not exceed 1 us; a batch spans up to
  -- delta_unit * integer'high between two samples.
  impure function new_sample_batch (
    session : python_session_t;
    logger : logger_t;
    checker : checker_t;
    batch_length : positive;
    delta_unit : time := 1 ps
  ) return sample_batch_t;

  -- Record word at the current simulation time
  procedure record_sample (variable batch : inout sample_batch_t; word : integer);

  -- Send the recorded samples to the backend and log the reports it has
  procedure flush_samples (variable batch : inout sample_batch_t);

  -- The number of samples recorded and not sent yet
  impure function num_samples (batch : sample_batch_t) return natural;
end package;

package body vc_python_pkg is

  constant time_split : time := 1073741824 fs;
  constant record_separator : character := character'val(30);
  constant field_separator : character := character'val(31);

  -- The full names of the ids with a Python session
  constant vc_sessions : dict_t := new_dict;

  impure function new_vc_session (id : id_t; logger : logger_t := null_logger) return python_session_t is

    constant name : string := full_name(id);
  begin

    if has_key(vc_sessions, name) then
      if logger = null_logger then
        failure(
          get_logger(id),
          "Two verification components have the id " & name & " and would share one Python backend"
        );
      else
        failure(logger, "Two verification components have the id " & name & " and would share one Python backend");
      end if;
    else
      set_string(vc_sessions, name, "");
    end if;
    return new_session(id);
  end;

  procedure create_backend (session : python_session_t; module_name, class_name : string; args : arg_t := null_arg) is
  begin

    -- Module and class are names, not data; the arguments are the bridge's typed call
    exec("from " & module_name & " import " & class_name, session);
    exec("vc = " & to_call_str(class_name, args), session);
  end;

  procedure backend_call (session : python_session_t; method : string; args : arg_t := null_arg) is
  begin

    call("vc." & method, args, session => session);
  end;

  impure function backend_call_integer (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return integer is
  begin

    return call_integer_w_arg("vc." & method, args, session => session);
  end;

  impure function backend_call_boolean (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return boolean is
  begin

    return call_boolean("vc." & method, args, session => session);
  end;

  impure function backend_call_string (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return string is
  begin

    return call_string("vc." & method, args, session => session);
  end;

  impure function backend_call_integer_array (
    session : python_session_t;
    method : string;
    args : arg_t := null_arg
  ) return integer_array_t is
  begin

    return call_integer_array("vc." & method, args, session => session);
  end;

  function time_halves (value : time) return integer_vector is

    constant hi : natural := value / time_split;
    constant lo : natural := (value - hi * time_split) / 1 fs;
  begin

    return (hi, lo);
  end;

  function arg_time (value : time) return arg_t is
  begin

    return arg(time_halves(value));
  end;

  function kwarg_time (name : string; value : time) return arg_t is
  begin

    return kwarg(name, time_halves(value));
  end;

  function character_codes (value : string) return integer_vector is

    alias normalized : string(1 to value'length) is value;
    variable result : integer_vector(1 to value'length);
  begin

    for idx in normalized'range loop

      result(idx) := character'pos(normalized(idx));
    end loop;

    return result;
  end;

  function arg_text (value : string) return arg_t is
  begin

    return arg(character_codes(value));
  end;

  function kwarg_text (name : string; value : string) return arg_t is
  begin

    return kwarg(name, character_codes(value));
  end;

  procedure push_arg (msg : msg_t; value : arg_t) is
  begin

    push_string(msg, value.name);
    push_string(msg, value.value);
  end;

  impure function pop_arg (msg : msg_t) return arg_t is

    constant name : string := pop_string(msg);
    constant value : string := pop_string(msg);
  begin

    return (name => name, value => value);
  end;

  procedure log_reports (
    session : python_session_t;
    logger : logger_t;
    checker : checker_t;
    args : arg_t := null_arg
  ) is

    constant reports : string := backend_call_string(session, "take_reports", args);
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
          when 'E' =>

            check_failed(checker, text(first + 2 to last - 1));
          when 'F' =>

            failure(logger, text(first + 2 to last - 1));
          when 'W' =>

            warning(logger, text(first + 2 to last - 1));
          when 'I' =>

            info(logger, text(first + 2 to last - 1));
          when others =>

            debug(logger, text(first + 2 to last - 1));
        end case;

      else
        failure(logger, "Malformed report from the Python backend: " & text(first to last - 1));
      end if;
      first := last + 1;
    end loop;

  end;

  impure function new_sample_batch (
    session : python_session_t;
    logger : logger_t;
    checker : checker_t;
    batch_length : positive;
    delta_unit : time := 1 ps
  ) return sample_batch_t is
  begin

    assert delta_unit > 0 fs and delta_unit <= 1 us
      report "The delta unit of a sample batch must be in (0 fs, 1 us]"
      severity failure;
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

  impure function num_samples (batch : sample_batch_t) return natural is
  begin

    return length(batch.p_samples) / 2;
  end;

  procedure record_sample (variable batch : inout sample_batch_t; word : integer) is

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

  procedure flush_samples (variable batch : inout sample_batch_t) is

    variable num_reports : natural;
  begin

    if num_samples(batch) = 0 then
      return;
    end if;

    num_reports := backend_call_integer(
      batch.p_session,
      "push",
      arg(batch.p_samples) & arg_time(batch.p_base_time) & arg_time(batch.p_delta_unit)
    );
    reshape(batch.p_samples, 0);

    if num_reports > 0 then
      log_reports(batch.p_session, batch.p_logger, batch.p_checker);
    end if;
  end;

end package body;
