# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
I2C
---

The I2C examples of the documentation, in tb_i2c_examples.vhd: a master
writing and reading registers, an EEPROM with acknowledge polling, a device
model written in Python, a monitor with its protocol checker, statistics and
malformed traffic.
"""

# docs-start: run-script
import os
from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

# The device models in python/ are imported by name in the simulator
os.environ["PYTHONPATH"] = os.pathsep.join(filter(None, [str(ROOT / "python"), os.environ.get("PYTHONPATH")]))

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "*.vhd")

if __name__ == "__main__":
    vu.main()
# docs-end: run-script
