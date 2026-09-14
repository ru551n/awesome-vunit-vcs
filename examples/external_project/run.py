# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at http://mozilla.org/MPL/2.0/.

"""
External project
----------------

A project using awesome-vunit-vcs the way a user does: ``add_package`` finds
the installed package, so neither this script nor its testbench knows where
the VHDL files or the Python backend modules of the package are installed.
Install the package (``pip install awesome-vunit-vcs`` or an editable
install of the repository) and run this script from any directory.
"""

from pathlib import Path

from vunit import VUnit


def main():
    root = Path(__file__).parent

    vu = VUnit.from_argv()
    vu.add_vhdl_builtins()
    vu.add_verification_components()
    vu.add_python()
    vu.add_package("awesome-vunit-vcs")

    lib = vu.add_library("lib")
    lib.add_source_files(root / "*.vhd")

    vu.main()


if __name__ == "__main__":
    main()
