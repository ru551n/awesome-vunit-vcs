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

use work.vc_python_pkg.all;

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
  -- Hypothesis strategy; ``arguments`` are its arguments, built with the
  -- bridge's typed ``arg`` and ``kwarg``, for example ``kwarg("max_length", 64)``. ``search_path`` is added to the
  -- Python module search path so the module can be imported.
  --
  -- ``max_examples`` is the number of examples Hypothesis generates, not
  -- counting the ones it runs while shrinking or the pinned and saved examples
  -- it tries first; for a stateful property it is the number of step
  -- sequences. 0, the default, uses the profile's budget: 100 examples, or ten
  -- times as many with ``AWESOME_VUNIT_VCS_PROPERTY_PROFILE=long``. A number you
  -- give is used in every profile. Pass ``get_seed(runner_cfg)`` as
  -- ``seed`` to make the examples follow VUnit's seed, and
  -- ``output_path(runner_cfg)`` as ``output_path`` to journal each example
  -- before it runs and to replay the smallest failure first on the next run.
  --
  -- A null ``id`` becomes ``awesome_vunit_vcs:property:<n>``; a null ``logger``
  -- the logger of the id and a null ``checker`` a checker on that logger.
  --
  -- When the property cannot run, because the strategy function raises, the
  -- strategy raises while drawing an example, the arguments are invalid or
  -- Hypothesis is not installed, one failure is logged on the property's logger
  -- and the property ends: :vhdl:`property_pkg.next_example` returns false and
  -- :vhdl:`property_pkg.get_outcome` is ``error``. For an exception in your code the
  -- first line of the failure is ``module:function raised Type: message (file:line)``,
  -- followed by the traceback lines in your code. To expect it, pass your own
  -- ``logger`` and ``disable_stop(logger, failure)`` before creating the property.
  impure function new_property(
    strategy : string;
    arguments : arg_t := null_arg;
    max_examples : natural := 0;
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
  -- Stateful properties
  ----------------------------------------------------------------------------
  -- When the strategy function returns a ``RuleBasedStateMachine`` subclass, each
  -- example is one step: the rule that runs it, with the arguments of the rule
  -- as fields. Every sequence of steps starts with the rule ``"start"``, when
  -- the design is reset.

  -- The rule of the current step.
  impure function get_rule(prop : property_t) return string;

  -- Report that the current step ran, returning ``value`` to the rule.
  procedure report_step(prop : property_t; value : integer := 0);

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

  -- How the property ended: ``running`` until ``next_example`` returns false, then
  -- ``passed``; ``failed``, a counterexample was found; ``flaky``, an example failed
  -- once and then passed; ``aborted``, the design did not recover after a lockup; or
  -- ``error``, the property could not run, such as an exception in the strategy
  -- or an invalid argument, already logged as a failure on the property's logger.
  impure function get_outcome(prop : property_t) return string;
  -- The number of examples run, shrinking included. For a stateful property each
  -- step is one example, the ``"start"`` steps included.
  impure function get_example_count(prop : property_t) return natural;
  -- The minimal failing example as Python shows it, empty when there is none.
  impure function get_counterexample(prop : property_t) return string;

  -- Check that the property passed. A failure logs the minimal counterexample
  -- on the checker of the property. A property that ended with ``error`` was
  -- already logged as a failure and is not reported again.
  procedure check_property(prop : property_t; msg : string := "");
end package;

package body property_pkg is
  -- Log the error that ended a property, once, as a failure on its logger
  procedure report_property_error(prop : property_t) is
    constant detail : string := backend_call_string(prop.p_session, "take_error");
  begin
    if detail /= "" then
      failure(prop.p_logger, detail);
    end if;
  end;

  impure function new_property(
    strategy : string;
    arguments : arg_t := null_arg;
    max_examples : natural := 0;
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

    result.p_session := new_vc_session(result.p_id, result.p_logger);
    create_backend(
      result.p_session, "awesome_vunit_vcs.common.property", "PropertyRunner",
      arg(strategy) & kwarg("max_examples", max_examples) & kwarg_text("seed", seed) &
      kwarg_text("output_path", output_path) & kwarg_text("search_path", search_path) &
      kwarg("name", full_name(result.p_id)) & kwarg("start", false)
    );
    -- The strategy's own arguments are given separately, so they never collide with the runner's
    backend_call(result.p_session, "start", arguments);
    report_property_error(result);
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
    constant more : boolean := backend_call_boolean(prop.p_session, "next");
  begin
    if not more then
      report_property_error(prop);
    end if;
    return more;
  end;

  impure function get_integer(prop : property_t; path : string := "") return integer is
  begin
    return backend_call_integer(prop.p_session, "integer", arg(path));
  end;

  impure function get_boolean(prop : property_t; path : string := "") return boolean is
  begin
    return backend_call_boolean(prop.p_session, "boolean", arg(path));
  end;

  impure function get_string(prop : property_t; path : string := "") return string is
  begin
    return backend_call_string(prop.p_session, "string", arg(path));
  end;

  impure function get_integer_vector(prop : property_t; path : string := "") return integer_vector is
    variable items : integer_array_t := backend_call_integer_array(prop.p_session, "vector", arg(path));
    variable result : integer_vector(0 to length(items) - 1);
  begin
    for idx in result'range loop
      result(idx) := get(items, idx);
    end loop;
    deallocate(items);
    return result;
  end;

  impure function get_unsigned(prop : property_t; path : string; length : positive) return std_ulogic_vector is
    constant bits : string := backend_call_string(prop.p_session, "unsigned", arg(path) & arg(length));
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
    return backend_call_integer(prop.p_session, "length", arg(path));
  end;

  impure function has_field(prop : property_t; path : string) return boolean is
  begin
    return backend_call_boolean(prop.p_session, "has", arg(path));
  end;

  impure function get_rule(prop : property_t) return string is
  begin
    return get_string(prop, "rule");
  end;

  procedure report_step(prop : property_t; value : integer := 0) is
  begin
    backend_call(prop.p_session, "report", arg(true) & kwarg("value", value));
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
    backend_call(
      prop.p_session, "report",
      arg(passed) & kwarg("timed_out", timed_out) & kwarg("recovered", recovered) & kwarg_text("message", msg)
    );
  end;

  procedure report_score(prop : property_t; name : string; value : real) is
  begin
    backend_call(prop.p_session, "score", arg(name) & arg(value));
  end;

  impure function get_outcome(prop : property_t) return string is
  begin
    return backend_call_string(prop.p_session, "get_outcome");
  end;

  impure function get_example_count(prop : property_t) return natural is
  begin
    return backend_call_integer(prop.p_session, "get_count");
  end;

  impure function get_counterexample(prop : property_t) return string is
  begin
    return backend_call_string(prop.p_session, "counterexample");
  end;

  procedure check_property(prop : property_t; msg : string := "") is
    constant summary : string := backend_call_string(prop.p_session, "summary");
  begin
    report_property_error(prop);
    if get_outcome(prop) = "error" then
      return;  -- logged once as a failure when the property ended
    end if;
    if msg = "" then
      check(prop.p_checker, get_outcome(prop) = "passed", summary);
    else
      check(prop.p_checker, get_outcome(prop) = "passed", msg & " - " & summary);
    end if;
  end;
end package body;
