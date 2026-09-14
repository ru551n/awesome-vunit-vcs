# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
GMII Verification Components
----------------------------

Shows how to verify a GMII design with ``gmii_source`` and ``gmii_monitor``.
The source transmits frames into a register pipeline (the DUT) and a monitor
on each side of it reconstructs, checks and counts them. The testbench shows
the scoreboard, a deliberate FCS error counted instead of failing the test,
statistics, a PCAPNG capture for Wireshark, a Python subscriber added to a
monitor and, when Scapy is installed, sending a Scapy packet.

Install awesome-vunit-vcs (see the installation guide) and run this script
from any directory. The packages are added by name, so the script does not
know where their VHDL files or Python modules are installed.
"""

from pathlib import Path

from vunit import VUnit

ROOT = Path(__file__).parent

vu = VUnit.from_argv()
vu.add_vhdl_builtins()
vu.add_verification_components()
vu.add_osvvm()
vu.add_package("vunit-python-bridge", allow_setup=True)
vu.add_package("awesome-vunit-vcs")

lib = vu.add_library("lib")
lib.add_source_files(ROOT / "src" / "*.vhd")
lib.add_source_files(ROOT / "*.vhd")

if __name__ == "__main__":
    vu.main()
