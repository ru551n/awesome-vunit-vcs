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

# The XGMII family: 4-lane single edge (32-bit SDR), 4-lane both edges
# (Clause 46 XGMII) and 8 lanes (64-bit variants, XLGMII, CGMII)
tb_xgmii = lib.test_bench("tb_xgmii")
for lanes, both_edges in ((4, False), (4, True), (8, False)):
    tb_xgmii.add_config(
        name=f"{lanes}_lanes_{'both_edges' if both_edges else 'rising_edge'}",
        generics={"lanes": lanes, "both_edges": both_edges},
    )

# MII at both of its link rates
tb_mii = lib.test_bench("tb_mii")
for link_rate_mbps in (10, 100):
    tb_mii.add_config(name=f"{link_rate_mbps}_mbps", generics={"link_rate_mbps": link_rate_mbps})

if __name__ == "__main__":
    vu.main()
