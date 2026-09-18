# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
AXI4
----

The AXI4 examples of the documentation, in tb_axi4_examples.vhd: a monitor
with a protocol checker and a shadow memory on an AXI4-Lite interface of
VUnit's bus master and AXI slaves, and on an AXI4 interface with IDs and
bursts, statistics, and a protocol violation counted by the checker.
"""

# docs-start: run-script
from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
# VUnit's AXI master and slaves, and its sync_pkg the monitor uses
vu.add_verification_components()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "*.vhd")

if __name__ == "__main__":
    vu.main()
# docs-end: run-script
