-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Property-based testing with Hypothesis, driven from VHDL.
--
-- A property is a Python function returning a Hypothesis strategy. The
-- testbench loops over the examples Hypothesis draws, simulates the design with
-- each of them and reports the verdict. Hypothesis shrinks a failure to a
-- minimal counterexample by running more examples through the same loop:
--
-- .. code-block:: vhdl
--
--    constant prop : property_t := new_property("my_strategies:payloads",
--      seed => get_seed(runner_cfg), output_path => output_path(runner_cfg));
--    ...
--    while next_example(prop) loop
--      reset_dut;
--      send(get_integer_vector(prop));
--      wait until done = '1' for example_budget(100 ns, 10 ns, get_length(prop));
--      report_example(prop, passed => done = '1' and result = expected, timed_out => done /= '1');
--    end loop;
--    check_property(prop);
--
-- Examples must be independent: reset the design, and any verification
-- component with state, before each example. Hypothesis reports a property as
-- flaky when an example fails once and passes when repeated.

library ieee;
use ieee.std_logic_1164.all;

library vunit_lib;
context vunit_lib.vunit_context;
use vunit_lib.integer_array_pkg.all;
use vunit_lib.vc_pkg.enumerate;

library python_bridge;
context python_bridge.python_context;

use work.vcs_python_pkg.all;

package property_pkg is
  -- A property under test. Create it with :vhdl:`property_pkg.new_property`.
  type property_t is record
    -- Private
    p_id : id_t;
    p_logger : logger_t;
    p_checker : checker_t;
    p_session : python_session_t;
  end record;

  -- Create a property.
  --
  -- ``strategy`` is ``"package.module:function"``, a Python function returning a
  -- Hypothesis strategy; ``arguments`` are keyword arguments for it as Python
  -- literals, for example ``"max_length=64"``. ``search_path`` is added to the
  -- Python module search path so the module can be imported.
  --
  -- ``max_examples`` is the number of examples Hypothesis generates, not
  -- counting the ones it runs while shrinking. Pass ``get_seed(runner_cfg)`` as
  -- ``seed`` to make the examples follow VUnit's seed, and
  -- ``output_path(runner_cfg)`` as ``output_path`` to journal each example
  -- before it runs and to replay the smallest failure first on the next run.
  --
  -- A null ``id`` becomes ``awesome_vunit_vcs:property:<n>``; a null ``logger``
  -- the logger of the id and a null ``checker`` a checker on that logger.
  impure function new_property(
    strategy : string;
    arguments : string := "";
    max_examples : positive := 100;
    seed : string := "";
    output_path : string := "";
    search_path : string := "";
    id : id_t := null_id;
    logger : logger_t := null_logger;
    checker : checker_t := null_checker
  ) return property_t;

  -- The id, logger and checker of a property.
  impure function get_id(prop : property_t) return id_t;
  impure function get_logger(prop : property_t) return logger_t;
  impure function get_checker(prop : property_t) return checker_t;

  -- Wait for the next example Hypothesis wants to run. False when the property
  -- has ended; then call :vhdl:`property_pkg.check_property`.
  impure function next_example(prop : property_t) return boolean;

  ----------------------------------------------------------------------------
  -- Example fields
  ----------------------------------------------------------------------------
  -- A ``path`` names a value inside the example: fields of dicts and dataclasses
  -- by name, items of lists, tuples and bytes by an index in parentheses,
  -- joined by dots, as in ``"frames(2).payload"``. The empty path is the whole
  -- example. A wrong path fails with a message naming the fields that exist.

  -- An integer at ``path``.
  impure function get_integer(prop : property_t; path : string := "") return integer;
  -- A boolean at ``path``.
  impure function get_boolean(prop : property_t; path : string := "") return boolean;
  -- A string at ``path``.
  impure function get_string(prop : property_t; path : string := "") return string;
  -- The integers of a list, tuple or bytes at ``path``, indexed from 0.
  impure function get_integer_vector(prop : property_t; path : string := "") return integer_vector;
  -- An unsigned integer, or bytes read big-endian, at ``path`` as ``length`` bits.
  impure function get_unsigned(prop : property_t; path : string; length : positive) return std_ulogic_vector;
  -- The number of items of a list, tuple or bytes at ``path``.
  impure function get_length(prop : property_t; path : string := "") return natural;
  -- Whether ``path`` exists and is not None, for optional fields.
  impure function has_field(prop : property_t; path : string) return boolean;

  ----------------------------------------------------------------------------
  -- Verdicts
  ----------------------------------------------------------------------------

  -- A simulation-time budget for an example: ``base`` plus ``per_item`` for each
  -- of ``items``.
  function example_budget(base : delay_length; per_item : delay_length; items : natural) return delay_length;

  -- Report the verdict on the current example.
  --
  -- ``timed_out`` means the design did not finish within its budget, which
  -- Hypothesis treats as a different failure than wrong behavior. After a
  -- lockup, reset the design and pass whether it works again as
  -- ``recovered``; false ends the property as aborted, keeping the smallest
  -- failing example found so far.
  procedure report_example(
    prop : property_t;
    passed : boolean;
    timed_out : boolean := false;
    recovered : boolean := true;
    msg : string := ""
  );

  -- Report a score of the current example before its verdict. Hypothesis steers
  -- the generation towards examples with higher scores for each ``name``
  -- (``hypothesis.target``); report each name at most once per example.
  procedure report_score(prop : property_t; name : string; value : real);

  -- ``running``, then ``passed``, ``failed``, ``flaky``, ``aborted`` or ``error``.
  impure function get_outcome(prop : property_t) return string;
  -- The number of examples run, shrinking included.
  impure function get_example_count(prop : property_t) return natural;
  -- The minimal failing example as Python shows it, empty when there is none.
  impure function get_counterexample(prop : property_t) return string;

  -- Check that the property passed. A failure logs the minimal counterexample
  -- on the checker of the property.
  procedure check_property(prop : property_t; msg : string := "");
end package;

package body property_pkg is
  impure function new_property(
    strategy : string;
    arguments : string := "";
    max_examples : positive := 100;
    seed : string := "";
    output_path : string := "";
    search_path : string := "";
    id : id_t := null_id;
    logger : logger_t := null_logger;
    checker : checker_t := null_checker
  ) return property_t is
    variable result : property_t;
  begin
    result.p_id := id;
    if id = null_id then
      result.p_id := enumerate(get_id("property", parent => get_id("awesome_vunit_vcs")));
    end if;

    result.p_logger := logger;
    if logger = null_logger then
      result.p_logger := get_logger(result.p_id);
    end if;

    result.p_checker := checker;
    if checker = null_checker then
      result.p_checker := new_checker(result.p_logger);
    end if;

    result.p_session := new_vc_session(result.p_id);
    create_backend(
      result.p_session, "awesome_vunit_vcs.common.property", "PropertyRunner",
      py_str(strategy) & ", " & py_str(arguments) & ", max_examples=" & integer'image(max_examples) &
      ", seed=" & py_str(seed) & ", output_path=" & py_str(output_path) &
      ", search_path=" & py_str(search_path) & ", name=" & py_str(full_name(result.p_id)));
    return result;
  end;

  impure function get_id(prop : property_t) return id_t is
  begin
    return prop.p_id;
  end;

  impure function get_logger(prop : property_t) return logger_t is
  begin
    return prop.p_logger;
  end;

  impure function get_checker(prop : property_t) return checker_t is
  begin
    return prop.p_checker;
  end;

  impure function next_example(prop : property_t) return boolean is
  begin
    return backend_boolean(prop.p_session, "next()");
  end;

  impure function get_integer(prop : property_t; path : string := "") return integer is
  begin
    return backend_integer(prop.p_session, "integer(" & py_str(path) & ")");
  end;

  impure function get_boolean(prop : property_t; path : string := "") return boolean is
  begin
    return backend_boolean(prop.p_session, "boolean(" & py_str(path) & ")");
  end;

  impure function get_string(prop : property_t; path : string := "") return string is
  begin
    return backend_string(prop.p_session, "string(" & py_str(path) & ")");
  end;

  impure function get_integer_vector(prop : property_t; path : string := "") return integer_vector is
    variable items : integer_array_t := backend_integer_array(prop.p_session, "vector(" & py_str(path) & ")");
    variable result : integer_vector(0 to length(items) - 1);
  begin
    for idx in result'range loop
      result(idx) := get(items, idx);
    end loop;
    deallocate(items);
    return result;
  end;

  impure function get_unsigned(prop : property_t; path : string; length : positive) return std_ulogic_vector is
    constant bits : string := backend_string(
      prop.p_session, "unsigned(" & py_str(path) & ", " & integer'image(length) & ")");
    alias bits_normalized : string(1 to bits'length) is bits;
    variable result : std_ulogic_vector(length - 1 downto 0);
  begin
    for idx in bits_normalized'range loop
      if bits_normalized(idx) = '1' then
        result(length - idx) := '1';
      else
        result(length - idx) := '0';
      end if;
    end loop;
    return result;
  end;

  impure function get_length(prop : property_t; path : string := "") return natural is
  begin
    return backend_integer(prop.p_session, "length(" & py_str(path) & ")");
  end;

  impure function has_field(prop : property_t; path : string) return boolean is
  begin
    return backend_boolean(prop.p_session, "has(" & py_str(path) & ")");
  end;

  function example_budget(base : delay_length; per_item : delay_length; items : natural) return delay_length is
  begin
    return base + items * per_item;
  end;

  procedure report_example(
    prop : property_t;
    passed : boolean;
    timed_out : boolean := false;
    recovered : boolean := true;
    msg : string := ""
  ) is
  begin
    backend_exec(
      prop.p_session,
      "report(" & py_bool(passed) & ", timed_out=" & py_bool(timed_out) & ", recovered=" & py_bool(recovered) &
      ", message=" & py_str(msg) & ")");
  end;

  procedure report_score(prop : property_t; name : string; value : real) is
  begin
    backend_exec(prop.p_session, "score(" & py_str(name) & ", " & real'image(value) & ")");
  end;

  impure function get_outcome(prop : property_t) return string is
  begin
    return backend_string(prop.p_session, "outcome");
  end;

  impure function get_example_count(prop : property_t) return natural is
  begin
    return backend_integer(prop.p_session, "count");
  end;

  impure function get_counterexample(prop : property_t) return string is
  begin
    return backend_string(prop.p_session, "counterexample()");
  end;

  procedure check_property(prop : property_t; msg : string := "") is
    constant summary : string := backend_string(prop.p_session, "summary()");
  begin
    if msg = "" then
      check(prop.p_checker, get_outcome(prop) = "passed", summary);
    else
      check(prop.p_checker, get_outcome(prop) = "passed", msg & " - " & summary);
    end if;
  end;
end package body;
