# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""vunit-python-bridge has a setup function, which VUnit only runs with allow_setup=True."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

BRIDGE_CALL = re.compile(r"""add_package\(\s*["']vunit[-_]python[-_]bridge["']\s*(?P<rest>[^)]*)\)""")


def tracked_text_files() -> list[Path]:
    output = subprocess.run(
        ["git", "ls-files", "*.py", "*.rst", "*.md", "*.toml"],
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [REPO / line for line in output.splitlines() if line]


def test_every_bridge_add_package_call_allows_setup() -> None:
    missing = []
    calls = 0
    for path in tracked_text_files():
        for match in BRIDGE_CALL.finditer(path.read_text(encoding="utf-8")):
            calls += 1
            if "allow_setup=True" not in match.group("rest").replace(" ", ""):
                missing.append(f"{path.relative_to(REPO)}: {match.group(0)}")
    assert calls > 0
    assert not missing, "add_package('vunit-python-bridge') without allow_setup=True:\n" + "\n".join(missing)
