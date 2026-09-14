# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Property-based testing
----------------------

Shows property-based testing of VHDL designs with Hypothesis, from a single
integer to composite examples: a record of configuration fields, a list of
variable-length byte vectors, a tagged union of transaction kinds and a
sequence of operations checked against a Python reference model.

The strategies are plain Python functions in ``python/property_examples.py``.
Each testbench loops over the examples Hypothesis draws with ``property_pkg``;
Hypothesis shrinks a failure to a minimal counterexample through the same loop.

Needs Hypothesis: ``pip install hypothesis``.
"""

from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge")
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "src" / "*.vhd")
lib.add_source_files(ROOT / "*.vhd")

if __name__ == "__main__":
    vu.main()
