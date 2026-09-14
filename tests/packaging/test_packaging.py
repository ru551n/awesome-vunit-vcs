"""
Slow packaging tests: builds distributions and virtual environments.

Not part of the default test run (``testpaths``); run them with::

    pytest tests/packaging

Set ``AWESOME_VUNIT_VCS_VUNIT`` to the pip requirement VUnit is installed from,
for example ``-e /path/to/vunit``.
"""

from __future__ import annotations

import os
import shutil

import check_package
import pytest

pytestmark = pytest.mark.packaging


def test_built_distributions_are_found_by_vunit(tmp_path):
    arguments = ["--work-dir", str(tmp_path)]
    if any(shutil.which(simulator) for simulator in ("nvc", "ghdl")) and os.environ.get("VUNIT_SIMULATOR") != "none":
        arguments.append("--run-example")
    assert check_package.main(arguments) == 0
