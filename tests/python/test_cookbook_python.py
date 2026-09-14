# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""Run the unit tests of the cookbook's Python files, as the cookbook tells users to."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

PYTHON = Path(__file__).resolve().parents[2] / "examples" / "cookbook" / "python"


def test_cookbook_python_unit_tests_pass() -> None:
    environment = {**os.environ, "PYTHONPATH": os.pathsep.join([str(PYTHON), os.environ.get("PYTHONPATH", "")])}
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", str(PYTHON / "test_cookbook_model.py")],
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
