"""Tests of stateful properties, pinned examples and profiles, driven by a Python loop in place of VHDL."""

from __future__ import annotations

import textwrap
from pathlib import Path
from typing import Any

import pytest

pytest.importorskip("hypothesis")

from awesome_vunit_vcs.common.property import PROFILE_VARIABLE, PropertyError, PropertyRunner, step

STRATEGIES = textwrap.dedent(
    """
    from hypothesis import strategies as st
    from hypothesis.stateful import RuleBasedStateMachine, invariant, rule

    from awesome_vunit_vcs.common.property import pin, step


    class Registers(RuleBasedStateMachine):
        def __init__(self):
            super().__init__()
            self.model = [0] * 8

        @rule(address=st.integers(0, 7), data=st.integers(0, 255))
        def write(self, address, data):
            step("write", address=address, data=data)
            self.model[address] = data

        @rule(address=st.integers(0, 7))
        def read(self, address):
            assert step("read", address=address) == self.model[address]


    def registers():
        return Registers


    @pin([255, 0])
    def pinned():
        return st.lists(st.integers(0, 255), max_size=4)
    """
)


@pytest.fixture
def strategies(tmp_path: Path) -> str:
    (tmp_path / "stateful_strategies_for_tests.py").write_text(STRATEGIES)
    return str(tmp_path)


def play_register_bank(runner: PropertyRunner, stuck_address: int | None) -> None:
    """Play VHDL with a register bank that ignores writes to ``stuck_address``."""
    registers = [0] * 8
    while runner.next():
        rule = runner.string("rule")
        value = 0
        if rule == "start":
            registers = [0] * 8
        elif rule == "write" and runner.integer("address") != stuck_address:
            registers[runner.integer("address")] = runner.integer("data")
        elif rule == "read":
            value = registers[runner.integer("address")]
        runner.report(True, value=value)


def test_stateful_property_passes(strategies: str) -> None:
    runner = PropertyRunner("stateful_strategies_for_tests:registers", max_examples=20, search_path=strategies)
    play_register_bank(runner, stuck_address=None)
    assert runner.outcome == "passed", runner.summary()


def test_stateful_failure_shrinks_to_minimal_steps(strategies: str) -> None:
    runner = PropertyRunner(
        "stateful_strategies_for_tests:registers", max_examples=200, seed="s", search_path=strategies
    )
    play_register_bank(runner, stuck_address=5)
    assert runner.outcome == "failed"
    assert runner.counterexample() == "write(address=5, data=1); read(address=5)"
    assert "Minimal failing steps" in runner.summary()


def test_pinned_example_runs_first(strategies: str) -> None:
    runner = PropertyRunner("stateful_strategies_for_tests:pinned", max_examples=3, search_path=strategies)
    assert runner.next()
    assert runner.vector().tolist() == [255, 0]
    runner.report(True)
    while runner.next():
        runner.report(True)
    assert runner.outcome == "passed"


def test_long_profile_runs_more_examples(strategies: str, monkeypatch: Any) -> None:
    monkeypatch.setenv(PROFILE_VARIABLE, "long")
    runner = PropertyRunner("stateful_strategies_for_tests:pinned", max_examples=5, search_path=strategies)
    while runner.next():
        runner.report(True)
    assert runner.count > 5


def test_unknown_profile_is_an_error(strategies: str, monkeypatch: Any) -> None:
    monkeypatch.setenv(PROFILE_VARIABLE, "forever")
    with pytest.raises(PropertyError, match="not a profile"):
        PropertyRunner("stateful_strategies_for_tests:pinned", search_path=strategies)


def test_step_outside_a_property_is_an_error() -> None:
    with pytest.raises(PropertyError, match="rules of a property"):
        step("read", address=0)
