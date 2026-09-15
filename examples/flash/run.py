# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
Flash
-----

The QSPI flash examples of the cookbook, in tb_flash_examples.vhd: a design
booting from a flash image, checking what was written, the pin timing, resets
and commands sent by the testbench.
"""

# docs-start: run-script
from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "src" / "*.vhd")
lib.add_source_files(ROOT / "*.vhd")

if __name__ == "__main__":
    vu.main()
# docs-end: run-script
