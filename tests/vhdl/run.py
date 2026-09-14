# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
HDL tests of awesome-vunit-vcs.

The packages are added the way a user adds them, so the tests also prove that
the installed VHDL library and Python backend modules are found without paths.
"""

from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_osvvm()
vu.add_package("vunit-python-bridge")
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "*.vhd")

if __name__ == "__main__":
    vu.main()
