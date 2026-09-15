"""Tests of the property runner, driven by a Python loop in place of VHDL."""

from __future__ import annotations

import json
import subprocess
import sys
import textwrap
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

pytest.importorskip("hypothesis")

from awesome_vunit_vcs.common.property import PropertyError, PropertyRunner, _parse_path

STRATEGIES = textwrap.dedent(
    """
    from dataclasses import dataclass

    from hypothesis import strategies as st


    def payloads(max_size=16):
        return st.lists(st.integers(0, 255), max_size=max_size)


    @dataclass(frozen=True)
    class Config:
        lanes: int
        enabled: bool


    def composite():
        return st.fixed_dictionaries(
            {
                "config": st.builds(Config, lanes=st.sampled_from([4, 8]), enabled=st.booleans()),
                "frames": st.lists(
                    st.fixed_dictionaries({"payload": st.binary(max_size=8), "name": st.text(max_size=3)}),
                    min_size=1,
                    max_size=3,
                ),
                "vlan": st.none() | st.integers(1, 4094),
            }
        )


    def not_a_strategy():
        return 42


    def broken_strategy():
        raise RuntimeError("the strategy is broken")


    def _crash(value):
        return value // 0


    def crashes_while_drawing():
        return st.integers(0, 3).map(_crash)


    def broken_machine():
        from hypothesis.stateful import RuleBasedStateMachine, rule

        class BrokenMachine(RuleBasedStateMachine):
            def __init__(self):
                super().__init__()
                raise ValueError("the machine is broken")

            @rule()
            def noop(self):
                pass

        return BrokenMachine
    """
)


@pytest.fixture
def strategies(tmp_path: Path) -> str:
    (tmp_path / "property_strategies_for_tests.py").write_text(STRATEGIES)
    return str(tmp_path)


def drive(runner: PropertyRunner, verdict: Callable[[PropertyRunner], dict[str, Any]]) -> list[str]:
    """Play VHDL: run every example and report the verdict."""
    seen = []
    while runner.next():
        seen.append(repr(runner._current))
        runner.report(**verdict(runner))
    return seen


def planted_bug(runner: PropertyRunner) -> dict[str, Any]:
    items = runner.vector()
    return {"passed": not (len(items) >= 3 and items[0] >= 0x40)}


def test_passing_property_passes(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:payloads", max_examples=30, search_path=strategies)
    drive(runner, lambda r: {"passed": True})
    assert runner.outcome == "passed"
    assert runner.summary().startswith("Property passed after")


def test_failure_shrinks_to_minimal_counterexample(strategies: str) -> None:
    runner = PropertyRunner(
        "property_strategies_for_tests:payloads", max_examples=300, seed="s", search_path=strategies
    )
    drive(runner, planted_bug)
    assert runner.outcome == "failed"
    assert runner.counterexample() == "[64, 0, 0]"
    assert "Minimal counterexample (wrong behavior" in runner.summary()


def test_lockup_is_a_distinct_failure(strategies: str) -> None:
    runner = PropertyRunner(
        "property_strategies_for_tests:payloads", max_examples=300, seed="s", search_path=strategies
    )

    def verdict(r: PropertyRunner) -> dict[str, Any]:
        locked_up = not planted_bug(r)["passed"]
        return {"passed": not locked_up, "timed_out": locked_up}

    drive(runner, verdict)
    assert runner.outcome == "failed"
    assert "ExampleTimeout" in runner.detail
    assert "(lockup" in runner.summary()


def test_unrecovered_lockup_aborts(strategies: str) -> None:
    runner = PropertyRunner(
        "property_strategies_for_tests:payloads", max_examples=300, seed="s", search_path=strategies
    )

    def verdict(r: PropertyRunner) -> dict[str, Any]:
        failing = not planted_bug(r)["passed"]
        return {"passed": not failing, "timed_out": failing, "recovered": False}

    drive(runner, verdict)
    assert runner.outcome == "aborted"
    assert runner.summary().startswith("DUT did not recover after lockup")
    assert runner.counterexample() != ""


def test_flaky_design_is_reported(strategies: str) -> None:
    runner = PropertyRunner(
        "property_strategies_for_tests:payloads", max_examples=300, seed="s", search_path=strategies
    )
    failures = 0

    def verdict(r: PropertyRunner) -> dict[str, Any]:
        nonlocal failures
        if not planted_bug(r)["passed"]:
            failures += 1
            return {"passed": failures != 1}
        return {"passed": True}

    drive(runner, verdict)
    assert runner.outcome == "flaky"


def test_same_seed_gives_same_examples(strategies: str) -> None:
    def examples(seed: str) -> list[str]:
        runner = PropertyRunner(
            "property_strategies_for_tests:payloads", max_examples=40, seed=seed, search_path=strategies
        )
        return drive(runner, lambda r: {"passed": True})

    assert examples("a") == examples("a")
    assert examples("a") != examples("b")


def test_saved_failure_is_replayed_first(strategies: str, tmp_path: Path) -> None:
    output_path = tmp_path / "test_output" / "lib.tb.test_x"
    for run, seed in enumerate(("first", "second")):
        runner = PropertyRunner(
            "property_strategies_for_tests:payloads",
            max_examples=300,
            seed=seed,
            output_path=str(output_path),
            search_path=strategies,
            name="prop",
        )
        seen = drive(runner, planted_bug)
        assert runner.outcome == "failed"
        if run == 1:
            assert seen[0] == "[64, 0, 0]"
    journal = output_path / "property_journal_prop.jsonl"
    entries = [json.loads(line) for line in journal.read_text().splitlines()]
    examples_run = [entry for entry in entries if "example" in entry]
    assert examples_run[-1]["example"] == "[64, 0, 0]"


def test_journal_records_each_example_and_its_verdict(strategies: str, tmp_path: Path) -> None:
    output_path = tmp_path / "test_output" / "lib.tb.test_x"
    runner = PropertyRunner(
        "property_strategies_for_tests:payloads",
        max_examples=300,
        seed="journal",
        output_path=str(output_path),
        search_path=strategies,
        name="prop",
    )
    drive(runner, planted_bug)
    entries = [json.loads(line) for line in (output_path / "property_journal_prop.jsonl").read_text().splitlines()]
    examples_run = [entry for entry in entries if "example" in entry]
    verdicts = [entry for entry in entries if "verdict" in entry]
    assert examples_run and len(verdicts) == len(examples_run)
    assert [entry["index"] for entry in examples_run] == [entry["index"] for entry in verdicts]
    assert {entry["verdict"] for entry in verdicts} == {"passed", "failed"}
    assert all(entry["seed"] == "journal" for entry in examples_run)


def test_composite_paths(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:composite", max_examples=20, search_path=strategies)
    checked = 0
    while runner.next():
        assert runner.integer("config.lanes") in (4, 8)
        assert isinstance(runner.boolean("config.enabled"), bool)
        count = runner.length("frames")
        payload = runner.vector(f"frames({count - 1}).payload")
        assert payload.dtype.name == "int32"
        assert payload.tolist() == list(runner._current["frames"][count - 1]["payload"])
        assert isinstance(runner.string("frames(0).name"), str)
        assert runner.has("vlan") == (runner._current["vlan"] is not None)
        assert not runner.has("frames(9)")
        checked += 1
        runner.report(True)
    assert checked > 0


def test_wrong_path_names_available_fields(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:composite", max_examples=5, search_path=strategies)
    assert runner.next()
    with pytest.raises(PropertyError, match="its fields are config, frames, vlan"):
        runner.integer("confg.lanes")
    with pytest.raises(PropertyError, match="its fields are lanes, enabled"):
        runner.integer("config.lane")
    with pytest.raises(PropertyError, match="index 7 does not exist"):
        runner.vector("frames(7).payload")
    with pytest.raises(PropertyError, match="not an integer"):
        runner.integer("config.enabled")
    runner.report(True)


@pytest.mark.parametrize(
    ("path", "parts"),
    [
        ("", []),
        ("a", ["a"]),
        ("(2)", [2]),
        ("frames(2).payload", ["frames", 2, "payload"]),
        ("m(1)(3).x", ["m", 1, 3, "x"]),
    ],
)
def test_path_grammar(path: str, parts: list[str | int]) -> None:
    assert _parse_path(path) == parts


@pytest.mark.parametrize("path", ["a..b", ".a", "a.", "a[1]", "a(x)", "1a", "a(1)b"])
def test_invalid_paths(path: str) -> None:
    with pytest.raises(PropertyError, match="not a field path"):
        _parse_path(path)


def test_unsigned_and_errors(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:composite", max_examples=5, search_path=strategies)
    assert runner.next()
    assert runner.unsigned("config.lanes", 8) in ("00000100", "00001000")
    with pytest.raises(PropertyError, match="does not fit in 2 bits"):
        runner.unsigned("config.lanes", 2)
    runner.report(True)


def test_invalid_strategy_is_a_property_error(strategies: str) -> None:
    with pytest.raises(PropertyError, match="not a Hypothesis strategy"):
        PropertyRunner("property_strategies_for_tests:not_a_strategy", search_path=strategies)
    with pytest.raises(PropertyError, match="Cannot import"):
        PropertyRunner("no_such_module_xyz:payloads")


def test_an_exception_in_a_strategy_function_names_the_function(strategies: str) -> None:
    with pytest.raises(PropertyError) as info:
        PropertyRunner("property_strategies_for_tests:broken_strategy", search_path=strategies)
    message = str(info.value)
    assert message.startswith(
        "property_strategies_for_tests:broken_strategy raised RuntimeError: the strategy is broken"
    )
    assert "property_strategies_for_tests.py:" in message


def test_an_exception_while_drawing_names_the_strategy_and_the_line(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:crashes_while_drawing", search_path=strategies)
    assert drive(runner, lambda r: {"passed": True}) == []
    assert runner.outcome == "error"
    first_line = runner.detail.splitlines()[0]
    assert first_line.startswith("property_strategies_for_tests:crashes_while_drawing raised ZeroDivisionError")
    assert "property_strategies_for_tests.py:" in first_line
    assert "return value // 0" in runner.detail
    assert runner.take_error() == runner.detail
    assert runner.take_error() == ""


def test_an_exception_in_the_strategy_function_ends_the_property_for_vhdl(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:broken_strategy", search_path=strategies, start=False)
    runner.start()
    assert runner.outcome == "error"
    first_line = runner.detail.splitlines()[0]
    assert first_line.startswith(
        "property_strategies_for_tests:broken_strategy raised RuntimeError: the strategy is broken"
    )
    assert "property_strategies_for_tests.py:" in first_line
    assert not runner.next()
    assert runner.take_error() == runner.detail
    assert runner.take_error() == ""
    assert runner.summary().startswith("Property ended with an error after 0 examples")


def test_an_invalid_strategy_ends_the_property_for_vhdl(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:not_a_strategy", search_path=strategies, start=False)
    runner.start()
    assert runner.outcome == "error"
    assert runner.detail.startswith("'property_strategies_for_tests:not_a_strategy' returned")
    assert not runner.next()


def test_an_exception_while_building_a_state_machine_ends_the_property(strategies: str) -> None:
    runner = PropertyRunner("property_strategies_for_tests:broken_machine", search_path=strategies, start=False)
    runner.start()
    drive(runner, lambda r: {"passed": True})
    assert runner.outcome == "error"
    first_line = runner.detail.splitlines()[0]
    assert first_line.startswith(
        "property_strategies_for_tests:broken_machine raised ValueError: the machine is broken"
    )
    assert runner.take_error()


def test_package_never_imports_hypothesis() -> None:
    code = textwrap.dedent(
        """
        import importlib, pkgutil, sys
        import awesome_vunit_vcs
        for module in pkgutil.walk_packages(awesome_vunit_vcs.__path__, "awesome_vunit_vcs."):
            importlib.import_module(module.name)
        assert "hypothesis" not in sys.modules, sorted(m for m in sys.modules if m.startswith("hypothesis"))
        """
    )
    subprocess.run([sys.executable, "-c", code], check=True)


def test_failure_message_names_the_saved_failure_and_the_journal(strategies: str, tmp_path: Path) -> None:
    output = tmp_path / "test_output" / "lib.tb.test"
    runner = PropertyRunner(
        "property_strategies_for_tests:payloads",
        max_examples=300,
        seed="s",
        search_path=strategies,
        output_path=str(output),
        name="tb:my_prop",
    )
    drive(runner, planted_bug)
    summary = runner.summary()
    assert runner.outcome == "failed"
    saved = tmp_path / "test_output" / "property_failures" / "lib.tb.test.tb_my_prop.txt"
    journal = output / "property_journal_tb_my_prop.jsonl"
    assert f"Saved failure: {saved}" in summary
    assert f"Journal: {journal}" in summary
