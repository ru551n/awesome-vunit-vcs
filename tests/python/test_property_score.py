"""Tests of report_score: scores reach hypothesis.target inside the example."""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

pytest.importorskip("hypothesis")

from awesome_vunit_vcs.common.property import PropertyError, PropertyRunner


@pytest.fixture
def strategies(tmp_path: Path) -> str:
    (tmp_path / "score_strategies.py").write_text(
        textwrap.dedent(
            """
            from hypothesis import strategies as st

            def values():
                return st.integers(0, 1000)
            """
        )
    )
    return str(tmp_path)


def test_scores_steer_towards_failures(strategies: str) -> None:
    """With the value as the score, Hypothesis finds a value above 990 that random draws rarely hit."""
    runner = PropertyRunner("score_strategies:values", max_examples=200, seed="target", search_path=strategies)
    while runner.next():
        value = runner.integer()
        runner.score("value", value)
        runner.report(value <= 990)
    assert runner.outcome == "failed"
    assert int(runner.counterexample()) > 990


def test_score_needs_a_current_example(strategies: str) -> None:
    runner = PropertyRunner("score_strategies:values", max_examples=5, search_path=strategies)
    with pytest.raises(PropertyError, match="without a current example"):
        runner.score("value", 1.0)
    while runner.next():
        runner.report(True)
