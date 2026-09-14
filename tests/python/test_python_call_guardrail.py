# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
The VHDL of the package calls Python with the bridge's typed arguments only.

Building Python source text from VHDL values (``"method(" & value & ")"``) breaks
on quotes and backslashes and hides what a call passes, so it must not come back.
Only vc_python_pkg uses the bridge's exec, for the import and the creation of a backend.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

VHDL_ROOT = Path(__file__).resolve().parents[2] / "src" / "awesome_vunit_vcs" / "vhdl"
BRIDGE_PACKAGE = VHDL_ROOT / "common" / "vc_python_pkg.vhd"

#: Subprograms that take Python source text, allowed in vc_python_pkg only
SOURCE_TEXT_CALLS = re.compile(r"\b(exec|eval|eval_\w+|exec_file|to_call_str)\s*\(")
#: Helpers of the old string style that must not reappear
OLD_HELPERS = re.compile(
    r"\b(py_str|py_bool|py_int_list|backend_exec|backend_integer|backend_boolean|backend_string)\b"
)
#: A string literal that opens a Python call and is concatenated with a value
CALL_TEXT = re.compile(r'"[A-Za-z_][\w.]*\([^"]*"\s*&')


def vhdl_files() -> list[Path]:
    return sorted(VHDL_ROOT.rglob("*.vhd"))


def code_lines(path: Path) -> list[tuple[int, str]]:
    return [
        (number, line.split("--", 1)[0])
        for number, line in enumerate(path.read_text().splitlines(), start=1)
        if line.split("--", 1)[0].strip()
    ]


@pytest.mark.parametrize("path", vhdl_files(), ids=lambda path: path.name)
def test_vhdl_calls_python_with_typed_arguments(path: Path) -> None:
    problems = []
    for number, line in code_lines(path):
        if OLD_HELPERS.search(line) or CALL_TEXT.search(line):
            problems.append(f"{path.name}:{number}: {line.strip()}")
        if path != BRIDGE_PACKAGE and SOURCE_TEXT_CALLS.search(line):
            problems.append(f"{path.name}:{number}: {line.strip()}")
    assert not problems, "Python source text built in VHDL:\n" + "\n".join(problems)


def test_the_guardrail_finds_source_text() -> None:
    assert CALL_TEXT.search('backend_exec(session, "report(" & py_bool(passed) & ")");')
    assert OLD_HELPERS.search("py_str(name)")
    assert SOURCE_TEXT_CALLS.search('exec("vc.x = 1", session);')
    assert not CALL_TEXT.search('backend_call(session, "report", arg(passed));')
