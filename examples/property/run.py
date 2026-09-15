# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Property-based testing
----------------------

Hypothesis properties of VHDL designs. tb_property_examples holds the examples
that share its ALU and register bank; tb_property_ethernet uses the GMII VCs and
tb_property_lockup a design that stalls. The strategies are plain Python
functions in python/strategies.py.

Needs Hypothesis: ``pip install hypothesis``.
"""

# docs-start: generate
import os
import sys
from pathlib import Path

from vunit import VUnit

from awesome_vunit_vcs.gen_vhdl import write_vhdl

ROOT = Path(__file__).parent

# The VHDL record of the Pair dataclass, regenerated when the dataclass changes
sys.path.insert(0, str(ROOT / "python"))
from example_records import Pair  # noqa: E402

write_vhdl([Pair], "example_records_pkg", ROOT / "generated" / "example_records_pkg.vhd")
# docs-end: generate

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "src" / "*.vhd")
lib.add_source_files(ROOT / "generated" / "*.vhd")
lib.add_source_files(ROOT / "*.vhd")

# Some examples have a deliberate bug behind an inject_bug generic, off by default. Set
# AWESOME_VUNIT_VCS_EXAMPLE_BUGS=1 to turn it on and watch Hypothesis find and shrink it.
BUG_BENCHES = []
if os.environ.get("AWESOME_VUNIT_VCS_EXAMPLE_BUGS") == "1":
    for test_bench in lib.get_test_benches():
        if test_bench.name in BUG_BENCHES:
            test_bench.set_generic("inject_bug", True)

if __name__ == "__main__":
    vu.main()
