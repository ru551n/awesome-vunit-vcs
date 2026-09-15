# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Quick start
-----------

The smallest complete use of awesome-vunit-vcs: a GMII source sends frames
through a register stage and a monitor checks them. The quick start page of
the documentation walks through it.
"""

# docs-start: run-script
from pathlib import Path

from vunit import VUnit

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(Path(__file__).parent / "*.vhd")

if __name__ == "__main__":
    vu.main()
# docs-end: run-script
