"""
Run the Python examples the documentation includes.

Every file in examples/python is shown in docs/python_guide.rst, so a change
that breaks an example fails here instead of in a reader's hands.
"""

from __future__ import annotations

import runpy
from pathlib import Path

import pytest

EXAMPLES = Path(__file__).resolve().parents[2] / "examples" / "python"

#: Examples that need an optional dependency
NEEDS = {"scapy_packets.py": "scapy", "property_based.py": "hypothesis"}


def test_every_example_is_listed() -> None:
    assert sorted(path.name for path in EXAMPLES.glob("*.py")) == [
        "build_frames.py",
        "capture_frames.py",
        "check_frames.py",
        "decode_samples.py",
        "monitor_subscribers.py",
        "packet_functions.py",
        "property_based.py",
        "scapy_packets.py",
    ]


@pytest.mark.parametrize("name", sorted(path.name for path in EXAMPLES.glob("*.py")))
def test_example_runs(name: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    if name in NEEDS:
        pytest.importorskip(NEEDS[name])
    # Examples write their files, such as captures, to the current directory
    monkeypatch.chdir(tmp_path)
    runpy.run_path(str(EXAMPLES / name), run_name="__main__")
