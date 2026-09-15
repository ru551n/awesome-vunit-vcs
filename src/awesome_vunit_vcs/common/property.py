"""
Property-based testing of HDL designs with Hypothesis, driven from VHDL.

A property is a user function returning a Hypothesis strategy. VHDL creates a
:class:`PropertyRunner` for it through ``property_pkg``, then loops: take the
next example, simulate the design with it, report whether it passed. Hypothesis
decides which examples to try, including the shrinking of a failure to a
minimal counterexample, so the loop runs as many examples as Hypothesis asks
for.

How it works: the ``@given`` test runs in a background thread. Its body hands
each drawn example to VHDL and blocks until VHDL reports the verdict. The
Python bridge holds the GIL only while a call from VHDL is running, so the
thread makes progress between those calls.

A strategy function may instead return a
:class:`hypothesis.stateful.RuleBasedStateMachine` subclass. Its rules run
steps in VHDL with :func:`step`, and Hypothesis shrinks a failure to the
shortest failing sequence of steps.

Hypothesis is imported only when a runner is created; the package does not
depend on it.
"""

from __future__ import annotations

import ast
import builtins
import dataclasses
import enum
import hashlib
import inspect
import json
import os
import queue
import re
import sys
import threading
from collections.abc import Mapping, Sequence
from typing import Any

import numpy as np
import numpy.typing as npt

from .vunit_bridge import decode_text

__all__ = [
    "DEFAULT_MAX_EXAMPLES",
    "PROFILE_VARIABLE",
    "START_RULE",
    "ExampleFailed",
    "ExampleTimeout",
    "PropertyError",
    "PropertyRunner",
    "pin",
    "step",
]

#: How long, in wall-clock seconds, VHDL waits for Hypothesis to produce the next
#: example before giving up. Simulation time is never limited from Python.
DEFAULT_TIMEOUT_S = 3600.0

#: The rule of the step a stateful property runs before each sequence of steps:
#: VHDL resets the design when it gets it.
START_RULE = "start"

#: The environment variable selecting the default example budget: ``quick`` (the
#: default) runs :data:`DEFAULT_MAX_EXAMPLES` examples, ``long`` ten times as
#: many, for example in a nightly run. A property given an explicit
#: ``max_examples`` runs that many in every profile.
PROFILE_VARIABLE = "AWESOME_VUNIT_VCS_PROPERTY_PROFILE"
_PROFILE_SCALES = {"quick": 1, "long": 10}

#: The number of examples a property runs in the ``quick`` profile when it is not
#: given ``max_examples``.
DEFAULT_MAX_EXAMPLES = 100

_driver = threading.local()

# Hypothesis raises an exception group for several distinct failures; the builtin
# exists from Python 3.11 (older Pythons get the exceptiongroup backport's type).
_EXCEPTION_GROUPS: tuple[type[BaseException], ...] = tuple(
    group for group in (getattr(builtins, "BaseExceptionGroup", None),) if group is not None
)


class PropertyError(ValueError):
    """A property cannot be created or an example field cannot be read."""


class ExampleFailed(AssertionError):
    """VHDL reported that the design behaved wrongly on the example."""


class ExampleTimeout(Exception):
    """VHDL reported that the design locked up on the example."""


#: What ending a property with failing examples raises
_EXAMPLE_FAILURES: tuple[type[BaseException], ...] = (AssertionError, ExampleTimeout, *_EXCEPTION_GROUPS)


class PropertyAborted(BaseException):
    """
    The design did not recover from a lockup.

    Not an :class:`Exception`, so Hypothesis stops at once instead of shrinking.
    """


def pin(*examples: Any) -> Any:
    """
    Always run ``examples`` first, like :func:`hypothesis.example`.

    Decorate the strategy function with it to keep a counterexample found once as
    a regression::

        @pin([255, 0])
        def byte_stream():
            return st.lists(st.integers(0, 255))
    """

    def decorate(function: Any) -> Any:
        function.__property_examples__ = (*getattr(function, "__property_examples__", ()), *examples)
        return function

    return decorate


def step(rule: str, **fields: Any) -> int:
    """
    Run one step of a stateful property in VHDL and return the value VHDL reports.

    Call it from the rules of a :class:`hypothesis.stateful.RuleBasedStateMachine`.
    VHDL reads ``rule`` with ``get_rule`` and the fields by name, and reports
    with ``report_step``.
    """
    runner = getattr(_driver, "runner", None)
    if runner is None:
        raise PropertyError("step() can only be called from the rules of a property run from VHDL")
    return int(runner.run_example({"rule": rule, **fields}))


class PropertyRunner:
    """
    Run a Hypothesis property one example at a time for VHDL.

    Args:
        strategy: ``"package.module:function"`` naming a function that returns a
            Hypothesis strategy. Each drawn value is one example.
        arguments: Keyword arguments for the function, for example
            ``{"max_length": 64}``.
        max_examples: The number of examples Hypothesis generates, not counting
            the ones it runs while shrinking or the pinned and saved examples it
            tries first. For a stateful property it is the number of step
            sequences. ``None`` or 0 uses the profile's budget
            (:data:`DEFAULT_MAX_EXAMPLES` in ``quick``, ten times as many in
            ``long``); an explicit number is used in every profile.
        seed: The seed of the example generation, for example VUnit's
            ``get_seed(runner_cfg)``. The same seed gives the same examples. An
            empty seed lets Hypothesis choose.
        output_path: The VUnit output path of the test. When given, the example
            about to be run is written to ``property_journal_<name>.jsonl``
            there before VHDL gets it, and the smallest failure is saved next to
            the output path, which VUnit clears on every run, and replayed first
            the next time.
        search_path: A directory added to ``sys.path`` so the strategy module
            can be imported.
        name: The name of the property, used in file names; VHDL passes the
            full name of the property's id.
        phases: Comma-separated Hypothesis phases to run, for example
            ``"explicit,generate"`` to skip shrinking. Empty runs all phases.
        timeout_s: Wall-clock seconds to wait for Hypothesis to produce an example.
        start: Start the property at once with ``arguments``. VHDL passes False
            and calls :meth:`start` with the strategy's arguments, so they never
            collide with the arguments of the runner.

    Raises:
        PropertyError: Hypothesis is not installed, or the strategy, arguments or
            phases are invalid.
    """

    def __init__(
        self,
        strategy: str,
        arguments: Mapping[str, Any] | None = None,
        *,
        max_examples: int | None = None,
        seed: str | Sequence[int] = "",
        output_path: str | Sequence[int] = "",
        search_path: str | Sequence[int] = "",
        name: str = "property",
        phases: str = "",
        timeout_s: float = DEFAULT_TIMEOUT_S,
        start: bool = True,
    ) -> None:
        self._strategy = strategy
        self._max_examples = max_examples
        self._seed = decode_text(seed)
        self._output_path = decode_text(output_path)
        self._search_path = decode_text(search_path)
        self._name = name
        self._phases = phases
        self._timeout_s = timeout_s
        self._started = False
        self.count = 0
        """The number of examples VHDL has been given."""
        self.outcome = "running"
        """``running``, then ``passed``, ``failed``, ``flaky``, ``aborted`` or ``error``."""
        self.detail = ""
        """What Hypothesis reported when the property ended."""
        # The state next() and summary() need, also when starting fails
        self._stateful = False
        self._examples: queue.Queue[tuple[str, Any]] = queue.Queue()
        self._verdicts: queue.Queue[tuple[str, str, float]] = queue.Queue()
        self._journal = ""
        self._failures_file = ""
        self._steps: list[dict[str, Any]] = []
        self._current: Any = None
        self._has_current = False
        self._cache: dict[str, Any] = {}
        self._failures: list[tuple[str, str, str]] = []
        self._error_taken = False
        if start:
            self.start(**(arguments or {}))
            if self.outcome == "error":
                raise PropertyError(self.detail)

    def start(self, *args: Any, **kwargs: Any) -> None:
        """
        Load the strategy function with its arguments and start generating examples.

        When that fails, because Hypothesis is not installed, the strategy function
        raises or the strategy, arguments or phases are invalid, the property ends at
        once with the outcome ``error`` and :attr:`detail` saying why, first line
        ``module:function raised Type: message (file:line)`` for an exception in the
        user's code.

        Raises:
            PropertyError: The property was already started.
        """
        if self._started:
            raise PropertyError("The property is already started")
        self._started = True
        try:
            self._launch(args, kwargs)
        except Exception as exc:
            self._finish("error", _error_detail(self._strategy, exc))

    def take_error(self) -> str:
        """
        The :attr:`detail` of a property that ended with an error, once; an empty string
        otherwise. VHDL logs it as one failure.
        """
        if self.outcome != "error" or self._error_taken:
            return ""
        self._error_taken = True
        return self.detail

    def _launch(self, args: tuple[Any, ...], kwargs: Mapping[str, Any]) -> None:
        strategy, max_examples, seed, name = self._strategy, self._max_examples, self._seed, self._name
        output_path, search_path, phases = self._output_path, self._search_path, self._phases
        try:
            import hypothesis
        except ImportError:
            raise PropertyError(
                "Property-based testing needs Hypothesis, which is not installed: pip install hypothesis"
            ) from None

        if search_path and search_path not in sys.path:
            sys.path.insert(0, search_path)
        target, pins = _load_property(strategy, args, kwargs)
        self._stateful = isinstance(target, type)

        self._journal, self._failures_file = _files(output_path, name)
        if self._stateful:
            self._failures_file = ""  # Hypothesis cannot replay a step sequence as an example

        settings = hypothesis.settings(
            max_examples=max_examples or DEFAULT_MAX_EXAMPLES * _profile_scale(),
            deadline=None,
            suppress_health_check=list(hypothesis.HealthCheck),
            phases=_phases(hypothesis, phases),
            print_blob=False,
            database=None,
        )
        hashed_seed = int.from_bytes(hashlib.sha256(seed.encode()).digest()[:8], "big")
        test: Any
        if self._stateful:
            # The stateful driver: every sequence starts with the start step, then
            # the rules of the machine run their steps through step().
            from hypothesis.stateful import run_state_machine_as_test

            def new_machine() -> Any:
                self._steps = []
                self.run_example({"rule": START_RULE})
                return target()

            if seed:
                new_machine = hypothesis.seed(hashed_seed)(new_machine)

            def test() -> None:
                run_state_machine_as_test(new_machine, settings=settings)  # type: ignore[no-untyped-call]

        else:
            # The @given driver: its body runs each drawn example in VHDL.
            def body(example: Any) -> None:
                self.run_example(example)

            test = hypothesis.given(target)(body)  # type: ignore[no-untyped-call]
            for value in (*pins, *self._saved_failures()):
                test = hypothesis.example(value)(test)
            test = settings(test)
            if seed:
                # @seed turns Hypothesis's own example database off (hypothesis/core.py,
                # seed()), which is why failures are saved and replayed by this class.
                test = hypothesis.seed(hashed_seed)(test)

        def run() -> None:
            from hypothesis.errors import Flaky

            _driver.runner = self
            try:
                test()
            except PropertyAborted:
                self._finish("aborted", "")
            except Flaky as exc:
                self._finish("flaky", _describe(exc))
            except _EXAMPLE_FAILURES as exc:
                self._finish("failed", _describe(exc))
            except BaseException as exc:
                self._finish("error", _error_detail(strategy, exc))
            else:
                self._finish("passed", "")

        self._thread = threading.Thread(target=run, name=f"hypothesis:{name}", daemon=True)
        self._thread.start()

    # Called by VHDL
    def next(self) -> bool:
        """Wait for the next example; False when the property has ended."""
        if self._has_current:
            raise PropertyError("report_example was not called for the previous example")
        try:
            kind, value = self._examples.get(timeout=self._timeout_s)
        except queue.Empty:
            self.outcome, self.detail = "error", f"Hypothesis produced no example within {self._timeout_s} s"
            return False
        if kind != "example":
            return False
        self._current, self._has_current = value, True
        self._cache = {}
        self.count += 1
        return True

    def report(
        self,
        passed: bool,
        timed_out: bool = False,
        recovered: bool = True,
        message: str | Sequence[int] = "",
        value: int = 0,
    ) -> None:
        """
        The verdict on the current example.

        Args:
            passed: The design behaved correctly.
            timed_out: The design did not finish within its simulation-time budget.
            recovered: After a lockup, the design worked again once reset. False
                ends the property as aborted.
            message: What went wrong, shown with the counterexample.
            value: What the step of a stateful property returns to its rule.
        """
        message = decode_text(message)
        if not self._has_current:
            raise PropertyError("report_example was called without a current example")
        self._has_current = False
        if passed:
            kind = "passed"
        elif timed_out and not recovered:
            kind = "abort"
        elif timed_out:
            kind = "timeout"
        else:
            kind = "failed"
        if self._journal:
            verdict = {"passed": "passed", "failed": "failed", "timeout": "timed out", "abort": "did not recover"}[kind]
            self._append_journal({"index": self.count, "verdict": verdict, "message": message})
        self._verdicts.put((kind, message, float(value)))

    def score(self, label: str, value: float) -> None:
        """
        Report a score of the current example, forwarded to :func:`hypothesis.target`.

        Hypothesis steers generation towards examples with higher scores. Report
        each label at most once per example, before :meth:`report`.
        """
        if not self._has_current:
            raise PropertyError("report_score was called without a current example")
        self._verdicts.put(("score", label, float(value)))

    # Called in the Hypothesis thread
    def run_example(self, example: Any) -> float:
        """
        Run one example in VHDL: hand it over, wait for the verdict and raise on a failure.

        Returns the value VHDL reported with the verdict.

        This is the step every driver uses; the ``@given`` driver calls it for each
        drawn example. It must run inside a Hypothesis test, in the driver thread.
        """
        self._write_journal(example)
        if self._stateful:
            self._steps.append(example)
        self._examples.put(("example", example))
        while True:
            kind, message, value = self._verdicts.get()
            if kind != "score":
                break
            import hypothesis

            hypothesis.target(value, label=message)
        if kind == "passed":
            return value
        self._failures.append((kind, repr(example), message))
        self._save_failure(repr(example))
        if kind == "timeout":
            raise ExampleTimeout(message)
        if kind == "abort":
            raise PropertyAborted(message)
        raise ExampleFailed(message)

    # Field access. A path names a value inside the example: fields of dicts,
    # dataclasses and named tuples by name, items of lists, tuples and bytes by a
    # VHDL-style index in parentheses, joined by dots, as in "frames(2).payload".
    # The empty path is the whole example.
    def integer(self, path: str = "") -> int:
        """An integer at ``path``, in the range of a VHDL integer."""
        return _vhdl_integer(self._lookup(path), path)

    def boolean(self, path: str = "") -> bool:
        """A boolean at ``path``."""
        value = self._lookup(path)
        if not isinstance(value, bool):
            raise PropertyError(f"{path!r} is {value!r}, not a boolean")
        return value

    def string(self, path: str = "") -> str:
        """A string at ``path``; for an :class:`enum.Enum` member, its name in lower case."""
        value = self._lookup(path)
        if isinstance(value, enum.Enum):
            return value.name.lower()
        if not isinstance(value, str):
            raise PropertyError(f"{path!r} is {value!r}, not a string")
        return value

    def length(self, path: str = "") -> int:
        """The number of items of the list, tuple or bytes at ``path``."""
        return len(self._sequence(path))

    def vector(self, path: str = "") -> npt.NDArray[np.int32]:
        """
        The integers of the list, tuple or bytes at ``path``, in one bridge call.

        An int32 array, so an empty sequence still reaches VHDL as integers.
        """
        items = [_vhdl_integer(item, f"{path}({index})") for index, item in enumerate(self._sequence(path))]
        return np.array(items, dtype=np.int32)

    def has(self, path: str) -> bool:
        """Whether ``path`` exists in the example and is not None, for optional fields."""
        try:
            return self._lookup(path) is not None
        except PropertyError:
            return False

    def unsigned(self, path: str, length: int) -> str:
        """An unsigned integer or bytes (big-endian) at ``path`` as a bit string of ``length`` bits, MSB first."""
        value = self._lookup(path)
        if isinstance(value, bytes | bytearray):
            value = int.from_bytes(value, "big")
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise PropertyError(f"{path!r} is {value!r}, not an unsigned integer")
        if value >= 1 << length:
            raise PropertyError(f"{path!r} is {value}, which does not fit in {length} bits")
        return format(value, f"0{length}b")

    def get_outcome(self) -> str:
        """The :attr:`outcome`, for VHDL."""
        return self.outcome

    def get_count(self) -> int:
        """The :attr:`count`, for VHDL."""
        return self.count

    def counterexample(self) -> str:
        """The minimal failing example, or an empty string when there is none."""
        if self._stateful and self.outcome in ("failed", "flaky"):
            return "; ".join(_format_step(item) for item in self._steps if item["rule"] != START_RULE)
        if not self._failures:
            return ""
        if self.outcome in ("failed", "flaky"):
            # Hypothesis replays the minimal example last
            return self._failures[-1][1]
        return _shortlex([example for _, example, _ in self._failures])

    def summary(self) -> str:
        """A description of how the property ended, for the log."""
        examples = f"{self.count} example{'s' if self.count != 1 else ''}"
        last_message = f": {self._failures[-1][2]}" if self._failures and self._failures[-1][2] else ""
        if self._stateful and not last_message and self.detail:
            last_message = f": {self.detail.splitlines()[0]}"
        if self.outcome == "passed":
            return f"Property passed after {examples}"
        if self.outcome == "failed":
            kind = "lockup" if self._failures and self._failures[-1][0] == "timeout" else "wrong behavior"
            what = "Minimal failing steps" if self._stateful else "Minimal counterexample"
            return (
                f"Property failed after {examples}. {what} ({kind}{last_message}): {self.counterexample()}"
                f"{self._where()}"
            )
        if self.outcome == "flaky":
            return (
                f"Property is flaky after {examples}: {self.counterexample()} failed once and then passed; "
                f"the design probably keeps state between examples{self._where()}"
            )
        if self.outcome == "aborted":
            return (
                f"DUT did not recover after lockup after {examples}. "
                f"Smallest failing example so far: {self.counterexample()}{self._where()}"
            )
        if self.outcome == "running":
            return "Property has not ended: call next_example until it returns false"
        return f"Property ended with an error after {examples}: {self.detail}"

    # Internals
    def _where(self) -> str:
        """Where the saved failure and the journal are, for the failure message."""
        parts = []
        if self._failures_file and os.path.exists(self._failures_file):
            parts.append(f"Saved failure: {self._failures_file}")
        if self._journal and os.path.exists(self._journal):
            parts.append(f"Journal: {self._journal}")
        return "".join(f". {part}" for part in parts)

    def _finish(self, outcome: str, detail: str) -> None:
        self.outcome, self.detail = outcome, detail
        if outcome == "passed" and self._failures_file and os.path.exists(self._failures_file):
            os.remove(self._failures_file)
        elif outcome in ("failed", "flaky") and self._failures:
            self._save_failure(self._failures[-1][1], replace=True)
        self._examples.put(("end", ""))

    def _lookup(self, path: str) -> Any:
        if not self._has_current:
            raise PropertyError("There is no current example: call next_example first")
        if path in self._cache:
            return self._cache[path]
        value = self._current
        walked = ""
        for part in _parse_path(path):
            value = _step(value, part, walked, path)
            walked = f"{walked}({part})" if isinstance(part, int) else (f"{walked}.{part}" if walked else part)
        self._cache[path] = value
        return value

    def _sequence(self, path: str) -> Any:
        value = self._lookup(path)
        if not isinstance(value, bytes | bytearray | list | tuple):
            raise PropertyError(f"{path!r} is {value!r}, not bytes, a list or a tuple")
        return value

    def _write_journal(self, example: Any) -> None:
        if not self._journal:
            return
        self._append_journal({"index": self.count + 1, "seed": self._seed, "example": repr(example)})

    def _append_journal(self, entry: dict[str, Any]) -> None:
        with open(self._journal, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry) + "\n")
            stream.flush()
            os.fsync(stream.fileno())

    def _saved_failures(self) -> list[Any]:
        if not self._failures_file or not os.path.exists(self._failures_file):
            return []
        with open(self._failures_file, encoding="utf-8") as stream:
            return [ast.literal_eval(line) for line in stream.read().splitlines() if line.strip()]

    def _save_failure(self, example: str, replace: bool = False) -> None:
        if not self._failures_file:
            return
        try:
            ast.literal_eval(example)
        except (ValueError, SyntaxError):
            return  # not a literal; the journal still names it
        if not replace:
            example = _shortlex([example, *[e for _, e, _ in self._failures]])
        with open(self._failures_file, "w", encoding="utf-8") as stream:
            stream.write(example + "\n")
            stream.flush()
            os.fsync(stream.fileno())


_SEGMENT = re.compile(r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)?(?P<indices>(?:\(\d+\))*)")


def _parse_path(path: str) -> list[str | int]:
    """``"frames(2).payload"`` → ``["frames", 2, "payload"]``; the empty path is ``[]``."""
    if path == "":
        return []
    parts: list[str | int] = []
    for segment in path.split("."):
        match = _SEGMENT.fullmatch(segment)
        if match is None or segment == "" or (not match["name"] and not match["indices"]):
            raise PropertyError(f"{path!r} is not a field path; write names and indices like 'frames(2).payload'")
        if match["name"]:
            parts.append(match["name"])
        parts.extend(int(index) for index in re.findall(r"\((\d+)\)", match["indices"]))
    return parts


def _step(value: Any, part: str | int, walked: str, path: str) -> Any:
    where = repr(walked) if walked else "the example"
    if isinstance(part, int):
        if not isinstance(value, bytes | bytearray | list | tuple):
            raise PropertyError(f"{path!r}: {where} is {type(value).__name__}, which has no items to index")
        if part >= len(value):
            raise PropertyError(f"{path!r}: {where} has {len(value)} items, so index {part} does not exist")
        return value[part]
    if isinstance(value, Mapping):
        if part in value:
            return value[part]
        fields = ", ".join(str(key) for key in value)
    elif dataclasses.is_dataclass(value) and not isinstance(value, type):
        names = [field.name for field in dataclasses.fields(value)]
        if part in names:
            return getattr(value, part)
        fields = ", ".join(names)
    elif isinstance(value, tuple) and hasattr(value, "_fields"):
        if part in value._fields:
            return getattr(value, part)
        fields = ", ".join(value._fields)
    else:
        raise PropertyError(f"{path!r}: {where} is {type(value).__name__}, which has no field {part!r}")
    raise PropertyError(f"{path!r}: {where} has no field {part!r}; its fields are {fields or 'none'}")


def _vhdl_integer(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise PropertyError(f"{path!r} is {value!r}, not an integer")
    if not -(2**31) <= value < 2**31:
        raise PropertyError(f"{path!r} is {value}, outside the range of a VHDL integer")
    return value


def _load_property(spec: str, args: tuple[Any, ...], kwargs: Mapping[str, Any]) -> tuple[Any, tuple[Any, ...]]:
    """The strategy or state machine class the function ``spec`` returns, and its pinned examples."""
    from ..ethernet.traffic import TrafficError, describe_exception, resolve

    try:
        function = resolve(spec)
    except TrafficError as exc:
        raise PropertyError(str(exc)) from None
    try:
        inspect.signature(function).bind(*args, **kwargs)
    except TypeError as exc:
        raise PropertyError(f"Cannot call {spec!r} with the given arguments: {exc}") from None
    except ValueError:
        pass  # a callable without an inspectable signature is called as it is
    try:
        target = function(*args, **kwargs)
    except Exception as exc:
        raise PropertyError(describe_exception(spec, exc)) from exc
    from hypothesis.stateful import RuleBasedStateMachine
    from hypothesis.strategies import SearchStrategy

    pins = tuple(getattr(function, "__property_examples__", ()))
    if isinstance(target, type) and issubclass(target, RuleBasedStateMachine):
        if pins:
            raise PropertyError(f"{spec!r} returns a state machine, which cannot have pinned examples")
        return target, pins
    if not isinstance(target, SearchStrategy):
        raise PropertyError(
            f"{spec!r} returned {target!r}, not a Hypothesis strategy or a RuleBasedStateMachine subclass"
        )
    return target, pins


def _profile_scale() -> int:
    profile = os.environ.get(PROFILE_VARIABLE, "quick") or "quick"
    if profile not in _PROFILE_SCALES:
        raise PropertyError(f"{PROFILE_VARIABLE}={profile!r} is not a profile; use {' or '.join(_PROFILE_SCALES)}")
    return _PROFILE_SCALES[profile]


def _format_step(item: dict[str, Any]) -> str:
    fields = ", ".join(f"{name}={value!r}" for name, value in item.items() if name != "rule")
    return f"{item['rule']}({fields})"


def _phases(hypothesis: Any, phases: str) -> Any:
    if not phases.strip():
        return tuple(hypothesis.Phase)
    try:
        return tuple(hypothesis.Phase[name.strip()] for name in phases.split(","))
    except KeyError as exc:
        names = ", ".join(phase.name for phase in hypothesis.Phase)
        raise PropertyError(f"Unknown Hypothesis phase {exc.args[0]!r}; the phases are {names}") from None


def _files(output_path: str, name: str) -> tuple[str, str]:
    if not output_path:
        return "", ""
    safe_name = "".join(char if char.isalnum() or char in "-_." else "_" for char in name)
    test_directory = os.path.normpath(output_path)
    journal = os.path.join(test_directory, f"property_journal_{safe_name}.jsonl")
    failures_directory = os.path.join(os.path.dirname(test_directory), "property_failures")
    os.makedirs(test_directory, exist_ok=True)
    os.makedirs(failures_directory, exist_ok=True)
    failures = os.path.join(failures_directory, f"{os.path.basename(test_directory)}.{safe_name}.txt")
    return journal, failures


def _shortlex(examples: list[str]) -> str:
    return min(examples, key=lambda text: (len(text), text))


def _error_detail(spec: str, exc: BaseException) -> str:
    """
    What went wrong when a property could not run, the cause first.

    An exception from the user's strategy names the strategy function and the
    innermost line of the user's code, like errors of packet functions do.
    """
    from ..ethernet.traffic import describe_exception, user_traceback

    if isinstance(exc, PropertyError):
        # Raised by this module with a message for the user; a cause is the user's exception
        lines = [str(exc)]
        if exc.__cause__ is not None:
            details = user_traceback(exc.__cause__)
            if details:
                lines.append(details)
        return "\n".join(lines)

    lines = [describe_exception(spec, exc), *getattr(exc, "__notes__", [])]
    details = user_traceback(exc)
    if details:
        lines.append(details)
    return "\n".join(lines)


def _describe(exc: BaseException) -> str:
    parts = [f"{type(exc).__name__}: {exc}", *getattr(exc, "__notes__", [])]
    if _EXCEPTION_GROUPS and isinstance(exc, _EXCEPTION_GROUPS):
        parts.extend(f"{type(sub).__name__}: {sub}" for sub in getattr(exc, "exceptions", ()))
    return "\n".join(parts)
